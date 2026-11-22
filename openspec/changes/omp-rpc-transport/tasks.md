# Tasks

## Test map

Every delta scenario is mapped below.

- **Red rows** name tests to be written in this change.
- **Green rows** are scenarios carried unchanged inside a MODIFIED requirement. They already have passing tests from archived changes, and are re-run in task 11.1 to confirm that the OMP edits did not break them.
- **Paths** are repository-relative.
- **A row naming several files** is green only when the named test passes in every listed file.
- **OMP integration tests** run the host against the scripted `omp-agent` fixture. No real `omp` runs; real-runtime evidence belongs to change 5.
- **New OMP tests** are named `OMP: <scenario>`.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Launch from an npx profile | packages/host/test/it/runtime_profiles_test.dart | a profile's executable and args reach the adapter unchanged (fixture agent reports its argv) | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Argument with spaces and quotes | packages/process_containment/test/pipes_test.dart | pipes preserve exact argv spaces quotes and empty arguments | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Override does not leak | packages/host/test/it/runtime_profiles_test.dart | profile env override reaches only its own sessions, not a terminal or another profile's session | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Codex argv profile | packages/host/test/it/codex_profiles_test.dart | Codex: Codex argv profile | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Unsupported runtime kind | packages/host/test/it/codex_profiles_test.dart | Codex: Unsupported runtime kind | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | OMP argv profile | packages/host/test/it/omp_profiles_test.dart | OMP: OMP argv profile | red |
| agent-runtimes: One runtime profile is the default | First start with the adapter installed | packages/host/test/it/runtime_profiles_test.dart | with no stored default the detected built-in is the default | green |
| agent-runtimes: One runtime profile is the default | Default profile removed from PATH | packages/host/test/it/runtime_profiles_test.dart; packages/desktop/test/agent_test.dart | stored built-in default not detected reports defaultAvailable false with the reason; focused agent UI unavailable default asks to choose or add without silent fallback | green |
| agent-runtimes: One runtime profile is the default | Codex added beside existing Claude default | packages/host/test/it/codex_profiles_test.dart | Codex: Codex added beside existing Claude default | green |
| agent-runtimes: One runtime profile is the default | Fresh Claude recovery with Codex default | packages/host/test/it/codex_profiles_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: incompatible default filters launcher and fresh recovery claude-code; Codex: Fresh Claude recovery with Codex default | green |
| agent-runtimes: One runtime profile is the default | Codex launcher with incompatible default | packages/host/test/it/codex_profiles_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: incompatible default filters launcher and fresh recovery codex; Codex: Codex launcher with incompatible default | green |
| agent-runtimes: One runtime profile is the default | OMP is the only detected runtime | packages/host/test/it/omp_profiles_test.dart | OMP: OMP is the only detected runtime | red |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Qualified version | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_continue_test.dart | listed (name, version) advertising loadSession claims load; Continue with load: replay start, replayed user agent tool events, replay end then idle; no prompt sent | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Unqualified version | packages/host/test/it/agent_continue_test.dart | same exact unlisted fixture without override is not-qualified; records remain known and read-only | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Unqualified version in a new session | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_test.dart | unlisted version claims the baseline only; unlisted version claims the baseline only; start names the version without load or resume | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Advertised feature missing | packages/host/test/it/agent_continue_test.dart | qualified fixture version advertising neither load nor resume answers not-advertised | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Adapter speaks another protocol version | packages/host/test/it/agent_test.dart | fixture answering protocolVersion 2 fails the start with unsupported ACP protocol version and leaves no process | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Codex follows minimum-version compatibility | packages/host/test/it/codex_profiles_test.dart | Codex: Codex follows minimum-version compatibility | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | OMP follows minimum-version compatibility | packages/host/test/it/omp_test.dart | OMP: OMP follows minimum-version compatibility | red |
| agent-runtimes: Native OMP detection never borrows another application's private installation | OMP installed by its installer | packages/host/test/agent/adapter_detector_test.dart | OMP: OMP installed by its installer | red |
| agent-runtimes: Native OMP detection never borrows another application's private installation | Only a shim exists | packages/host/test/agent/adapter_detector_test.dart; packages/host/test/it/omp_profiles_test.dart | OMP: Only a shim exists | red |
| agent-runtimes: Native OMP detection never borrows another application's private installation | Only a private copy exists | packages/host/test/agent/adapter_detector_test.dart; packages/host/test/it/omp_profiles_test.dart | OMP: Only a private copy exists | red |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | New session gets the entry | packages/host/test/it/agent_tools_test.dart | session/new carries one kumiko entry with the bridge command and no workspace file changes | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Continue gets a new entry | packages/host/test/it/agent_tools_test.dart | load and resume carry a kumiko entry with a fresh secret | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Endpoint unavailable | packages/host/test/it/agent_tools_test.dart | endpoint down sends empty mcpServers and status unavailable | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Adapter rejects session creation | packages/host/test/it/agent_tools_test.dart | rejected session/new revokes the secret, stores nothing and is not retried | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Codex receives its bridge configuration | packages/host/test/it/codex_tools_test.dart | Codex: Codex receives its bridge configuration | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Codex configuration cannot be applied | packages/host/test/it/codex_tools_test.dart | Codex: Codex configuration cannot be applied | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Child uses inherited Kumiko tools | packages/host/test/it/codex_tools_test.dart | Codex: Child uses inherited Kumiko tools | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Unrelated commands cannot read bridge secret | packages/host/test/it/codex_tools_test.dart; packages/host/test/agent/tool_file_audit_test.dart; packages/host/test/it/release_contract_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex: Unrelated commands cannot read bridge secret; Codex audit budget:; Codex audit manifest: | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | User already defines kumiko MCP | packages/host/test/it/codex_tools_test.dart | Codex: User already defines kumiko MCP | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | Child bridge connection cap | packages/host/test/it/codex_tools_test.dart | Codex: Child bridge connection cap | green |
| agent-tool-access: Each live session run receives a Kumiko MCP entry | OMP run without tool delivery | packages/host/test/it/omp_test.dart | OMP: OMP run without tool delivery | red |
| desktop-host-protocol: OMP sessions require a compatible peer | Compatible peers | packages/host/test/it/omp_test.dart | OMP: Compatible peers | red |
| desktop-host-protocol: OMP sessions require a compatible peer | Older desktop | packages/host/test/it/omp_test.dart | OMP: Older desktop | red |
| desktop-host-protocol: OMP sessions require a compatible peer | Older host | packages/desktop/test/omp_agent_test.dart | OMP: Older host | red |
| omp-sessions: OMP uses its native RPC connection | Start native OMP | packages/host/test/it/omp_test.dart | OMP: Start native OMP | red |
| omp-sessions: OMP uses its native RPC connection | Readiness never arrives | packages/host/test/it/omp_test.dart; packages/host/test/agent/omp_driver_test.dart | OMP: Readiness never arrives | red |
| omp-sessions: OMP uses its native RPC connection | Unsupported protocol version | packages/host/test/it/omp_test.dart | OMP: Unsupported protocol version | red |
| omp-sessions: OMP uses its native RPC connection | Malformed frame after start | packages/host/test/agent/omp_client_test.dart; packages/host/test/it/omp_test.dart | OMP: Malformed frame after start | red |
| omp-sessions: OMP versions below the minimum are refused before spawn | Supported version | packages/host/test/agent/version_probe_test.dart; packages/host/test/it/omp_test.dart | OMP: Supported version | red |
| omp-sessions: OMP versions below the minimum are refused before spawn | Version too old | packages/host/test/agent/version_probe_test.dart; packages/host/test/it/omp_test.dart | OMP: Version too old | red |
| omp-sessions: OMP versions below the minimum are refused before spawn | Probe fails | packages/host/test/agent/version_probe_test.dart; packages/host/test/it/omp_test.dart | OMP: Probe fails | red |
| omp-sessions: OMP versions below the minimum are refused before spawn | Executable replaced after the probe | packages/host/test/it/omp_test.dart | OMP: Executable replaced after the probe | red |
| omp-sessions: An OMP session records its native identity | Identity stored | packages/host/test/it/omp_test.dart | OMP: Identity stored | red |
| omp-sessions: An OMP session records its native identity | Identity missing | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Identity missing | red |
| omp-sessions: OMP prompt admission and completion are distinct | Admission precedes output | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Admission precedes output | red |
| omp-sessions: OMP prompt admission and completion are distinct | Handled without the agent | packages/host/test/agent/omp_driver_test.dart | OMP: Handled without the agent | red |
| omp-sessions: OMP prompt admission and completion are distinct | Admission refused | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Admission refused | red |
| omp-sessions: OMP prompt admission and completion are distinct | Transport breaks after admission | packages/host/test/it/omp_test.dart | OMP: Transport breaks after admission | red |
| omp-sessions: OMP replies and thinking stream in order | Streamed reply | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Streamed reply | red |
| omp-sessions: OMP replies and thinking stream in order | Thinking and text interleave | packages/host/test/agent/omp_driver_test.dart | OMP: Thinking and text interleave | red |
| omp-sessions: OMP replies and thinking stream in order | Too many open messages | packages/host/test/agent/omp_driver_test.dart | OMP: Too many open messages | red |
| omp-sessions: OMP replies and thinking stream in order | Unknown event | packages/host/test/agent/omp_driver_test.dart | OMP: Unknown event | red |
| omp-sessions: OMP turn errors are shown as OMP reports them | Provider error | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Provider error | red |
| omp-sessions: OMP turn errors are shown as OMP reports them | Oversized error text | packages/host/test/agent/omp_driver_test.dart | OMP: Oversized error text | red |
| omp-sessions: OMP Stop uses native abort without process termination | Abort succeeds | packages/host/test/it/omp_test.dart | OMP: Abort succeeds | red |
| omp-sessions: OMP Stop uses native abort without process termination | Turn finished first | packages/host/test/it/omp_test.dart | OMP: Turn finished first | red |
| omp-sessions: OMP Stop uses native abort without process termination | Abort acknowledged after its deadline | packages/host/test/agent/omp_client_test.dart; packages/host/test/it/omp_test.dart | OMP: Abort acknowledged after its deadline | red |
| omp-sessions: OMP Stop uses native abort without process termination | Abort not confirmed | packages/host/test/it/omp_test.dart | OMP: Abort not confirmed | red |
| omp-sessions: OMP interactive requests are declined until supported | Tool approval requested | packages/host/test/agent/omp_driver_test.dart; packages/host/test/it/omp_test.dart | OMP: Tool approval requested | red |
| omp-sessions: OMP interactive requests are declined until supported | Open URL request | packages/host/test/agent/omp_driver_test.dart | OMP: Open URL request | red |
| omp-sessions: OMP interactive requests are declined until supported | Request after the turn | packages/host/test/agent/omp_driver_test.dart | OMP: Request after the turn | red |
| omp-sessions: OMP features not yet supported are visibly unavailable | Tool activity in a turn | packages/host/test/agent/omp_driver_test.dart | OMP: Tool activity in a turn | red |
| omp-sessions: OMP features not yet supported are visibly unavailable | Continue on a saved OMP session | packages/host/test/it/omp_test.dart; packages/desktop/test/omp_agent_test.dart | OMP: Continue on a saved OMP session | red |
| omp-sessions: Closing an OMP session ends its input before cleanup | Orderly close | packages/host/test/it/omp_test.dart | OMP: Orderly close | red |
| omp-sessions: Closing an OMP session ends its input before cleanup | OMP does not exit | packages/host/test/it/omp_test.dart | OMP: OMP does not exit | red |
| omp-sessions: OMP configuration and sign-in stay native | User-configured provider | packages/host/test/it/omp_test.dart | OMP: User-configured provider | red |
| omp-sessions: OMP configuration and sign-in stay native | Profile override does not leak | packages/host/test/it/omp_profiles_test.dart | OMP: Profile override does not leak | red |

## 1. ADR and architecture record

- [x] 1.1 Write `docs/adr/0016-native-omp-rpc-transport.md` (Status, Date, Supersedes, Context, Decision, Consequences). It records:
  - the v1 NDJSON wire;
  - the probe and minimum-version admission at 18.20.1;
  - fail-closed declines until approvals are mapped;
  - the `omp` peer capability;
  - the saved adapter identity `omp-rpc`;
  - the explicit OMP-only amendments to ADR 0004 decision 2, ADR 0012's qualification wording, and ADR 0005/0013's per-run tool entry (design, ADRs section).

  Verify: the file exists and names each amended clause.
- [x] 1.2 Update `openspec/architecture.md`:
  - the runtime adapters and agent adapter unit rows;
  - the runtime protocols line;
  - an OMP node in the component diagram;
  - a new "Native OMP contract (ADR 0016)" section carrying the design's Resource Bounds rows: waiting commands, high-water mark, staging, open-message flags, notices and probe.

  Verify: the section cites ADR 0016 and the ADR index lists 0016.

## 2. Protocol capability and shared runtime kinds

- [x] 2.1 Write failing tests in `packages/host_protocol/test/omp_capability_test.dart`:
  - `Capability.omp` round-trips through `hello`;
  - `supportedRuntimeKinds` is `claude-code`, `codex`, `omp`;
  - the OMP gate helper refuses without `agent` and `omp`, naming the missing capability.

  Confirm they fail for the missing symbols.
- [x] 2.2 Add `Capability.omp`, `supportedRuntimeKinds` and the OMP gate helper next to `requireCodexCapabilities`. Advertise `omp` from the host (`host.dart`) and the desktop (`main.dart`).

  Verify: `mise exec -- dart test test/omp_capability_test.dart` in `packages/host_protocol` passes, and `mise run test:host_protocol` is green.

## 3. Shared native version probe

- [x] 3.1 Write failing tests in `packages/host/test/agent/version_probe_test.dart` for `probeNativeVersion` with the OMP parser:
  - `omp/18.20.1` is accepted;
  - `omp/18.20.0` is refused, naming both versions;
  - empty output, multi-line output, output over 4 KiB, a non-zero exit and a timeout are each refused with their reason.

  These cover the rows *Supported version*, *Version too old* and *Probe fails*. Confirm they fail.
- [x] 3.2 Extract the launch, settle, output-cap and timeout logic of `probeCodexVersion` into `probeNativeVersion(..., parse, environment)`, keeping Codex's parse, allowlist and 0.166.0 minimum unchanged. Add the OMP parser, the 18.20.1 minimum and the OMP environment allowlist (design D2).
  Run the probe tests through the contained integration-test host on every OS. Bring forward the OMP probe-args option (`host_options.dart`, `test_hooks.dart`) and add a test-only probe request that runs the shared probe with the OMP parser. Reuse the existing scripted probe fixture here; group 6 still owns the OMP agent fixture.

  Verify: `version_probe_test.dart` passes, and the Codex probe tests in `packages/host/test/it/codex_profiles_test.dart` and `codex_test.dart` pass unchanged.

## 4. OMP RPC client

- [x] 4.1 Add the in-memory test peer `packages/host/test/agent/support/omp_peer.dart`, modelled on `codex_peer.dart`. Write failing tests in `omp_client_test.dart` for:
  - `k<n>` ids;
  - the response/event split;
  - the 32-command cap answered `busy` before any write;
  - per-command deadlines;
  - failure responses carrying `error` and `code`;
  - a non-JSON-object line failing the transport;
  - a response for a never-issued id failing the transport (*Malformed frame after start*);
  - a late response for an issued id dropped harmlessly, including after more than 32 later commands were issued and settled (*Abort acknowledged after its deadline*);
  - the shared 16 MiB line limit and the 1 MiB write admission.

  Confirm they fail.
- [x] 4.2 Implement `packages/host/lib/src/agent/omp/omp_client.dart` on `NativeLineReader`, `NativeWriteAdmission` and `LargeLinePermit`, with the issued-id high-water mark (design D1).

  Verify: `mise exec -- dart test test/agent/omp_client_test.dart` in `packages/host` passes.

## 5. Detection and built-in profile

- [ ] 5.1 Write failing tests:
  - in `adapter_detector_test.dart`: *OMP installed by its installer*, *Only a shim exists* and *Only a private copy exists*, using fixture directories only and executing nothing;
  - in `packages/host/test/it/omp_profiles_test.dart`: *OMP is the only detected runtime* and the profile-list checks for *Only a shim exists* and *Only a private copy exists*, without starting any adapter. Group 7 adds the explicit-profile launch assertion for the private copy.

  Confirm they fail.
- [ ] 5.2 Implement `detectOmp` in `adapter_detector.dart`, running in the same isolate under the 2 s cap:
  - Windows: `omp.exe` on PATH and in `%LOCALAPPDATA%\omp`;
  - POSIX: `omp` on PATH and in the existing well-known directories;
  - never execute `.cmd` or `.ps1`.

  Then:
  - add the `omp` field to `AdapterDetectionResult`;
  - add the `builtin:omp` profile with arguments `--mode rpc` (`runtime_profile_service.dart`);
  - make the empty-store default order Claude, Codex, OMP;
  - replace the inline kind allowlist with `supportedRuntimeKinds`.

  Verify: the discovery cases in both files pass, and `runtime_profiles_test.dart` and `codex_profiles_test.dart` stay green. Flip the discovery rows green except *Only a private copy exists*, which also requires the launch assertion in group 7.

## 6. Scripted OMP fixture and test hooks

- [ ] 6.1 Add `packages/host/lib/src/test_hooks/omp_agent_fixture.dart`, dispatched from `fixtures.dart` as `--test-fixture omp-agent`. The fixture:
  - answers `--version` with a scripted `omp/<v>` line;
  - plays a JSON script of frames, including `ready`, responses, `message_update` deltas, `prompt_result`, `extension_ui_request`, tool events, and malformed or out-of-order frames;
  - reports its received commands, argv, cwd and environment canaries to a jsonl file.

  Reuse the OMP probe-args test option from group 3 and add `packages/host/test/it/support/omp_support.dart`, modelled on `codex_support.dart`.

  Verify: a smoke test in `omp_test.dart` starts the fixture and reads its report.

## 7. Start path: gates, launch, readiness and identity

- [ ] 7.1 Write failing integration tests in `omp_test.dart`:
  - *Start native OMP*, *Readiness never arrives* and *Unsupported protocol version*;
  - *Supported version*, *Version too old*, *Probe fails* and *Executable replaced after the probe*;
  - *Identity stored* and *Identity missing*;
  - *OMP follows minimum-version compatibility*;
  - *OMP run without tool delivery*;
  - *Compatible peers* and *Older desktop*;
  - *User-configured provider*: a canary environment value appears in no record, start result, state or event.
  - In `omp_profiles_test.dart`: *OMP argv profile*, *Profile override does not leak*, and the explicit custom profile launch assertion for *Only a private copy exists*.

  Also write the readiness and identity unit tests in `omp_driver_test.dart`. Confirm they fail.
- [ ] 7.2 Implement `OmpRuntimeDriver` `initialize` and `newSession`, in this order:
  1. require `ready` with protocol 1;
  2. send `set_event_filter` with delta updates;
  3. read `get_state` and require `sessionId` ≤ 4 KiB;
  4. call `onCreated`.

  In `agent_service.dart`:
  - check the OMP peer gate before the probe;
  - run the probe, then re-check the executable;
  - mint no grant for `omp`, and report tools unavailable with the reason;
  - launch with `inheritParentEnvironment: true`;
  - select the OMP driver in `_AgentIO`;
  - map `OmpProtocolException` to `adapterProtocol` with the stage and stderr tail;
  - save the adapter as `omp-rpc`.

  Verify: the group 7 rows pass in `test/it/omp_test.dart`, `test/it/omp_profiles_test.dart` and `test/agent/omp_driver_test.dart`; flip them green, including *Only a private copy exists* after both files pass.

## 8. Turns: admission, streaming and errors

- [ ] 8.1 Write failing tests:
  - *Admission precedes output*, *Handled without the agent*, *Admission refused* and *Transport breaks after admission*;
  - *Streamed reply*, *Thinking and text interleave*, *Too many open messages* and *Unknown event*;
  - *Provider error* and *Oversized error text*;
  - driver tests for a `prompt_result` that arrives before the prompt response, and for pre-admission staging overflow at 64 entries or 256 KiB.

  Confirm they fail.
- [ ] 8.2 Implement `prompt` (design D3, D4):
  - register the turn and handle admission, including `agentInvoked:false`;
  - complete the turn from `prompt_result`;
  - stage early events under the Codex bounds;
  - map deltas with per-message flags released at `message_end`, enforcing the 64-message, 256-index and 4 KiB limits;
  - map notices, with bounded and redacted error text.

  Verify: the group 8 rows pass; flip them green.

## 9. Stop, declines, notices, Continue refusal and close

- [ ] 9.1 Write failing tests:
  - *Abort succeeds*, *Turn finished first*, *Abort acknowledged after its deadline* and *Abort not confirmed*. The last two include an acknowledgement after `prompt_result`, one after the deadline, and one after more than 32 later commands;
  - *Tool approval requested*, *Open URL request* and *Request after the turn*, plus the 8-notice cap;
  - *Tool activity in a turn* and *Continue on a saved OMP session*;
  - *Orderly close* and *OMP does not exit*.

  Confirm they fail.
- [ ] 9.2 Implement:
  - `cancel` and `cancelWithPermissions` sending `abort`, with `activeNativeTurns` and `onNativeTurnEnded` so that AgentSession's native Stop settles unchanged;
  - the fail-closed `extension_ui_response` declines (design D5): clamped, redacted and escaped titles, the notice cap, and Failed when a decline cannot be written;
  - the tool-count notice (design D6);
  - the Continue refusal before any probe or spawn;
  - the close order (design D8): abort, close stdin, keep draining, 2 s grace, then `units.end`.

  Verify: the group 9 rows pass; flip them green.

## 10. Desktop

- [ ] 10.1 Write failing widget tests in `packages/desktop/test/omp_agent_test.dart`, using `FakeHostLink`:
  - the OMP launch items are enabled when the host advertises `omp`;
  - *Older host*: they are disabled, naming the missing capability;
  - the profile-dialog kind "OMP native RPC";
  - the "Message OMP" hint;
  - no Steer button;
  - the OMP auth guidance;
  - *Continue on a saved OMP session* shows the host's refusal reason.

  Confirm they fail.
- [ ] 10.2 Implement:
  - the `#omp` and `#omp-profile` launch items, with an unavailable reason (`workbench_page.dart`, `workbench_controller.dart`);
  - the kind entry and help text, with `supportedRuntimeKinds` as the dialog allowlist (`runtime_profiles_dialog.dart`);
  - the hint and auth guidance (`agent_pane_view.dart`, `agent_controller.dart`).

  Verify: `mise exec -- flutter test test/omp_agent_test.dart` in `packages/desktop` passes, and `codex_agent_test.dart` and `agent_test.dart` stay green.

## 11. Integration checks

- [ ] 11.1 Re-run the tests of every green test-map row, then run `mise run check`, `mise run test:host` and `mise run test`; all pass. The timing rows named in AGENTS.md are re-run alone before being treated as failures.
- [ ] 11.2 Run `mise run audit`. The dependency audit and the qualification record check pass, with no new dependency.
- [ ] 11.3 Run `openspec validate omp-rpc-transport --strict`, and confirm that every test-map row is green.

## Workflow follow-up

- Pre-ship review, PR and watch, through specwright-commit and specwright-pr (`finish: pr`).
- After merge:
  - change 3 (`omp-rpc-permissions-and-tools`) replaces the D5 declines and the D6 tool notice;
  - change 4 replaces the Continue refusal.
- Follow-ups recorded in the design: a runtime-family registry, workspace trust (issue #22) and the M2-F1 composer keys.
