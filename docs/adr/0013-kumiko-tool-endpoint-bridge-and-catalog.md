# ADR 0013: Kumiko tool endpoint, bridge handshake and tool catalog

- **Status:** accepted (2026-11-02)
- **Date:** 2026-11-02
- **Source:** change `kumiko-tool-delivery` design D1 to D10; ADR 0001, ADR 0002, ADR 0005 and ADR 0012
- **Relation:** refines ADR 0005 and does not supersede it. It amends ADR 0012 decision 7 additively; the ADR 0012 file is unchanged.

## Context

ADR 0005 fixes the shape of Kumiko tool delivery: one host tool service, an ACP stdio `mcp-bridge` over a per-user pipe or socket, a per-session secret, per-call authorization, and *connected* only after an observed call. It leaves the endpoint mechanics, the bridge handshake, the tool catalog and the evidence format open. Later tool changes (the M2 read-only role, M3 project tools) and later runtimes must follow one contract rather than infer it from an archived change, as ADR 0012 did for transport and qualification.

The endpoint is the one listening surface Kumiko adds on the machine, and the secret is a credential. Both live next to processes Kumiko does not control: the adapter spawns the bridge, and any local process can try to connect.

## Decision

### Endpoint (D2)

1. **Per-user endpoint, never TCP or UDP.** The host creates one endpoint per host run and removes it on exit. Rejected: a localhost TCP endpoint with a token (ADR 0005); a per-user `/tmp/kumiko-<uid>` socket directory as primary or fallback; Windows AF_UNIX sockets via FFI.
2. **POSIX.** `ServerSocket.bind(InternetAddress('<profile>/tools.sock', type: unix), 0)`. The profile directory is already verified owner-only; the socket is `chmod 0600`. An existing `tools.sock` is deleted first, which is safe because the profile lock makes this host its only owner. The path is checked in bytes against the platform `sun_path` limit: 104 on macOS, 108 on Linux. A longer path makes the endpoint unavailable (decision 4) and the host continues. No `/tmp` fallback.
3. **Windows.** Pipe `\\.\pipe\kumiko-tools-<128-bit random hex>`, created with `CreateNamedPipeW(PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE (first instance only) | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE | PIPE_REJECT_REMOTE_CLIENTS, ...)`, `nMaxInstances` 256. Its security descriptor is built from the SDDL `D:P(A;;GA;;;<current user SID>)(A;;GA;;;SY)`; the user SID is read from the process token. The endpoint name reaches the bridge as `KUMIKO_TOOL_ENDPOINT` in the MCP entry environment (a socket path on POSIX).
4. **Endpoint failure is host-wide degraded mode, not a start failure (D7).** If the endpoint cannot be created, the host logs it and keeps running. Sessions then get no `kumiko` entry (`mcpServers` stays empty) and show `unavailable: endpoint-unavailable: <cause>`. Tools are additive; terminals and chat must not depend on them. There is no `session/new` retry without `mcpServers` after an adapter error: it would create a second native session after an ambiguous error and hide a delivery failure.
5. **Cancellable Windows I/O.** All endpoint I/O on Windows is overlapped and cancellable by the host. `WindowsPipeReader` and `WindowsPipeWriter` are not reused for endpoint connections: their blocking `ReadFile`/`WriteFile` cannot run on an overlapped handle and only unblock when the peer closes, which here is a process the host does not control.
   - An accept worker isolate waits on overlapped `ConnectNamedPipe` together with a stop event through `WaitForMultipleObjects`, keeps one pending instance, and creates the next after each connect.
   - Each connection gets one worker isolate that owns its handle and runs overlapped `ReadFile`/`WriteFile`, each waiting on its I/O event plus the connection's stop event.
   - A host-initiated close (preamble deadline, authentication refusal, `busy`, line bound, revocation, host shutdown) signals the stop event. The worker calls `CancelIoEx`, waits for the cancelled operation with `GetOverlappedResult(..., bWait: TRUE)`, then `DisconnectNamedPipe` and `CloseHandle`, and exits. The host joins the worker before counting the slot free.
   - New code lives in `process_containment` (`windows_pipe_server.dart`, and a client `openWindowsPipe`) beside the existing pipe I/O.
   - A Windows test asserts that a client that connects and never writes or closes is disconnected within the preamble deadline and its slot is free again.
6. **Access control is tested per OS.** Windows tests read the DACL back (`GetSecurityInfo`) and assert only the current user's SID and `SY`, and that remote clients are rejected (flag set). POSIX tests assert socket mode `0600` in an owner-only directory. Stale-socket replacement and removal on exit are tested.

### Handshake and bridge (D3, D9)

7. **Bridge entry.** Each live session run carries one stdio MCP entry named `kumiko` in `session/new`, `session/load` or `session/resume`: `command` is the host executable (`Platform.resolvedExecutable`), `args` is `["--mcp-bridge"]`, and `env` is `KUMIKO_TOOL_ENDPOINT`, `KUMIKO_TOOL_SECRET` and `KUMIKO_UNIT` (the session unit's containment marker, so the POSIX marker scan finds a bridge whatever environment the adapter applies). ACP v1 stdio form: `{name, command, args, env:[{name,value}]}`. No repository or runtime configuration file is written (ADR 0005 decision 6).
8. **Secret.** 32 bytes from `Random.secure`, base64url. It is minted per run (start or Continue) before `units.launch`, passed only in the entry's environment (never argv, which any local process can read through the process table), and never stored, logged, sent to the desktop or written to a repository file. Before any adapter stderr tail leaves the host, every occurrence of a live or just-revoked secret of that run is replaced with `<redacted>`.
9. **Bridge startup.** The bridge reads `KUMIKO_TOOL_ENDPOINT` and `KUMIKO_TOOL_SECRET`. If either is missing or the connect fails, it writes one stderr line and exits 2 before reading stdin. On Windows the client retries a busy pipe through `WaitNamedPipe` for 2 s, then exits 2.
10. **Handshake lines.** After connecting, the bridge sends one line:
    - request: `{"kumikoBridge":1,"secret":"<base64url 32 bytes>"}\n`
    - success: `{"ok":true}\n`
    - refusal: `{"ok":false,"error":"unauthenticated"}\n`, then the host closes
    - cap reached: `{"ok":false,"error":"busy"}\n`, then the host closes
    The host compares secrets in constant time on the decoded bytes. Unauthenticated connections have a **5-second deadline** and a **512-byte preamble bound**. A wrong first line, a non-JSON line or an MCP message closes the connection, and no MCP message from it is processed. Only after `ok` does the bridge start relaying, and only then does the host feed lines to the MCP server for the bound session. Authentication failures are logged as a counter without the secret. Rejected: carrying the secret inside MCP `initialize`, which would expose the JSON-RPC parser to unauthenticated peers.
11. **Relay.** After the handshake the bridge copies bytes stdin to endpoint and endpoint to stdout without parsing MCP. It exits on stdin EOF, endpoint EOF or error, and any write failure. It opens no listening surface, writes nothing to disk, registers no ledger unit and takes no profile lock. It is the adapter's child inside the agent unit's job object (Windows) or process group (POSIX), so ADR 0001 and ADR 0012 containment cover it.
12. **Grant binding (D4).** The grant is registered in the tool service before `units.launch` as a pending slot (target, role `coding`, runtime kind, profile). `initialize` adds adapter name and version; `onCreated` (or Continue registration) binds it to the live session and record id. A `kumiko_session_info` call that arrives while the slot is unbound waits on the binding, bounded by the `session/new` 60-second deadline, and fails with *session unavailable* if the attempt fails. The grant is revoked on start failure, adapter exit, close and host exit; revocation closes its open connections. A secret maps to exactly one live session run.

### MCP subset and catalog (D1, D5)

13. **The host is the MCP server.** JSON-RPC 2.0, newline-delimited, implemented in the tool service. Supported: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`. Any other request gets `-32601`. Notifications (no `id`) are never answered: unknown ones are ignored, and `notifications/cancelled` for an in-flight call drops its result. No resources, prompts or streaming results; no MCP library dependency.
14. **Protocol versions.** Supported: `2025-06-18`, `2025-03-26`, `2024-11-05`. `initialize` answers with the client's requested `protocolVersion` when it is one of these, else the newest.
15. **Error codes.**
    - `-32601`: method not supported.
    - `-32602`: unknown or forbidden tool (message `tool <name> is not available`), or arguments that fail the tool's schema (extra properties are rejected).
    - `-32000`: server-side refusal, including `too many concurrent calls` and *session unavailable*.
    - `-32700`: parse error for a malformed line from an authenticated bridge; that line is answered and the connection stays open unless the line bound is exceeded.
16. **Catalog.** `ToolCatalog` maps a role to its allowed tools. M1: `coding -> {kumiko_session_info}`. `tools/list` returns only the role's tools. `tools/call` checks on every call: the grant is live, the tool is in the role's set, and the arguments validate against the schema. Results come only from the grant's own slot, never from an argument. Later roles and tools extend this table and follow these rules.
17. **`kumiko_session_info`.** Takes an empty object, is marked read-only, changes no state, reads host memory only, and returns the calling session's Kumiko session id, role, runtime kind, adapter name and version, and the target workspace path captured at start (unchanged by later focus moves). The result is under 4 KiB.

### Tools status (D6)

18. **Status lives in `AgentSession`'s sequenced state.** `AgentSession` gains `toolsStatus` (`notYetUsed | connected | notStarted | unavailable`) and `toolsReason`, publishes changes through `_publish`, and so orders tools changes against turn state (ADR 0012 decision 2). `AgentStateParams`, `AgentStartResult` and the Continue result carry an optional `tools: {status, reason?}` object: additive, no protocol version bump. A separate tools control notification with its own sequence is rejected (two sequences can reorder on the desktop).
19. **Grant flags.** The grant records `everAuthenticated` and `everCalled` from the pending-slot stage, because the bridge may authenticate during `session/new` before the `AgentSession` exists. A new session reads these flags (an earlier successful call yields `connected` at once). The tool service also notifies `AgentService` of `authenticated` and `callSucceeded`, forwarded to the session on the host isolate. The first-turn-end check reads the grant's `everAuthenticated`, not forwarded events.
20. **Transitions.**
    - start: `notYetUsed`; or `unavailable` when the endpoint is down (reason `endpoint-unavailable: <cause>`) or the adapter version has a recorded failure (decision 22);
    - first successful `tools/call` -> `connected` (terminal for the run; never regresses, including when the adapter restarts the bridge);
    - first turn end while `everAuthenticated` is false -> `notStarted`;
    - from `notStarted`, a later authentication -> `notYetUsed`;
    - from `notStarted` or version-recorded `unavailable`, a later successful call -> `connected` (observation beats the record).
    Listing tools without a successful call never yields `connected`. Continue resets the status to its start value.

### Evidence amendment of ADR 0012 decision 7 (D8)

21. **`kumiko tool call` item.** The checker adds `kumiko tool call` to the baseline items, required per OS for every listed adapter version, with the same OS rules as the other user items: Windows must be recorded; Linux and macOS may be `unproven`. Delivery itself is not a claimed capability: every session gets the entry, and only an observed call yields `connected`.
22. **`toolDeliveryFailures`.** `qualified_adapters.dart` keeps its tuples and adds a separate literal `toolDeliveryFailures = <(String, String, String)>[]` holding `(adapterName, version, observed failure)`. A session on a listed exact name and version starts `unavailable` with that text.
23. **Checker rule for the item.**
    - A `fail` row must carry `observed: "<text>"` in its `Notes` cell (single line, no pipes). A `fail` without it fails the checker.
    - A `fail` is accepted only when `toolDeliveryFailures` lists the same adapter name and version with exactly that text. An accepted `fail` counts as a satisfied item and is printed as `TOOL DELIVERY FAILURE RECORDED: <adapter> <version> <os>: <text>`.
    - A `fail` without a matching list entry, a list entry whose evidence is `pass`, `unproven` or missing, and a list entry whose text differs from the evidence all fail the checker, naming adapter, version and OS.
    - Verdicts are otherwise unchanged: **QUALIFIED** when every checked item passes or is an accepted tool-delivery failure; **ACCEPTED** while allowed `unproven` items remain; never QUALIFIED with an unaccepted `fail`.
    - Source grammar: after `qualifiedAdapters`, the parser reads a second literal `const toolDeliveryFailures = <(String, String, String)>[ ('<name>', '<version>', '<text>'), ];`. The third string may contain spaces but no single quote, backslash or newline. An empty list is valid. A missing or unparseable second literal fails the checker.
    - The checker change and the first `kumiko tool call` Windows row land together, from a real qualification run whose driver step prompts the agent to call `kumiko_session_info` and records the session's tools status and call result.

### Bounds (Resource Bounds)

| Queue / buffer | Bound | At the bound |
|---|---|---|
| Unauthenticated connections | 16 concurrent; 5 s preamble deadline | Further accepts closed at once |
| Preamble line | 512 bytes | Connection closed |
| Authenticated connections | 4 per grant, 256 total | New connection answered `{"ok":false,"error":"busy"}` and closed |
| MCP line from bridge | 1 MiB | Connection closed and logged |
| In-flight calls per connection | 8 | Further calls get `-32000 too many concurrent calls` |
| Call waiting on slot binding | `session/new` 60 s | Fails with *session unavailable* |
| Outbound queue per connection | 1 MiB pending result bytes | Stop reading that connection's requests until drained |
| Grants | One per live session run (unit cap 64) | Bound by the unit cap |
| `kumiko_session_info` result | < 4 KiB | - |
| Windows pending pipe instances | 1 pending; `nMaxInstances` 256 | Client `WaitNamedPipe` 2 s, then bridge exits 2 |
| Windows connection workers | One isolate per connection (16 unauthenticated + 256 authenticated) | Accept refused at the caps; every worker cancellable by its stop event |

Tool handling reads only memory and never awaits desktop credit, so ADR 0002 control is not delayed.

## Rejected alternatives

- **MCP served inside the bridge, calling host RPCs.** A second protocol implementation and part of the authority logic would sit in a process the adapter controls, and every tool would change two programs.
- **`package:dart_mcp`.** A new dependency (with audit and upgrade surface) for five methods.
- **Gating the entry on qualification.** ADR 0005 decision 5 already ties *connected* to an observed call; gating would withhold the entry from the versions that need observing.
- **Checking authorization only at `tools/list`.** Authority can change between list and call; ADR 0005 decision 4 requires a check on every call.
- **Minting the secret after `session/new` returns, or keying grants by native session id.** The entry must be in `session/new`, adapters may start the server during it, and the native id does not exist yet.
- **The host launching bridges as separate units.** ACP stdio MCP servers are spawned by the agent.
- **`SO_PEERCRED`/`getpeereid` on POSIX, secret rotation within a run, and native repository registration (D15) in M1.** Not built; the 0700 profile directory plus the secret suffice, and each is revisited on the evidence named in the change's mechanism ledger.

## Consequences

- Later tool changes add roles and tools to `ToolCatalog` and must keep per-call checks, the handshake, the bounds above and the honest status rule.
- The endpoint is the one listening surface Kumiko adds. Its access control is tested per OS; a peer-identity check on POSIX is deferred.
- The adapter may persist the MCP entry (with the secret) in its native history. The secret is per run and revoked at run end, so a persisted copy is inert; qualification notes whether history contains it.
- A session whose adapter ignores the entry shows *not started by the adapter* after its first turn. An observed delivery failure for an exact version is recorded in `toolDeliveryFailures` with its evidence, which satisfies the ADR 0005 qualification alternative of "reported unavailable with the observed failure".
- The bridge is a new process kind, but it is never a ledger unit; containment and reconciliation cover it through the agent unit.

## Reversal cost

High for the authorization model (ADR 0005). Medium for the endpoint mechanics and the MCP server (the bridge is unchanged if a library replaces the built-in subset). Low for the handshake (bridge and host ship in one executable), status semantics, and the evidence format and checker rule. Writing this ADR has low reversal cost; changing the contract later needs an ADR that amends or supersedes it.
