# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-tool-access → The host serves Kumiko tools on a per-user local endpoint | Endpoint exists while the host runs | packages/host/test/it/tool_endpoint_test.dart | endpoint accepts a same-user connection and opens no TCP/UDP port | green |
| agent-tool-access → The host serves Kumiko tools on a per-user local endpoint | Endpoint access is limited to the current user | packages/process_containment/test/pipe_server_windows_test.dart; packages/host/test/it/tool_endpoint_test.dart | pipe DACL reads back current user and SYSTEM only, remote clients rejected; socket dir owner-only and socket mode 0600 | green |
| agent-tool-access → The host serves Kumiko tools on a per-user local endpoint | Endpoint cannot be created | packages/host/test/it/tool_endpoint_test.dart | over-long socket path leaves the host running, logs the reason, sessions show unavailable | green |
| agent-tool-access → The host serves Kumiko tools on a per-user local endpoint | Endpoint is removed on exit | packages/host/test/it/tool_endpoint_test.dart | endpoint is gone after the desktop disconnects | green |
| agent-tool-access → The host serves Kumiko tools on a per-user local endpoint | Stale socket from a killed host | packages/host/test/it/tool_endpoint_test.dart | stale tools.sock is replaced and accepts connections (POSIX) | green |
| agent-tool-access → Each live session run receives a Kumiko MCP entry | New session gets the entry | packages/host/test/it/agent_tools_test.dart | session/new carries one kumiko entry with the bridge command and no workspace file changes | red |
| agent-tool-access → Each live session run receives a Kumiko MCP entry | Continue gets a new entry | packages/host/test/it/agent_tools_test.dart | load and resume carry a kumiko entry with a fresh secret | red |
| agent-tool-access → Each live session run receives a Kumiko MCP entry | Endpoint unavailable | packages/host/test/it/agent_tools_test.dart | endpoint down sends empty mcpServers and status unavailable | red |
| agent-tool-access → Each live session run receives a Kumiko MCP entry | Adapter rejects session creation | packages/host/test/it/agent_tools_test.dart | rejected session/new revokes the secret, stores nothing and is not retried | red |
| agent-tool-access → Tool connections are authenticated by a per-run session secret | Correct secret | packages/host/test/it/tool_auth_test.dart | correct secret is accepted and served for its session only | green |
| agent-tool-access → Tool connections are authenticated by a per-run session secret | Wrong secret | packages/host/test/it/tool_auth_test.dart | wrong secret is refused before any MCP message | green |
| agent-tool-access → Tool connections are authenticated by a per-run session secret | Missing secret | packages/host/test/it/tool_auth_test.dart | MCP without preamble or silence past the deadline closes the connection | green |
| agent-tool-access → Tool connections are authenticated by a per-run session secret | Secret of a closed session | packages/host/test/it/tool_auth_test.dart | revoked secret is refused after close and after adapter exit | green |
| agent-tool-access → Tool connections are authenticated by a per-run session secret | Secret stays out of the record and the desktop | packages/host/test/it/tool_auth_test.dart | secret absent from records, control messages and redacted stderr tails | red |
| agent-tool-access → Every tool call is authorized against its session | Permitted tool for the coding role | packages/host/test/agent/tool_service_test.dart | coding role lists and calls kumiko_session_info | green |
| agent-tool-access → Every tool call is authorized against its session | Tool not permitted for the role | packages/host/test/agent/tool_service_test.dart | unknown or forbidden tool returns not-available error | green |
| agent-tool-access → Every tool call is authorized against its session | Session closed while connected | packages/host/test/it/tool_auth_test.dart | call after close is rejected and the connection closed | green |
| agent-tool-access → Every tool call is authorized against its session | Arguments name another session | packages/host/test/agent/tool_service_test.dart | arguments naming another session are rejected as invalid | green |
| agent-tool-access → A read-only session information tool is available | Call returns the calling session | packages/host/test/it/agent_tools_test.dart | kumiko_session_info returns id, role, runtime, adapter and target | red |
| agent-tool-access → A read-only session information tool is available | Call during session creation | packages/host/test/it/agent_tools_test.dart | call before session/new returns waits for the record, or fails session unavailable when start fails | red |
| agent-tool-access → A read-only session information tool is available | Target kept after focus moves | packages/host/test/it/agent_tools_test.dart | result names the original target after another workspace is focused | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Successful call connects | packages/host/test/it/agent_tools_test.dart | status not yet used until the first successful call, then connected | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Bridge listed tools but never called one | packages/host/test/it/agent_tools_test.dart | tools/list alone never yields connected | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Adapter never starts the bridge | packages/host/test/it/agent_tools_test.dart | first turn end without authentication gives not started, later auth not yet used, later call connected | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Bridge authenticated during session creation | packages/host/test/it/agent_tools_test.dart | early authentication never reports not started | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Endpoint connection held open by a client | packages/process_containment/test/pipe_server_windows_test.dart; packages/host/test/it/tool_auth_test.dart | silent client is disconnected by the host within the deadline and its slot freed | green |
| agent-tool-access → The Kumiko tools status reports only what was observed | Known failure for the adapter version | packages/host/test/it/agent_tools_test.dart | listed version failure shows unavailable with recorded text | red |
| agent-tool-access → The Kumiko tools status reports only what was observed | Continue resets the status | packages/host/test/it/agent_tools_test.dart | continued run starts at not yet used | red |
| agent-tool-access → The bridge ends with its session or its host | Session closed | packages/host/test/it/agent_tools_test.dart | bridge process gone when close settles | red |
| agent-tool-access → The bridge ends with its session or its host | Host killed | packages/host/test/it/agent_tools_test.dart | bridge exits on endpoint EOF and reconciliation leaves none | red |
| agent-tool-access → The bridge ends with its session or its host | Bridge started without a host | packages/host/test/it/mcp_bridge_test.dart | missing endpoint or variables exit non-zero with one stderr line | green |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Passing tool call recorded | tool/test/qualify_claude_acp_test.dart | dry run records kumiko tool call pass from the fixture | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Evidence missing the item | tool/test/check_qualification_test.dart | missing kumiko tool call fails naming version, OS, item | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Recorded failure is reported | packages/host/test/it/agent_tools_test.dart | listed failure affects only that exact version | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Failure without its observation | tool/test/check_qualification_test.dart | fail without observed text fails | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Recorded failure matches evidence | tool/test/check_qualification_test.dart | matched failure is QUALIFIED and printed | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | Evidence failure without a list entry | tool/test/check_qualification_test.dart | unlisted fail fails | red |
| agent-runtimes → Kumiko tool delivery is qualified per adapter version | List entry contradicts the evidence | tool/test/check_qualification_test.dart | list entry with pass or different text fails | red |
| desktop-host-protocol → Agent control carries the Kumiko tools status | Status change reaches the desktop | packages/host/test/it/agent_tools_test.dart | first successful call publishes state seq+1 with tools connected | red |
| desktop-host-protocol → Agent control carries the Kumiko tools status | Stale status message | packages/desktop/test/agent_test.dart | stale tools status ignored by sequence | green |
| desktop-host-protocol → Agent control carries the Kumiko tools status | Older desktop | packages/host_protocol/test/agent_messages_test.dart | state without or with an unknown tools field round-trips | green |
| desktop-host-protocol → Tool traffic never uses the desktop connection | Tool call under saturated output | packages/host/test/it/agent_qualification_test.dart | tool call answered within the control-latency bound under saturation | red |
| desktop-host-protocol → Tool traffic never uses the desktop connection | Busy tool clients do not delay Stop | packages/host/test/it/agent_qualification_test.dart | Stop acknowledged within bound while a client holds max in-flight calls | red |

## 1. ADR and architecture

- [x] 1.1 Write `docs/adr/0013-kumiko-tool-endpoint-bridge-and-catalog.md` per design D10: D2 endpoint, ACL and cancellable Windows I/O; D3 handshake; D5 catalog and MCP subset; D6 status; D8 additive amendment of ADR 0012 decision 7. Status `accepted (<date>)`, refining ADR 0005. Add its row to the in-force index in `openspec/architecture.md` and update the Kumiko tools contract line and the tool-service row. Verify: the file exists, and `grep 0013 openspec/architecture.md` shows the index row.

## 2. Windows named-pipe endpoint (process_containment)

- [x] 2.1 Write failing `packages/process_containment/test/pipe_server_windows_test.dart`. It covers: owner-only DACL read back (current user SID and SYSTEM only); `PIPE_REJECT_REMOTE_CLIENTS` set; first-instance squatting refused; a client that connects and stays silent is disconnected by a host-signalled stop within 1 s and the worker joined; byte round trip both ways; `openWindowsPipe` client connect, busy retry 2 s, and missing pipe errors. Verify: `dart test` fails on the missing API (skipped off Windows).
- [x] 2.2 Implement `windows_pipe_server.dart` and the client per design D2. Use overlapped `ConnectNamedPipe`/`ReadFile`/`WriteFile`, a stop event, `CancelIoEx`, then `GetOverlappedResult(wait)`, then `DisconnectNamedPipe`/`CloseHandle`. Use one worker isolate per connection and an SDDL security descriptor built from the token user SID. Add the needed `windows_api.dart` bindings. Verify: 2.1 passes on Windows, existing `pipes_windows_test.dart` still passes; flip rows green.

## 3. Tool service, endpoint and handshake (host)

- [x] 3.1 Write failing `packages/host/test/agent/tool_service_test.dart` for the in-memory parts: grant register, bind and revoke; constant-time secret match; `ToolCatalog` per role; the MCP subset (`initialize` version choice, `ping`, `tools/list`, `tools/call`, `-32601` for unknown requests, no answer to notifications, `notifications/cancelled` drops a result); `kumiko_session_info` arguments validation (`-32602`, extra properties rejected); in-flight cap 8; 1 MiB line bound. Verify: the tests fail for the missing service.
- [x] 3.2 Implement `ToolService`, `ToolCatalog`, grants with `everAuthenticated`/`everCalled`, the slot binding future, and the MCP server per design D1, D3, D4 and D5. Verify: 3.1 passes; flip its rows green.
- [x] 3.3 Write failing `packages/host/test/it/tool_endpoint_test.dart` and `tool_auth_test.dart` against the real test-host executable. They cover: same-user connect; no TCP or UDP listener; socket dir and mode (POSIX); unavailable endpoint for an over-long path (host still starts, log line); removal on exit; stale socket replaced; the preamble handshake (correct, wrong, missing, silent past 5 s, revoked after close and after adapter exit); 16 unauthenticated and 4-per-grant caps with `busy`; secret absent from records, control messages and redacted stderr tails. Verify: the tests fail.
- [x] 3.4 Implement the endpoint in the host: POSIX unix socket in the profile with the `sun_path` check, the Windows pipe from group 2, startup after the profile lock, removal at shutdown, and degraded mode per D7. Wire `ToolService` into `Host`. Verify: 3.3 passes on the CI OSes; flip rows green.

## 4. Bridge mode

- [x] 4.1 Write failing `packages/host/test/it/mcp_bridge_test.dart`. It covers: `--mcp-bridge` with missing variables or a missing endpoint writes one stderr line and exits non-zero without reading stdin; with a live host it authenticates and relays MCP both ways; it exits on stdin EOF, on endpoint EOF and on a refused secret. Verify: the tests fail.
- [x] 4.2 Implement `--mcp-bridge` dispatch in `host_main.dart` beside `--unit-exec` and the relay per D3 and D9, in both the release and test entry points. Verify: 4.1 passes; `tool/test/bundle_host_test.dart` still passes; flip rows green.

## 5. Delivery, secrets and status in agent sessions

- [ ] 5.1 Extend the ACP test fixture (`test_hooks/acp_agent_fixture.dart`) to optionally spawn the `mcpServers` stdio entry with its env, as Claude does (reduced environment plus entry env), and to call `kumiko_session_info` on request: during `session/new`, after it, or never. Write failing `packages/host/test/it/agent_tools_test.dart` for every `agent_tools_test.dart` row in the test map, including bridge exit on close and on host kill with no bridge left after reconciliation. Update the `mcpServers` empty assertions in `agent_test.dart:69` and `agent_continue_test.dart:322` to the new entry. Verify: the new tests fail; the updated assertions fail.
- [ ] 5.2 Implement per D4, D6, D7 and D9. `AgentService._open` mints and registers the grant before launch, builds the `kumiko` entry (command `Platform.resolvedExecutable --mcp-bridge`, env `KUMIKO_TOOL_ENDPOINT`, `KUMIKO_TOOL_SECRET`, `KUMIKO_UNIT`), binds the slot at `onCreated` or at Continue registration, and revokes on every end path. `AcpClient` takes the entry for new, load and resume. `AgentSession` owns the tools status and publishes it in sequence. Add `toolDeliveryFailures` (empty) to `qualified_adapters.dart`, and redact secrets in stderr tails. Verify: 5.1 passes along with the whole `packages/host/test` suite; flip rows green.

## 6. Protocol and desktop

- [x] 6.1 Write failing `host_protocol` tests in `agent_messages_test.dart`: an optional `tools {status, reason?}` on `AgentStateParams`, `AgentStartResult` and the Continue result, round-tripping with the field absent or present, an unknown status tolerated as unknown, and an older-desktop decode. Write failing desktop tests in `agent_test.dart` and `workbench_agent_status_test.dart`: the pane shows each of the four status texts, the *unavailable* reason, and ignores a stale sequence. Verify: the tests fail.
- [x] 6.2 Implement the additive protocol fields and the chat pane status line in `agent_pane_view.dart` and `agent_controller.dart`. Verify: 6.1 passes along with `flutter test` in `packages/desktop`; flip rows green.

## 7. Fairness under saturation

- [ ] 7.1 Extend `packages/host/test/it/agent_qualification_test.dart` with two cases: a `kumiko_session_info` call answered within the control-latency bound while a terminal saturates and another event channel has no credit; and Stop acknowledged within the bound while one client holds 8 in-flight calls. Verify: they fail before wiring or are proven by 5.2, then pass; flip rows green.

## 8. Qualification

- [ ] 8.1 Write failing `tool/test/check_qualification_test.dart` cases for D8: missing item; `fail` without `observed:`; a matched failure is QUALIFIED and printed; an unlisted `fail`; a list entry with `pass`, `unproven`, missing evidence or different text; an empty, missing and unparseable `toolDeliveryFailures` literal. Write a failing `tool/test/qualify_claude_acp_test.dart` dry-run case recording `kumiko tool call`. Verify: the tests fail.
- [ ] 8.2 Implement the checker rule and grammar in `tool/check_qualification.dart` and `tool/qualification_support.dart`, the driver's tool step in `tool/qualify_claude_acp.dart` (prompt the agent to call the Kumiko session tool, record the status and the result), and the doc contract and template rows in `docs/qualification/claude-agent-acp.md`. Verify: 8.1 passes; flip rows green.
- [ ] 8.3 (user, Windows) Run real qualification for `@agentclientprotocol/claude-agent-acp` 0.99.1 with `dart tool/qualify_claude_acp.dart --workspace <disposable checkout>`. Record the `kumiko tool call` row: `pass`, or `fail` with `observed: "<text>"` and the matching `toolDeliveryFailures` entry. Also note whether the native history contains the secret. Add `unproven` rows for Linux and macOS. Verify: `dart tool/check_qualification.dart` prints ACCEPTED or QUALIFIED (no failure), and the CI qualification job is green.

## 9. Integration checks

- [ ] 9.1 Run the full suites on Windows locally and the CI matrix on Windows, Linux and macOS: `dart test` in `packages/process_containment`, `packages/host_protocol`, `packages/host` and `tool`, `flutter test` in `packages/desktop`, `dart analyze` workspace-wide, and `dart tool/audit_dependencies.dart`, which must report no new dependency. Verify: all green.
- [ ] 9.2 Release-host smoke on Windows: build with `tool/bundle_host.dart`, start a Claude Code session in the desktop app, and have the agent call the Kumiko session tool. Verify: the pane shows *Kumiko tools: connected*, or *unavailable* with the recorded failure, and after quit no `kumiko_host --mcp-bridge` process remains (Task Manager / `Get-Process`).
