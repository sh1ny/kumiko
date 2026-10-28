# Kumiko Architecture

The current system shape. Change designs read this first. Strategy: [strategy.md](strategy.md). Product direction and decisions D1-D55: [`changes/document-kumiko-direction/design.md`](changes/document-kumiko-direction/design.md). Foundational decisions: [`docs/adr/`](../docs/adr/).

No application code exists yet. Library and runtime claims below are documented, not qualified. The M1 changes qualify them.

## System triage

| Trigger | Applies | Evidence |
|---|---|---|
| T1 Components | Yes | Desktop UI, child execution host, runtime subprocesses, PTYs, tool bridge, and later the team server and external integrations. |
| T2 State | Yes | Local store (layout, sessions, drafts, solo records), native runtime histories, later shared team records. |
| T3 Concurrency | Yes | Multiple agents, terminals and tool calls run at once in the host; later several desktops write to shared records. |
| T4 Boundaries | Yes | Desktop-host protocol, ACP/OMP RPC, MCP bridge, team-server API, GitHub/Jira. Each crosses a process or authority boundary. |
| T5 Volume | Yes | Terminal output, streamed agent events, conversation history and growing project data. |
| T6 Risk | Yes | Agents mutate source and run commands. Private data must stay off the team server. Owner authority and company identity are involved. |

## Components

```mermaid
flowchart LR
    subgraph PC[User's PC]
        D[Flutter desktop<br/>UI, terminal emulation] -- "stdio frames (ADR 0002)" --> H[Execution host<br/>child process]
        H --> S[(Local SQLite store<br/>ADR 0003)]
        H -- "ACP stdio JSON-RPC" --> CC[Claude Code ACP adapter]
        H -. later .-> OMP[OMP native RPC]
        H -- "PTY bytes" --> SH[Shells and TUIs]
        CC -- "MCP stdio" --> B[mcp-bridge]
        B -- "per-user pipe/socket" --> H
        H --> WS[Checkouts / workspaces]
    end
    D -. "later: HTTPS (ADR 0007)" .-> T[Team server]
    H -. "later: owner-authorized tool calls" .-> T
    T -. later .-> X[GitHub / GHES / Jira]
```

| Component | Responsibility | Owns (state) | Talks to via (contract) |
|---|---|---|---|
| Desktop (`desktop`) | Workbench UI, input, terminal emulation/rendering, close/exit confirmations | In-memory view state and terminal scrollback only | Host via ADR 0002; team server later via ADR 0007 |
| Execution host (`host`) | Spawns and owns runtimes, adapters, PTYs and the tool service; sole local-store writer; terminates all children when the desktop goes | Live process table, session records, local store | Desktop (ADR 0002); runtimes (ACP/RPC); PTYs; bridge endpoint (ADR 0005) |
| Runtime adapters (in host) | Map each runtime onto the session model, with qualified capabilities | Per-session protocol state | ACP over the agent's stdio; OMP RPC later (ADR 0004) |
| Tool service and `mcp-bridge` | Expose authorized Kumiko operations to agent sessions | Session-secret map | MCP stdio to the runtime; per-user local endpoint to the host (ADR 0005) |
| Local store | Durable local state | SQLite files | Host only (ADR 0003) |
| `domain` package | Pure rules shared by local and team paths | None | Library |
| Team server (M4+) | Shared records, membership, identity, integrations | Shared database | Desktop and host over a negotiated API (ADR 0007) |

## State ownership

| State | Sole writer | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| Open layout and working sets (Personal and per project) | Host, on desktop request | Until the user changes it; app exit does not mark tabs closed | Restored on reopen; references to missing sessions or workspaces show as unavailable | Local store |
| Workspace cleanup state (*cleanup unresolved* flag and reasons) | Host holding the profile lock | Until a retried reconciliation cleans it or the user confirms | Checked before every launch against the workspace | Local store |
| Kumiko session record (target, runtime, native id, role) | Host | Until the user deletes it from history | Target never changes after creation; resume capability rechecked per adapter version | Local store |
| Conversation transcript | Runtime | The runtime's own retention | Read through the adapter's resume or history path | Runtime's native history |
| Live agent and terminal processes | Host | Until stop, close or host exit | Never rebuilt; reopen shows *saved, not running* | Host process table (memory) |
| Process ledger (pending entry before spawn, then pid, start time, containment id, target workspace) | Host holding the profile lock | Entry from before spawn until the unit is cleaned | Reconciled by the next lock holder before any launch | Local store |
| Unsent drafts and file recovery drafts | Host | Until sent, saved or explicitly discarded | An explicit discard deletes the draft so it cannot be recovered | Local store |
| Terminal scrollback | Desktop emulator | While the tab is open | Lost on close, crash or exit (layout-only reopen) | None durable |
| Shared records (M4+) | Team server | Server policy (D23) | Refetched after reconnect; cache is display-only | Team server |

## Boundaries and contracts

- **Desktop-host protocol:** defined in the `host_protocol` package, versioned with a `hello` handshake and capability set (ADR 0002). Both sides use the generated or shared types only.
- **Runtime protocols:** ACP (stdio, newline-delimited JSON-RPC; `session/new`, and `session/resume` or `session/load` per advertised capability) and OMP RPC. They are pinned per qualified adapter version in the adapter's qualification list (ADR 0004).
- **Kumiko tools:** MCP tool schemas are owned by the host tool service and versioned with it. Authorization is per call (ADR 0005).
- **Local store schema:** a version table in each database, with forward migrations run by the host (ADR 0003).
- **Team API (M4+):** negotiated compatibility in both upgrade orders (D26). There are no message types for private data (ADR 0007).
- **Dependency rule:** no package may add product-analytics, crash-report or remote-logging SDKs (D25). A dependency audit enforces this in CI.

## Resource bounds and failure visibility

Numeric limits are not agreed (design record, Resource Bounds). Each change that introduces a flow sets its number, tests it and records it here. The mechanism and who finds out are fixed now.

| Flow / store | Bound | At the bound | On failure | Who finds out |
|---|---|---|---|---|
| Desktop-host pipe (all channels) | Maximum frame size; control frames sent before the next data frame; per-channel credit (ADR 0002) | A channel without credit pauses alone; control and other channels continue | Pipe loss is handled as host lost (row below) | User, immediately |
| Terminal byte channel (host to desktop) | Per-channel credit and in-flight buffer in the host | Backpressure: the host stops reading that PTY until credit returns | Channel error closes the terminal with exit status shown | Terminal user |
| Terminal scrollback (desktop) | Configurable line cap per terminal | Oldest lines are evicted | n/a | Visible scrollback limit |
| Agent session events (host to desktop) | Bounded queue per session | Backpressure to the adapter. Events are never silently dropped; overflow ends the stream with an error | Session marked *stopped or unknown* with reason | Session owner |
| Concurrent sessions and terminals | Configurable host cap | New launch refused with a visible reason | n/a | Launching user |
| Tool calls per session | Bounded concurrency and argument/result size | Call rejected with error to the agent | Error result; never a fake success | Agent and session activity |
| Host process (whole) | One host per user profile (exclusive lock, ADR 0001) | Second launch starts no host; it focuses the running instance or reports it and exits | Desktop shows host lost. On Windows the desktop terminates the host's job. On restart, the new host reconciles the process ledger before launching anything. Unresolved units, including pending entries without a pid and surviving marked descendants, put their workspace in *cleanup unresolved*, which refuses every new execution against it until a retry cleans it or the user confirms | User, immediately; cleanup results per session |
| Local store write or migration | Transactional | n/a | Write error surfaced on the triggering action; migration failure blocks startup with error | User |
| Host diagnostics (stderr log) | Size-rotated local file (D46) | Rotation; never deletes store data | n/a | Local diagnostics only |

## In-force ADRs

Lists accepted ADRs only.

| ADR | Decision | Supersedes |
|---|---|---|
| [0001](../docs/adr/0001-desktop-and-child-execution-host.md) | Desktop UI plus one child execution host per user profile (exclusive lock); host owns all processes; ledger-based crash cleanup with workspace gate; no daemon | - |
| [0002](../docs/adr/0002-versioned-desktop-host-protocol.md) | Length-prefixed multiplexed frames over host stdio; JSON-RPC control; raw terminal channels; hello/capability negotiation; credit flow control with control priority | - |
| [0003](../docs/adr/0003-host-owned-local-sqlite-store.md) | Local SQLite store, host sole writer under the profile lock; transactional migrations; private by construction; package picked by M1 probe | - |
| [0004](../docs/adr/0004-runtime-adapters-and-session-identity.md) | Host-side runtime adapters with qualified capabilities; immutable session targets; stop vs close; resume only via the runtime's qualified path | - |
| [0005](../docs/adr/0005-host-tool-service-and-authorization.md) | One host tool service; ACP stdio `mcp-bridge` over a per-user pipe/socket; per-session secret; per-call authorization; connected only after a successful call | - |
| [0006](../docs/adr/0006-host-owned-ptys-and-terminal-rendering.md) | PTYs and shells in the host from argv profiles; emulation in the desktop; engine picked by M1 spike | - |
| [0007](../docs/adr/0007-optional-team-server-boundary.md) | Optional team server is sole writer of shared records; no offline replica; private data never crosses; technology decided at the team milestone | - |
