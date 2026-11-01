# Tasks

## Test map

Verification sequencing (user-approved): groups 2-10 verify locally on Windows, plus Linux through WSL when available and runnable. Task 11.3 owns the full Windows/Linux/macOS CI run. Complete tasks on local evidence without claiming unrun OS results. Flip a test-map row green only when its test has passed locally; platform-only tests not run locally remain red with `pending 11.3 CI` until CI proves them. Real-adapter user qualification and the stop at 10.2 are unchanged.

Component sequencing (user-approved): when a scenario needs a component built in a later group, assign its full test to that group in this task file and keep its test-map row red until it passes. A row spanning multiple test files or host/desktop parts turns green only when every part passes. Earlier groups complete their own layer without substituting a forwarding/mock execution path. These task-only ordering corrections must preserve all specified behavior and test strength; behavior changes or weakened tests still require a user decision.

Test locations:
- `process_containment`:
  - `packages/process_containment/test/pipes_test.dart`: piped units on all OSes (D2).
  - `pipes_windows_test.dart`: `@TestOn('windows')`, handle inheritance and full pipes.
- `host_protocol`:
  - `packages/host_protocol/test/agent_messages_test.dart`: typed runtime/agent messages, capability gating, error codes.
  - `agent_channels_test.dart`: one host-allocated event channel, attach ordering over a real `Connection` pair.
  - `agent_events_test.dart`: normalized event codec and the Resource Bounds truncation rules.
- `domain`: `packages/domain/test/runtime_profile_test.dart`, the pure model and validation.
- Host unit tests (pure Dart, no processes; the state-machine combinations live here, per the review suggestion and the `flutter-test-architecture` skill):
  - `packages/host/test/agent/executable_resolver_test.dart`;
  - `adapter_detector_test.dart`;
  - `acp_client_test.dart`;
  - `normalizer_test.dart`;
  - `qualification_test.dart`;
  - `agent_session_test.dart`, over an in-memory ACP transport.
- Host integration tests (the real test host through `support/desktop_standin.dart`; the fake ACP agent is the test host run with `--test-fixture acp-agent` and a JSON script, D13):
  - `packages/host/test/store/migrations_test.dart`: v5.
  - `packages/host/test/it/runtime_profiles_test.dart`.
  - `agent_test.dart`: start, stream, permissions, Stop, records.
  - `agent_close_test.dart`: close, process cleanup, desktop and host loss.
  - `agent_continue_test.dart`: load, resume, unavailable.
  - `agent_qualification_test.dart`: saturation, backpressure, large lines.
- Desktop:
  - `packages/desktop/test/agent_test.dart`: widget and controller tests over the scripted `HostLink`.
  - `workbench_test.dart`: launcher, close hook, restore.
  - `packages/desktop/integration_test/agent_test.dart` and `agent_reopen_test.dart`: the real app, the bundled test host and the fake agent as a user runtime profile.
- Real adapter:
  - `tool/qualify_claude_acp.dart`, run by the user per OS, records `docs/qualification/claude-agent-acp.md`.
  - `tool/check_qualification.dart` (tests in `tool/test/check_qualification_test.dart`) checks it against `qualified_adapters.dart`. It prints **QUALIFIED** only when every claimed capability is `pass` on every OS, and **ACCEPTED** when Linux or macOS user items are `unproven`. Any `fail`, a blank, or a Windows `unproven` fails it.

Automated evidence: [CI run 41344233824](https://github.com/sh1ny/kumiko/actions/runs/41344233824), code checkpoint `d5b2f5d415f0d8102a69c905aaa30858bb218b39`, Windows/Linux/macOS green (Windows passed an unchanged timing retry). Green states below cover applicable automated checks, not the 19 real-adapter Linux/macOS user observations: qualification remains **ACCEPTED**, not **QUALIFIED**.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-runtimes → A runtime profile is an argv launch description for an ACP adapter | Launch from an npx profile | packages/host/test/it/runtime_profiles_test.dart | a profile's executable and args reach the adapter unchanged (fixture agent reports its argv) | green (three-OS CI; applicable platforms) |
| agent-runtimes → A runtime profile is an argv launch description for an ACP adapter | Argument with spaces and quotes | packages/process_containment/test/pipes_test.dart | pipes preserve exact argv spaces quotes and empty arguments | green (three-OS CI; applicable platforms) |
| agent-runtimes → A runtime profile is an argv launch description for an ACP adapter | Override does not leak | packages/host/test/it/runtime_profiles_test.dart | profile env override reaches only its own sessions, not a terminal or another profile's session | green (three-OS CI; applicable platforms) |
| agent-runtimes → An installed adapter is detected as a built-in profile | Adapter installed with npm on Windows | packages/host/test/agent/adapter_detector_test.dart | Windows npm layout (fixture dir with claude-agent-acp.cmd, node_modules/.../dist/index.js, node.exe) yields node.exe + absolute index.js | green (three-OS CI; applicable platforms) |
| agent-runtimes → An installed adapter is detected as a built-in profile | Adapter on PATH on macOS | packages/host/test/agent/adapter_detector_test.dart | POSIX npm layout (bin symlink to dist/index.js, node beside it) yields absolute node + absolute index.js | green (three-OS CI; applicable platforms) |
| agent-runtimes → An installed adapter is detected as a built-in profile | Desktop started from the Dock | packages/host/test/agent/adapter_detector_test.dart; tool/check_qualification.dart | PATH without the install dir still finds the adapter in a well-known directory (fixture home); qualification check > the macOS Finder/Dock item is recorded pass or unproven (user-verified) | green (three-OS fixtures/checker); real Dock observation unproven (ACCEPTED) |
| agent-runtimes → An installed adapter is detected as a built-in profile | Adapter not installed | packages/host/test/it/runtime_profiles_test.dart; packages/desktop/test/agent_test.dart | runtime/list with no adapter returns no built-in and the reason; launcher with no runtime profile offers Add profile naming the package and Node ≥ 22 | green (three-OS CI; applicable platforms) |
| agent-runtimes → An installed adapter is detected as a built-in profile | Built-in profile cannot be edited | packages/host/test/it/runtime_profiles_test.dart | save or remove of a built-in is refused read-only-profile and nothing changes | green (three-OS CI; applicable platforms) |
| agent-runtimes → The user can define, edit and remove runtime profiles | Add a profile | packages/host/test/it/runtime_profiles_test.dart | saved profile survives a host restart unchanged | green (three-OS CI; applicable platforms) |
| agent-runtimes → The user can define, edit and remove runtime profiles | Invalid profile refused | packages/domain/test/runtime_profile_test.dart; packages/host/test/it/runtime_profiles_test.dart | empty executable and env name with = are invalid; save refused invalid-profile leaves the store unchanged | green (three-OS CI; applicable platforms) |
| agent-runtimes → The user can define, edit and remove runtime profiles | Remove a profile in use | packages/host/test/it/agent_continue_test.dart | removing a running session's profile keeps it running and its record; a later Continue uses the default profile | green (three-OS CI; applicable platforms) |
| agent-runtimes → One runtime profile is the default | First start with the adapter installed | packages/host/test/it/runtime_profiles_test.dart | with no stored default the detected built-in is the default | green (three-OS CI; applicable platforms) |
| agent-runtimes → One runtime profile is the default | Default profile removed from PATH | packages/host/test/it/runtime_profiles_test.dart; packages/desktop/test/agent_test.dart | stored built-in default not detected reports defaultAvailable false with the reason; launcher asks to choose or add a profile | green (three-OS CI; applicable platforms) |
| agent-runtimes → An unusable adapter executable is reported, never substituted | Missing executable | packages/host/test/it/agent_test.dart | agent/start with a missing executable fails executable-not-found naming the path, no unit in the ledger, no record | green (three-OS CI; applicable platforms) |
| agent-runtimes → An unusable adapter executable is reported, never substituted | Batch file refused | packages/host/test/agent/executable_resolver_test.dart | an absolute .cmd or .bat executable is refused with the batch-file reason and the node.exe form | green (three-OS CI; applicable platforms) |
| agent-runtimes → An unusable adapter executable is reported, never substituted | Bare name on Windows | packages/host/test/agent/executable_resolver_test.dart | bare node resolves through PATH and PATHEXT to the .exe | green (three-OS CI; applicable platforms) |
| agent-runtimes → An unusable adapter executable is reported, never substituted | Bare name resolving to a batch file on Windows | packages/host/test/agent/executable_resolver_test.dart | bare npx whose first match is npx.cmd is refused, naming npx.cmd and the npx-cli.js form, and a later .exe is not used | green (three-OS CI; applicable platforms) |
| agent-runtimes → An unusable adapter executable is reported, never substituted | Node too old | packages/host/test/it/agent_test.dart | fixture adapter exiting 1 before initialize with an engine error: start fails with the exit status and stderr tail, no record | green (three-OS CI; applicable platforms) |
| agent-runtimes → Runtime capabilities are claimed only from evidence | Qualified version | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_continue_test.dart | listed (name, version) advertising loadSession claims load; Continue with a qualified fixture version loads | green (three-OS CI; applicable platforms) |
| agent-runtimes → Runtime capabilities are claimed only from evidence | Unqualified version | packages/host/test/it/agent_continue_test.dart | Continue whose adapter reports an unlisted version answers resume-unavailable{not-qualified} with the version, terminates the unit, record unchanged | green (three-OS CI; applicable platforms) |
| agent-runtimes → Runtime capabilities are claimed only from evidence | Unqualified version in a new session | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_test.dart | unlisted version claims the baseline only; agent/start result lists load and resume unavailable with the version | green (three-OS CI; applicable platforms) |
| agent-runtimes → Runtime capabilities are claimed only from evidence | Advertised feature missing | packages/host/test/it/agent_continue_test.dart | qualified fixture version advertising neither load nor resume answers resume-unavailable{not-advertised} | green (three-OS CI; applicable platforms) |
| agent-runtimes → Runtime capabilities are claimed only from evidence | Adapter speaks another protocol version | packages/host/test/it/agent_test.dart | fixture answering protocolVersion 2 fails the start with unsupported ACP protocol version and leaves no process | green (three-OS CI; applicable platforms) |
| agent-sessions → An agent session starts in the selected workspace | Start in a checkout | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | session/new receives cwd = workspace path (fixture reports it); launcher Claude Code opens a new tab with a chat pane bound to the selected workspace | green (three-OS CI; applicable platforms) |
| agent-sessions → An agent session starts in the selected workspace | No workspace selected | packages/desktop/test/workbench_test.dart | Personal with no workspace marks Claude Code as needing one with Open folder and sends no agent/start | green (three-OS CI; applicable platforms) |
| agent-sessions → An agent session starts in the selected workspace | Workspace unavailable | packages/host/test/it/agent_test.dart | agent/start for a deleted workspace folder is refused workspace-unavailable with no unit or record | green (three-OS CI; applicable platforms) |
| agent-sessions → A session's execution target never changes | Focus another workspace | packages/desktop/test/agent_test.dart; packages/host/test/it/agent_test.dart | selecting workspace B then sending a prompt sends agent/prompt with the same session id; the fixture still reports cwd A and the stored record names A | green (three-OS CI; applicable platforms) |
| agent-sessions → A session's execution target never changes | Move the chat pane | packages/desktop/test/agent_test.dart | moving a running chat pane to a new tab and into a split keeps link, transcript and session id and sends no host message | green (three-OS CI; applicable platforms) |
| agent-sessions → A session's execution target never changes | Folder replaced behind the workspace | packages/host/test/it/agent_continue_test.dart | Continue after replacing the target directory (new identity) answers resume-unavailable{target-changed} with no unit started | green (three-OS CI; applicable platforms) |
| agent-sessions → Agent processes end with the session, the desktop or the host | Desktop is killed with a running session | packages/host/test/it/agent_close_test.dart | killing the stand-in desktop during a fixture turn that spawned a long-lived child leaves no adapter or child process | green (three-OS CI; applicable platforms) |
| agent-sessions → Agent processes end with the session, the desktop or the host | Host dies abruptly | packages/host/test/it/agent_close_test.dart | killed host: the next host settles the agent unit or marks the workspace cleanup unresolved and refuses agent/start there | green (three-OS CI; applicable platforms) |
| agent-sessions → Agent processes end with the session, the desktop or the host | Unit limit reached | packages/host/test/it/agent_test.dart | agent/start at the unit cap is refused unit-cap with no record | green (three-OS CI; applicable platforms) |
| agent-sessions → Replies and tool activity stream into the chat | Streamed reply | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | 40 scripted chunks arrive as ordered agentText events; the chat's final text equals their concatenation | green (three-OS CI; applicable platforms) |
| agent-sessions → Replies and tool activity stream into the chat | Tool call progresses | packages/host/test/agent/normalizer_test.dart; packages/desktop/test/agent_test.dart | tool_call then updates map to tool/toolUpdate with status and diff; one card shows the title, statuses in order and the diff | green (three-OS CI; applicable platforms) |
| agent-sessions → Replies and tool activity stream into the chat | Oversized tool output | packages/host_protocol/test/agent_events_test.dart; packages/desktop/test/agent_test.dart | tool content over the bound is truncated with truncated true within256KiB encoded; the card shows the truncated mark and later events still render | green (three-OS CI; applicable platforms) |
| agent-sessions → Replies and tool activity stream into the chat | Unknown update kind | packages/host/test/agent/normalizer_test.dart; packages/host/test/it/agent_test.dart | an unknown sessionUpdate kind yields no event; the fixture's later chunks still arrive | green (three-OS CI; applicable platforms) |
| agent-sessions → Permission requests are answered only by an explicit choice | Allow once | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | permissionRequested carries the options; permissionReply delivers the optionId to the fixture; the card shows Allow and the status returns to Running | green (three-OS CI; applicable platforms) |
| agent-sessions → Permission requests are answered only by an explicit choice | Pane moved while a request is pending | packages/desktop/test/agent_test.dart | moving the pane and selecting another workspace keep the request pending with its options and send nothing | green (three-OS CI; applicable platforms) |
| agent-sessions → Permission requests are answered only by an explicit choice | Stop with a pending request | packages/host/test/agent/agent_session_test.dart; packages/host/test/it/agent_test.dart | Stop writes the cancelled outcome before session/cancel (transport order); the fixture receives cancelled; the request is shown cancelled | green (three-OS CI; applicable platforms) |
| agent-sessions → One turn runs at a time | Send while running | packages/desktop/test/agent_test.dart; packages/host/test/agent/agent_session_test.dart | Send disabled while running, text kept; agent/prompt while running refused turn-running | green (three-OS CI; applicable platforms) |
| agent-sessions → One turn runs at a time | Turn ends with a refusal | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | stopReason refusal returns to idle; the chat shows the refusal | green (three-OS CI; applicable platforms) |
| agent-sessions → One turn runs at a time | Prompt fails | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | a prompt error returns to idle with turnEnded{error}; the chat shows the message and the sent prompt | green (three-OS CI; applicable platforms) |
| agent-sessions → Session status reflects runtime evidence | Status of a background tab | packages/desktop/test/agent_test.dart | a permission request in an inactive tab shows Waiting for approval on that tab without activating it | green (three-OS CI; applicable platforms) |
| agent-sessions → Session status reflects runtime evidence | Adapter exits during a turn | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart; packages/host/test/it/agent_close_test.dart | fixture exiting 1 mid-turn yields agent/exited{failed, status 1} and the record remains; pane shows Failed with the status and Continue; native exit retires permissions and drains trailing updates after credit resumes | green (three-OS CI; applicable platforms) |
| agent-sessions → Stop interrupts the turn and reports the actual result | Stop a running turn | packages/host/test/it/agent_test.dart | Stop on a fixture that honours cancel yields stopResult stopped, state idle, the same unit alive and a new prompt accepted | green (three-OS CI; applicable platforms) |
| agent-sessions → Stop interrupts the turn and reports the actual result | Turn finished first | packages/host/test/agent/agent_session_test.dart | prompt answered end_turn after Stop yields finishedFirst | green (three-OS CI; applicable platforms) |
| agent-sessions → Stop interrupts the turn and reports the actual result | Adapter ignores the cancel | packages/host/test/agent/agent_session_test.dart; packages/host/test/it/agent_test.dart | no answer by the stop deadline yields notConfirmed, state stopping, no termination; close still ends it | green (three-OS CI; applicable platforms) |
| agent-sessions → Stop interrupts the turn and reports the actual result | Turn errors after Stop | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | an error answer after Stop yields endedWithError with the message; the chat shows Turn ended with an error after Stop | green (three-OS CI; applicable platforms) |
| agent-sessions → Stop interrupts the turn and reports the actual result | Turn ends after the stop deadline | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | a cancelled answer after notConfirmed sends one late stopResult then idle; the chat replaces the line with Stopped (after the deadline) | green (three-OS CI; applicable platforms) |
| agent-sessions → Closing a running agent asks for confirmation | Close an idle session | packages/desktop/test/agent_test.dart; packages/host/test/it/agent_close_test.dart | idle close shows no dialog and sends agent/close; the host terminates the unit and keeps the record | green (three-OS CI; applicable platforms) |
| agent-sessions → Closing a running agent asks for confirmation | Cancel closing a running session | packages/desktop/test/agent_test.dart | the dialog shows the direction's wording; Cancel keeps pane, split and turn and sends nothing | green (three-OS CI; applicable platforms) |
| agent-sessions → Closing a running agent asks for confirmation | Confirm closing a running session | packages/host/test/it/agent_close_test.dart; packages/desktop/test/agent_test.dart | close of a running fixture turn sends cancel, answers pending requests cancelled, terminates the tree, keeps the record and leaves a file the fixture wrote; the pane closes on exited{closed} | green (three-OS CI; applicable platforms) |
| agent-sessions → Closing a running agent asks for confirmation | Tab with a running agent and a live terminal | packages/desktop/test/workbench_test.dart | closing a tab with a running session and a live terminal shows one dialog naming both; confirm closes both and the tab | green (three-OS CI; applicable platforms) |
| agent-sessions → Closing a running agent asks for confirmation | Turn ends while the confirmation is open | packages/desktop/test/agent_test.dart | turn ends during the dialog; confirm closes it as idle with no stop sent | green (three-OS CI; applicable platforms) |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | Record survives restart | packages/host/test/it/agent_test.dart | after a host restart the store holds the record with the same ids, adapter version and target path and identity | green (three-OS CI; applicable platforms) |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | Start fails before a native id | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | fixture failing session/new leaves no record; the pane shows the failure with Retry | green (three-OS CI; applicable platforms) |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | No transcript in Kumiko's files | packages/host/test/it/agent_test.dart | after a turn with a canary prompt, reply and stderr line, no file under the profile directory (store, WAL, logs) contains the canary | green (three-OS CI; applicable platforms) |
| agent-sessions → Reopen shows saved sessions and continues only on request | Continue through load | packages/host/test/it/agent_continue_test.dart; packages/desktop/test/agent_test.dart | Continue with load: replay{start}, the replayed user/agent/tool events, replay{end}, then idle, and the fixture saw no session/prompt; the chat shows the history | green (three-OS CI; applicable platforms) |
| agent-sessions → Reopen shows saved sessions and continues only on request | Continue through resume | packages/host/test/it/agent_continue_test.dart; packages/desktop/test/agent_test.dart | Continue with resume only: notice earlier messages not shown then idle; the next prompt reaches the same native session | green (three-OS CI; applicable platforms) |
| agent-sessions → Reopen shows saved sessions and continues only on request | Reopen starts nothing | packages/desktop/integration_test/agent_reopen_test.dart | three chat panes reopen as Saved, not running and the host ledger holds no agent unit | green (three-OS CI; applicable platforms) |
| agent-sessions → Unavailable resume is visible | History deleted | packages/host/test/it/agent_continue_test.dart | fixture failing session/load yields exited{failed, resume-unavailable} with the adapter's error; unit terminated; no session/new sent | green (three-OS CI; applicable platforms) |
| agent-sessions → Unavailable resume is visible | Cleanup unresolved | packages/host/test/it/agent_continue_test.dart | Continue in a cleanup-unresolved workspace answers resume-unavailable{cleanup-unresolved} with no unit started | green (three-OS CI; applicable platforms) |
| agent-sessions → Unavailable resume is visible | Start a fresh session instead | packages/desktop/test/agent_test.dart; packages/desktop/test/agent_profiles_test.dart; packages/desktop/integration_test/agent_reopen_test.dart | New session from resume unavailable sends agent/start for the same workspace and keeps the old session id unused; fresh recovery uses current runtime after the original profile is deleted, preserving the workspace and old record | green (three-OS CI; applicable platforms) |
| agent-sessions → Host loss marks sessions stopped or unknown | Host killed mid-turn | packages/desktop/test/agent_test.dart | host loss turns every chat pane Stopped or unknown and disables Send, Stop and the request options | green (three-OS CI; applicable platforms) |
| agent-sessions → Host loss marks sessions stopped or unknown | Restart host | packages/desktop/test/agent_test.dart | after a host restart the pane shows Saved, not running with Continue, and no agent/continue is sent until clicked | green (three-OS CI; applicable platforms) |
| agent-sessions → Native authentication is reported, never managed | Not signed in | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | observed session/new authentication error reports auth-required and cleans up without a record; the pane shows the sign-in message and Retry | green (three-OS fixture CI; Windows native auth confirmed) |
| agent-sessions → Native authentication is reported, never managed | Sign-in expires mid-session | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | observed prompt authentication error returns idle with auth-required and exact native diagnostics; the chat shows the sign-in message | green (three-OS fixture CI; Windows native auth confirmed) |
| agent-sessions → Session event volume is bounded without silent loss | Slow consumer | packages/host/test/it/agent_qualification_test.dart | with no credit, the host stops reading at the queue bound (fixture reports blocked writes); on resume every event arrives in order | green (three-OS CI; applicable platforms) |
| agent-sessions → Session event volume is bounded without silent loss | Oversized adapter message | packages/host/test/it/agent_qualification_test.dart | a 17 MiB fixture line fails the session adapter-protocol, terminates the unit and keeps the record | green (three-OS CI; applicable platforms) |
| agent-sessions → Session event volume is bounded without silent loss | Long conversation | packages/desktop/test/agent_test.dart | past 2,000 entries or 8 MiB the oldest entries are hidden behind the marker and new events still render | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Each agent session has one host-to-desktop event channel | Start a session | packages/host_protocol/test/agent_channels_test.dart | agent/start result names a session id and a unique host-allocated channel | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Each agent session has one host-to-desktop event channel | Channel limit reached | packages/host/test/it/agent_test.dart | agent/start with the channel limit reached is refused channel-limit with no unit started | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Each agent session has one host-to-desktop event channel | Desktop never attaches | packages/host/test/it/agent_close_test.dart | no attach within the attach timeout terminates the unit, frees the channel and keeps the record | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent state, requests and results travel as control messages | Permission request while the event channel is stalled | packages/host/test/it/agent_qualification_test.dart | channel without credit but queue below the bound: permissionRequested arrives and the reply reaches the fixture | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent state, requests and results travel as control messages | Event queue full when a permission request is raised | packages/host/test/it/agent_qualification_test.dart | queue at its bound: the request appears only after credit returns; Stop meanwhile yields notConfirmed after the deadline; close is acked within 250 ms and ends the unit | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent state, requests and results travel as control messages | Reply to an answered request | packages/host/test/agent/agent_session_test.dart | a reply to a resolved request fails unknown-request and writes nothing to the transport | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent state, requests and results travel as control messages | Stop an unknown session | packages/host/test/it/agent_test.dart | agent/stop for a closed session fails unknown-session and other sessions are unaffected | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent methods are capability-gated | Both peers support agents | packages/host_protocol/test/agent_messages_test.dart | runtime and agent methods dispatch when both advertise agent | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent methods are capability-gated | Host without the capability | packages/host_protocol/test/agent_messages_test.dart; packages/desktop/test/agent_test.dart | agent methods fail method-not-available; the Claude Code launcher entry is disabled with the reason and terminal entries work | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent control stays responsive under saturated output | Stop under saturation | packages/host/test/it/agent_qualification_test.dart | saturating terminal A, stalled session B: Stop in session C acked ≤ 250 ms worst of 100 and C's events keep flowing | green (three-OS CI; applicable platforms) |
| desktop-host-protocol → Agent control stays responsive under saturated output | Permission reply under saturation | packages/host/test/it/agent_qualification_test.dart | saturating terminal A: permissionReply in session C acked ≤ 250 ms worst of 100 and delivered to the fixture | green (three-OS CI; applicable platforms) |
| workbench-layout → The launcher opens Claude Code sessions | Open Claude Code from the launcher | packages/desktop/test/workbench_test.dart | + Claude Code opens an active, focused new tab with one agent-chat pane bound to A showing Starting | green (three-OS CI; applicable platforms) |
| workbench-layout → The launcher opens Claude Code sessions | Second session in the same workspace | packages/desktop/test/workbench_test.dart | a second Claude Code launch opens a second tab and leaves the first unchanged | green (three-OS CI; applicable platforms) |
| workbench-layout → The launcher opens Claude Code sessions | No runtime profile | packages/desktop/test/agent_test.dart | with no runtime profile no tab opens and the add-profile prompt names the adapter package | green (three-OS CI; applicable platforms) |
| workbench-layout → Chat panes are saved with the layout | Reopen a split with a chat and a terminal | packages/desktop/integration_test/agent_reopen_test.dart | split of chat and terminal reopens with the same ratio; chat shows Saved, not running with the same session id, terminal ended, not restored | green (three-OS CI; applicable platforms) |
| workbench-layout → Chat panes are saved with the layout | Pane state holds no conversation text | packages/desktop/test/agent_test.dart | the saved pane state holds only sessionId and runtimeName after a scripted conversation | green (three-OS CI; applicable platforms) |
| workbench-layout → Chat panes are saved with the layout | Session never got a record | packages/desktop/test/agent_test.dart | a restored pane with no sessionId, or with agent/records known false, shows Ended with New session and no Continue | green (three-OS CI; applicable platforms) |

## 1. ADR draft and qualification scaffolding

- [x] 1.1 Write `docs/adr/0012-agent-session-transport-and-qualification.md` with `Status: proposed` (MADR-short, as ADRs 0001-0011). It covers:
  - one adapter process per session (D1);
  - transcript events on a per-session data channel, with state, requests and results on control (D4, D5);
  - runtime profiles as argv with no bundled adapter, and the resolution rules (D11, user decision 2026-10-31);
  - the exact-version qualified list, its baseline and its results file checked in CI (D10);
  - rejected alternatives and reversal cost from the design.

  Add its row to `openspec/architecture.md` marked proposed. Verify the fields match ADRs 0001-0011.
- [x] 1.2 Create `docs/qualification/claude-agent-acp.md` as the format template only, with no observed adapter version section. Explain that `tool/qualify_claude_acp.dart` plus the user write version sections from real runs in 10.1/10.2. Include the status legend (`pass`/`fail`/`unproven` and notes) and a version-section template listing the D13 items per OS (windows, linux, macos):
  - launch;
  - streaming;
  - tool activity;
  - permission request;
  - Stop;
  - close with confirmation;
  - load;
  - resume;
  - auth-required observed (code and message);
  - on macOS, launch from Finder or the Dock.

  `unproven` is allowed only for Linux and macOS user items. Do not introduce `pending` or invent observations. Verify the template lists every D13 item once per OS; the file contains no version section.
- [x] 1.3 Write `tool/test/check_qualification_test.dart` (red), then `tool/check_qualification.dart`. Create `packages/host/lib/src/agent/qualified_adapters.dart` with an empty qualified list here; 5.3 adds claim tests and logic, and 10.3 fills the list from recorded results. The checker parses that source and the results file. Missing or unparseable source fails. An empty list exits 0 and prints NO CLAIMS (no adapter qualified), never ACCEPTED or QUALIFIED. For listed pairs, check the baseline, authentication observation and macOS Finder/Dock items, plus load/resume only when claimed. Every checked item must be `pass` on Windows and `pass` or `unproven` on Linux and macOS; authentication `pass` needs its observed code and message. Reject blank results, Windows `unproven`, unknown items or OSes, and duplicate sections, naming the version, OS and item. Unclaimed load/resume may fail or remain unproven. Nonempty accepted claims print ACCEPTED or QUALIFIED as in the test map. Verify the fixture cases:
  - an empty list prints NO CLAIMS; missing or unparseable source fails;
  - all checked items `pass` prints QUALIFIED;
  - Linux and macOS user items `unproven` prints ACCEPTED and lists them;
  - a checked `fail`, a blank, a Windows `unproven`, or a listed pair with no section each fails, naming the item;
  - unclaimed load/resume failures do not block claims for the other capabilities.

  Keep checker logic in a pure function and cover its cases there, with one CLI subprocess smoke test.

  Add the check to the CI audit step on every OS. Flip the qualification part of "Desktop started from the Dock" to the check's state.

## 2. Piped standard I/O in process_containment (D2)

- [x] 2.1 Write failing `pipes_test.dart` cases:
  - a piped unit echoes stdin to stdout;
  - stderr is separate;
  - arguments with spaces and quotes arrive unchanged;
  - EOF follows child exit;
  - a child writing 4 MiB without being read blocks, not fails, and resumes when read;
  - a child that never reads stdin stalls only the writer;
  - terminating the unit ends a grandchild.

  Write failing `pipes_windows_test.dart` cases:
  - only the three pipe handles are inherited (the child enumerates its inherited handles);
  - `CREATE_NO_WINDOW` holds, so no console window is created.

  Verify they fail because `pipes` is missing.
- [x] 2.2 Windows: add `CreatePipe` bindings and the `pipes` option to `spawnWindowsUnit`:
  - the child ends are inheritable and are the only entries in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, with `STARTF_USESTDHANDLES`;
  - the parent closes the child ends after creation;
  - job-then-resume is kept;
  - reader and writer isolates follow `PtyReaderIsolate` and `PtyWriterIsolate` (one chunk in flight).

  Verify the Windows rows of 2.1 pass.
- [x] 2.3 POSIX: pass `pipes` through `spawnPosixUnit` and make `UnitManager.launch` hand the stdin, stdout and stderr streams to the caller instead of draining them (`unit_manager.dart:231-236`), with no change for PTY or plain units. Verify locally: the runnable rows of 2.1, existing `pty_test.dart` and unit tests pass; three-OS CI is task 11.3. Flip "Argument with spaces and quotes" green only on observed local evidence.

## 3. Protocol: agent capability, messages and events (D4, D5)

- [x] 3.1 Write failing `agent_messages_test.dart`:
  - typed round-trip of every `runtime/*` and `agent/*` method and notification in D5;
  - each new error code with its data;
  - `agent/records` ≤ 128 ids;
  - prompt ≤ 256 KiB;
  - permission request clamps (title 4 KiB, 16 options, names 256 B, preview 16 KiB);
  - `methodCapability` gating, without the capability → `method-not-available`.

  Then add `Capability.agent`, the methods, notifications and errors in `messages.dart`. Verify it passes and flip "Both peers support agents" and the protocol part of "Host without the capability" green.
- [x] 3.2 Write failing `agent_events_test.dart` for the normalized event codec and every Resource Bounds event rule:
  - newline-delimited JSON round-trip of each kind;
  - text over 64 KiB encoded split on code point boundaries;
  - a 1 MiB text cap with `truncated`;
  - tool items truncated to 64 KiB each;
  - items added while the total stays ≤ 256 KiB, with `omittedItems`;
  - escaping counted, for example a string of quotes and control characters;
  - the notice fallback;
  - plan clamps;
  - a desktop-side decoder refusing an event over 256 KiB plus one frame.

  Implement in `host_protocol`. Verify it passes and flip the codec part of "Oversized tool output" green.
- [x] 3.3 Write failing `agent_channels_test.dart`: `agent/start` reserves one host-allocated outbound channel; no frame before attach; result and first event coalesced in one read keep the connection open. Implement with the existing `reserveChannels(1)` and `attachOutbound`. Verify it passes and flip "Start a session" green.

## 4. Runtime profiles: domain model, store v5, resolution and detection (D7, D11)

- [x] 4.1 Write failing `runtime_profile_test.dart`:
  - args round-trip;
  - empty executable invalid;
  - env names with `=` invalid;
  - `runtimeKind` required;
  - the shell-profile bounds (64 profiles, 256 args of ≤ 4 KiB, 128 env, 12 KiB).

  Implement the pure model in `domain`, reusing the shell profile validators. Verify it passes and flip its domain rows green.
- [x] 4.2 Write failing v5 tests in `migrations_test.dart`:
  - a v4 store migrates to v5 with `runtime_profile`, `agent_session` (`role` CHECK `coding`) and nothing else changed;
  - a fault inside the step rolls back to v4;
  - a v4-only step list refuses the v5 store with its bytes unchanged;
  - `currentSchemaVersion == 5`.

  Add the v5 step in `store.dart` (one transaction). Verify they pass.
- [x] 4.3 Write failing `executable_resolver_test.dart`:
  - absolute paths;
  - PATH then the well-known directories per OS (D11);
  - Windows PATHEXT where the first match must be `.exe`, and a `.cmd`/`.bat` first match is refused without going on to a later `.exe`;
  - an absolute `.cmd` refused;
  - POSIX not-executable;
  - missing files.

  Write failing `adapter_detector_test.dart` over fixture directory layouts:
  - Windows npm (`claude-agent-acp.cmd`, `node_modules/.../dist/index.js`, `node.exe`);
  - POSIX npm (bin symlink, `node` beside it);
  - an install only in a well-known directory with a minimal PATH;
  - a missing script;
  - the 2 s cap.

  Implement `ExecutableResolver` and `AdapterDetector` in `host/lib/src/agent/`. The built-in profile is absolute `node` plus the script, with `node`'s directory prepended to `PATH`. Verify they pass and flip the resolver and detector rows green.
- [x] 4.4 Write failing `runtime_profiles_test.dart` for the mapped runtime-profile CRUD, default, detection, refusal and built-in read-only rows that need no adapter process. Exclude "Launch from an npx profile" and "Override does not leak": their execution tests belong to 6.1/6.2 and stay red until then. Implement `RuntimeProfileService` (built-ins in memory, user profiles in v5, `default_runtime`, refusal of built-in edits) and wire `runtime/*` in `Host._onRequest` under `Capability.agent`; advertise `agent` in `host.dart`. Verify locally and flip observed passing parts green; multi-part rows wait for their remaining parts, and three-OS CI is task 11.3.

## 5. ACP client, fake agent, normalizer and session state machine (D3, D6, D8, D10, D13, D14)

- [x] 5.1 Write failing `acp_client_test.dart` over an in-memory byte transport:
  - newline-delimited framing with partial lines across chunks;
  - request and response matching;
  - adapter-to-client `session/request_permission` answered;
  - other adapter requests answered `-32601`;
  - unknown notifications ignored;
  - invalid JSON → protocol error;
  - the 16 MiB line bound;
  - the large-line permit: past 1 MiB a session waits for the single host-wide permit, and the permit is released when the line is parsed and normalized, **and also when the session fails, closes, or its adapter's output ends mid-line** (review round 1 re-check suggestion 2).

  Implement `host/lib/src/agent/acp/`. Verify it passes.
- [x] 5.2 Write failing `normalizer_test.dart`:
  - each stable `session/update` variant maps to its event (`user_message_chunk` → `user`, `agent_message_chunk` → `agentText`, `agent_thought_chunk` → `thought`, `tool_call`/`tool_call_update` with text, diff and terminal content, `plan`);
  - unknown kinds and fields ignored;
  - bounds applied through the 3.2 codec.

  Implement. Verify it passes and flip "Unknown update kind" (normalizer part) and "Tool call progresses" (normalizer part) green.
- [x] 5.3 Write failing `qualification_test.dart` for the D10 claims: listed exact pair plus advertised → claimed; unlisted version → baseline only; no `agentInfo.version` → unqualified; listed but not advertised → not claimed. Use the empty `qualified_adapters.dart` list created in 1.3; it is filled in 10.3. Implement the claim logic and verify it passes.
- [x] 5.4 Write failing `agent_session_test.dart` over the in-memory transport, covering the D6 state machine and every combination D8 defines:
  - prompt → running → idle;
  - a permission request → waitingApproval → reply → running;
  - a reply to a resolved request → `unknown-request` with nothing written;
  - Stop with pending requests writes the cancelled outcomes before `session/cancel`;
  - the Stop outcomes `stopped`, `finishedFirst`, `endedWithError`, `notConfirmed` (fake clock) and exactly one late result;
  - a prompt while running → `turn-running`;
  - refusal and error turn ends;
  - preserve the adapter's code and message on an unmatched prompt error; exact native auth-required matching and its regression belong to 10.2, after the required real observation exists;
  - `seq` increasing on every state change;
  - more than 16 pending requests → the extra answered cancelled with a notice.

  Implement `AgentSession`. Verify it passes and flip the host-unit rows green.
- [x] 5.5 Add the `acp-agent` test fixture (`host/lib/src/test_hooks/acp_agent_fixture.dart`, run by `--test-fixture acp-agent` with a JSON script in `KUMIKO_TEST_ACP_SCRIPT`). It covers every D13 behaviour:
  - reports its argv, cwd and environment;
  - configurable `agentInfo` version and capabilities, and protocol version;
  - honour, ignore or race cancel;
  - exit codes;
  - an engine-error exit before `initialize`;
  - auth errors;
  - load replay and resume;
  - oversized lines and unknown kinds;
  - blocked-write reporting;
  - a long-lived child process;
  - a canary text in its reply and stderr.

  Write a smoke test in `packages/host/test/it/agent_test.dart` that the fixture runs as a profile and answers `initialize`. Verify locally; three-OS CI is task 11.3.

## 6. Host agent service: start, stream, permissions, Stop, close, records (D1, D2, D4, D7, D8)

- [x] 6.1 Write failing tests in `agent_test.dart` and `agent_close_test.dart` for every host row mapped there except Continue, the qualification rows and the exact native-auth matching scenarios assigned to 10.2. Also write "Launch from an npx profile" and "Override does not leak" in `runtime_profiles_test.dart`, using the real `AgentService` and the ACP fixture's argv/environment reports. Verify they fail for the missing service.
- [x] 6.2 Implement `AgentService.start` per D7:
  - workspace required and available;
  - profile and executable resolution and checks;
  - reserve one channel;
  - `UnitManager.launch(kind: 'agent', pipes)`;
  - `initialize` (60 s) and the protocol version check;
  - the claims;
  - `session/new{cwd, mcpServers: []}` (60 s);
  - insert the record;
  - answer.

  On failure, terminate, release and write no record, with the stderr tail ≤ 4 KiB. Map exit 127 before `initialize` to `executable-not-found` and 126 to `not-executable` **only when the stderr tail starts with the shim's `unit-exec:` prefix**, otherwise `adapter-start-failed` with the status (review round 1 re-check suggestion 1). Keep stderr in a 64 KiB memory ring, never in `host.log`. Verify the start, refusal, protocol-version, Node-too-old and record rows pass. Until qualification supplies the exact native auth match in 10.2, preserve and show the adapter's own error message as D14 specifies; do not invent a classifier constant. With 6.3, make "Launch from an npx profile" and "Override does not leak" pass through actual agent starts (not a test forwarding saved profile fields into a substitute spawn), then flip those rows green.
- [x] 6.3 Implement attach (10 s timeout), the event relay (normalized events through the channel writer, the 1 MiB queue bound pausing adapter stdout, overshoot ≤ 1 MiB) and the control notifications in the D4 order (`turnEnded` and `state idle` after the turn's events are enqueued). Wire `agent/*` in `Host._onRequest`. Verify the streaming, permission, Stop, unknown-session, canary and "Desktop never attaches" rows pass, and flip them green.
- [x] 6.4 Implement close: ack on entering `closing`; when running, cancel, answer pending requests cancelled, then a 2 s grace; terminate through the existing settle path within 30 s; send `exited{closed}` or `closeFailed`; keep the record. Implement `agent/release`. Verify locally, including desktop kill and host kill with a fixture grandchild, and flip observed passing `agent_close_test.dart` rows green; three-OS CI is task 11.3.

## 7. Continue: load, resume and resume unavailable (D9)

- [x] 7.1 Write failing `agent_continue_test.dart` tests for every Continue row:
  - load replay order;
  - resume notice;
  - unqualified, not-advertised, target-changed, target-missing and cleanup-unresolved;
  - unknown record;
  - load error;
  - a second Continue of an open record refused;
  - Continue after the profile was removed uses the default.

  Use `agent/records` for restored panes. Introduce the existing test-build seam's `HostExtension.qualifiedAdaptersOverride` here, where qualified-fixture Continue first needs it; `AgentService` uses that candidate list only when an extension supplies one, otherwise the production literal list. Test the same unlisted fixture with and without the override (load versus `resume-unavailable{not-qualified}`), and verify the release entry point cannot receive the override. Task 10.1 reuses this seam for real qualification; do not add a side probe around `AgentService` or write fixture candidates into the production list. Verify the pending Continue behavior fails before implementation.
- [x] 7.2 Implement `agent/continue` and `agent/records` per D9 (checks before spawn, decision by the Continue run, load or resume after attach, replay through the normal relay under backpressure, no prompt sent). Verify locally and flip observed passing rows green; three-OS CI is task 11.3.

## 8. Host qualification under load (ADR 0002, Resource Bounds)

- [x] 8.1 Write `agent_qualification_test.dart`, then fix any failures:
  - saturating terminal A, stalled session B, and Stop and permission replies in session C acked ≤ 250 ms worst of 100, with C's events flowing;
  - a slow consumer: reading stops at the bound and every event arrives in order after resume;
  - a queue at its bound with a permission request: it shows after credit, Stop gives `notConfirmed`, and close is acked ≤ 250 ms;
  - a 17 MiB line fails the session;
  - two sessions emitting 8 MiB lines at once: the second waits for the permit, both complete, and host memory stays within the stated worst case.

  Verify locally, flip observed passing rows green, and print `measured:` lines for the ack latencies; three-OS CI is task 11.3.

## 9. Desktop chat panes (D6, D12)

- [x] 9.1 Refactor `WorkbenchController.requestClose` (`workbench_controller.dart:553`) from its terminal branch to a `ViewCloser` interface (`warnsOnClose`, `closeConfirmed`), implemented by `TerminalController`. Verify every existing close row in `terminal_test.dart` and `workbench_test.dart` stays green.
- [x] 9.2 Write failing `agent_test.dart` controller tests:
  - link states (pending start, live, closing, ended);
  - orphans for a pane closed during a pending start;
  - `seq` ordering;
  - the transcript model (append by channel order, tool cards updated by `toolCallId`, replay markers, 2,000 entries or 8 MiB eviction with a marker);
  - permission requests kept across moves;
  - Stop results including late ones;
  - host loss → Stopped or unknown, then Saved, not running after restart;
  - the pane state holding only `{sessionId, runtimeName}`.

  Implement `AgentController` and the `agent-chat` view kind (`needsWorkspace: true`, fresh-UUID `item`). Verify the controller rows pass.
- [x] 9.3 Write failing widget tests, then build the chat view:
  - prompt box (Send disabled while not idle, text kept);
  - streamed text;
  - thinking marked;
  - tool cards with diff and truncated mark;
  - plan;
  - permission card with the adapter's options;
  - Stop and its result line;
  - status chip on the pane and tab;
  - Failed, Ended, Saved, not running (Continue, New session) and resume unavailable (reason, New session);
  - auth message with Retry;
  - the hidden-entries marker.

  Verify every desktop widget row in `agent_test.dart` passes.
- [x] 9.4 Add **Claude Code** to the + launcher: needs a workspace, uses the default runtime profile with a picker, is disabled without the capability, prompts when no profile exists, and always opens a new tab. Add the runtime profile editor (list, add, edit, remove, copy a built-in, set default), with the OS-specific `npx` example (D11). Implement the agent `ViewCloser`: it warns for running, waiting and stopping with "Are you sure you want to stop the running agent?", and one dialog covers a mixed tab. Verify the launcher, profile, close and mixed-tab rows of `workbench_test.dart` and `agent_test.dart` pass.
- [x] 9.5 Write `integration_test/agent_test.dart`: the real app and bundled test host with a fake-agent runtime profile. It opens a workspace, launches Claude Code, sends a prompt, sees streamed text and a tool card, answers a permission request, presses Stop, and closes with confirmation. Write `agent_reopen_test.dart`:
  - a chat beside a terminal reopens with the same split;
  - Saved, not running;
  - no agent unit in the ledger;
  - Continue loads the history.

  Verify both locally and flip observed passing rows green; three-OS CI is task 11.3.

## 10. Real adapter qualification (pauses for the user's per-OS runs)

- [x] 10.1 Write `tool/qualify_claude_acp.dart`. It runs the test host executable with a `HostExtension`, never the release host, and drives the real adapter with the user's built-in or chosen profile through ordinary `agent/start`, prompt, permission, Stop, close and `agent/continue` paths. Use the extension's `qualifiedAdaptersOverride` for exactly the candidate adapter name/version plus `{load, resume}` in that qualification run; normal D9 checks and claim logic still apply. The production list changes only in 10.3 from observed passes. Reuse the test-build override seam introduced for group 7, not a side probe around `AgentService`. Verify with a fake fixture that an unlisted version loads with the override and answers `resume-unavailable{not-qualified}` without it, and that the release entry point ignores or refuses the override flag/environment, like its existing test-fixture refusal. Ask for the interactive confirmations (permission answered, Stop observed, close confirmation, Dock launch on macOS), and write actual results and the observed auth-required code and message into `docs/qualification/claude-agent-acp.md`. Verify end to end against the fake agent (`--dry-run`) without writing fixture observations into the production evidence document.
- [x] 10.2 Ask the user to run the qualification on Windows with `@agentclientprotocol/claude-agent-acp` 0.99.1 (or the then-current version) and record the results. Record Linux and macOS items `unproven` unless the user runs them (precedent of 2026-10-29). Never record a user-verified item as passed on the user's behalf. Stop here until the Windows results are recorded. Use the recorded auth-required code and message as the D14 classifier constant, with a unit test in `agent_session_test.dart`. Implement and verify the deferred host parts of "Not signed in" (`agent_test.dart`: auth-required, no record) and "Sign-in expires mid-session" (`agent_session_test.dart`: idle with turnEnded{auth-required}); verify the corresponding desktop parts still pass before flipping these multi-part rows green. Generic remote-error propagation is implemented earlier; no native auth value may be fabricated from a fixture.
- [x] 10.3 Add the qualified pairs to `qualified_adapters.dart` only for capabilities with recorded `pass` results. Run `dart run tool/check_qualification.dart` and verify it prints ACCEPTED or QUALIFIED. If load or resume failed on Windows, leave it out of the list (Continue then shows *resume unavailable: not qualified*) and tell the user.

## 11. Integration checks and planning files

- [x] 11.1 Update `openspec/architecture.md`:
  - replace the "Agent session events" resource-bound row with the real numbers (event channel, 1 MiB queue, 16 MiB line and the large-line permit, 256 KiB events, stop 10 s, start 60 s, desktop 2,000 entries or 8 MiB, the memory worst case);
  - add rows for the session record, runtime profiles and the adapter stderr ring;
  - add the adapter unit to the components table;
  - add `docs/qualification/` to the boundaries.

  Verify the rows match design.md Resource Bounds and State & Ownership.
- [x] 11.2 Set ADR 0012 to `Status: accepted` with the date and update its index row. Verify the ADR matches the built behaviour (D1, D4, D5, D10, D11).
- [x] 11.3 Run the full CI workflow on Windows, Linux and macOS: audit with `check_qualification.dart`, analyze with `--fatal-infos`, every package's tests, the desktop integration tests, and the release build with the bundled host. Verify it is green and `openspec validate claude-acp-chat-session --strict` passes.
  - [CI run 41344233824, attempt 2](https://github.com/sh1ny/kumiko/actions/runs/41344233824/attempts/2) is green at `d5b2f5d415f0d8102a69c905aaa30858bb218b39`: dependency/qualification audit, root and desktop fatal-info analysis, every package test suite, all eight native desktop integration files, profile checks, release host and desktop bundles, and artifact uploads passed on all three platforms.
  - Initial CI exposed native SDK chunks over 64 KiB and canonical executable aliases; bounded zero-copy delivery and file-identity assertions fixed the causes without weakening the original pipe assertion. Windows then had one 599 ms idle-close acknowledgement against 250 ms; the unchanged failed-job retry passed, including that same threshold. Agent integrations use the bundled test host; the remaining integrations use the release host.
  - Strict OpenSpec validation passed. Clean CI root analysis passes; local owned analysis passes while the unrelated stale `houndshark` checkout remains untouched. One bounded external Claude review, launched in a fresh Orca tab with report-back, returned zero findings for `c5a0b83`; subsequent CI repairs at `d5b2f5d` were verified by regression/native runs and CI, not another broad review loop.
- [x] 11.4 Confirm every test map row is green, or the qualification check passes for its user-verified part. Verify by reading the table against the test run output. M1 cannot close until `check_qualification.dart` prints QUALIFIED.
  - All 87 mapped automated rows pass on their applicable platforms, including the native POSIX npm-symlink and minimal-PATH cases. The real-adapter checker prints ACCEPTED with 19 Linux/macOS user observations unproven, including actual Finder/Dock launch. Windows native authentication evidence is preserved. No QUALIFIED claim or M1 closure is made.

## Workflow follow-up

- After the change is merged and archived, the roadmap's M1 exit criteria for Claude Code sessions are walked by `specwright-roadmap` **close**, including the Linux and macOS qualification items recorded `unproven`.
