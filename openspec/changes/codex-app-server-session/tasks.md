# Tasks

## Test map

Every delta scenario is mapped below. Red rows name prospective tests, not existing passing tests. Green rows retain unchanged scenarios and named coverage from completed archived change test maps; they must be rerun during this change and are not a claim of fresh execution in this planning run. Rows whose wording changed are red even when related regression tests already exist. All paths are repository-relative. A real-runtime observation is not replaced by its synthetic checker test. A row naming several files is green only when its named test passes in every listed file; a row naming the qualification record is green only after task 8.3 records the approved observation.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Launch from an npx profile | packages/host/test/it/runtime_profiles_test.dart | a profile's executable and args reach the adapter unchanged (fixture agent reports its argv) | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Argument with spaces and quotes | packages/process_containment/test/pipes_test.dart | pipes preserve exact argv spaces quotes and empty arguments | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Override does not leak | packages/host/test/it/runtime_profiles_test.dart | profile env override reaches only its own sessions, not a terminal or another profile's session | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Codex argv profile | packages/host/test/it/codex_profiles_test.dart | Codex: Codex argv profile | green |
| agent-runtimes: A runtime profile is an argv launch description for an ACP adapter | Unsupported runtime kind | packages/host/test/it/codex_profiles_test.dart | Codex: Unsupported runtime kind | green |
| agent-runtimes: The user can define, edit and remove runtime profiles | Add a profile | packages/host/test/it/runtime_profiles_test.dart | saved profile survives a host restart unchanged | green |
| agent-runtimes: The user can define, edit and remove runtime profiles | Invalid profile refused | packages/domain/test/runtime_profile_test.dart; packages/host/test/it/runtime_profiles_test.dart | empty executable and env name with = are invalid; save refused invalid-profile leaves the store unchanged | green |
| agent-runtimes: The user can define, edit and remove runtime profiles | Remove a profile in use | packages/host/test/it/codex_profiles_test.dart | Codex: Remove a profile in use | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Qualified version | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_continue_test.dart | listed (name, version) advertising loadSession claims load; Continue with load: replay start, replayed user agent tool events, replay end then idle; no prompt sent | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Unqualified version | packages/host/test/it/agent_continue_test.dart | same exact unlisted fixture without override is not-qualified; records remain known and read-only | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Unqualified version in a new session | packages/host/test/agent/qualification_test.dart; packages/host/test/it/agent_test.dart | unlisted version claims the baseline only; unlisted version claims the baseline only; start names the version without load or resume | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Advertised feature missing | packages/host/test/it/agent_continue_test.dart | qualified fixture version advertising neither load nor resume answers not-advertised | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Adapter speaks another protocol version | packages/host/test/it/agent_test.dart | fixture answering protocolVersion 2 fails the start with unsupported ACP protocol version and leaves no process | green |
| agent-runtimes: Runtime capabilities are claimed only from evidence | Codex follows minimum-version compatibility | packages/host/test/it/codex_profiles_test.dart | Codex: Codex follows minimum-version compatibility | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Adapter installed with npm on Windows | packages/host/test/agent/adapter_detector_test.dart | Windows npm layout (fixture dir with claude-agent-acp.cmd, node_modules/.../dist/index.js, node.exe) yields node.exe + absolute index.js | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Adapter on PATH on macOS | packages/host/test/agent/adapter_detector_test.dart | POSIX npm layout (bin symlink to dist/index.js, node beside it) yields absolute node + absolute index.js | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Desktop started from the Dock | packages/host/test/agent/adapter_detector_test.dart; tool/check_qualification.dart | PATH without the install dir still finds the adapter in a well-known directory (fixture home); qualification check > the macOS Finder/Dock item is recorded pass or unproven (user-verified) | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Adapter not installed | packages/host/test/it/runtime_profiles_test.dart; packages/desktop/test/agent_test.dart | runtime/list with no adapter returns no built-in and the reason; focused agent UI launcher with no runtime profile offers Add profile naming package and Node >= 22 | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Built-in profile cannot be edited | packages/host/test/it/runtime_profiles_test.dart | save or remove of a built-in is refused read-only-profile and nothing changes | green |
| agent-runtimes: An installed adapter is detected as a built-in profile | Only Codex is installed | packages/host/test/it/codex_profiles_test.dart; packages/desktop/test/agent_test.dart | Codex: Codex is installed on PATH; focused agent UI launcher with no runtime profile offers Add profile naming package and Node >= 22 | green |
| agent-runtimes: One runtime profile is the default | First start with the adapter installed | packages/host/test/it/runtime_profiles_test.dart | with no stored default the detected built-in is the default | green |
| agent-runtimes: One runtime profile is the default | Default profile removed from PATH | packages/host/test/it/runtime_profiles_test.dart; packages/desktop/test/agent_test.dart | stored built-in default not detected reports defaultAvailable false with the reason; focused agent UI unavailable default asks to choose or add without silent fallback | green |
| agent-runtimes: One runtime profile is the default | Codex added beside existing Claude default | packages/host/test/it/codex_profiles_test.dart | Codex: Codex added beside existing Claude default | green |
| agent-runtimes: One runtime profile is the default | Fresh Claude recovery with Codex default | packages/host/test/it/codex_profiles_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: incompatible default filters launcher and fresh recovery claude-code; Codex: Fresh Claude recovery with Codex default | green |
| agent-runtimes: One runtime profile is the default | Codex launcher with incompatible default | packages/host/test/it/codex_profiles_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: incompatible default filters launcher and fresh recovery codex; Codex: Codex launcher with incompatible default | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Passing tool call recorded | tool/test/qualify_claude_acp_test.dart | dry run records kumiko tool call pass from the fixture | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Evidence missing the item | tool/test/check_qualification_test.dart | missing kumiko tool call fails naming version, OS, item | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Recorded failure is reported | packages/host/test/it/agent_tools_test.dart | listed failure affects only that exact version | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Failure without its observation | tool/test/check_qualification_test.dart | fail without observed text fails | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Recorded failure matches evidence | tool/test/check_qualification_test.dart | matched failure is QUALIFIED and printed | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | Evidence failure without a list entry | tool/test/check_qualification_test.dart | unlisted fail fails | green |
| agent-runtimes: Kumiko tool delivery is qualified per adapter version | List entry contradicts the evidence | tool/test/check_qualification_test.dart | list entry with pass or different text fails | green |
| agent-runtimes: Native Codex detection never borrows another application's private installation | Codex is installed on PATH | packages/host/test/it/codex_profiles_test.dart | Codex: Codex is installed on PATH | green |
| agent-runtimes: Native Codex detection never borrows another application's private installation | Only a Windows batch shim exists | packages/host/test/it/codex_profiles_test.dart | Codex: Only a Windows batch shim exists | green |
| agent-runtimes: Native Codex detection never borrows another application's private installation | Only Tern has installed Codex | packages/host/test/it/codex_profiles_test.dart | Codex: Only Tern has installed Codex | green |
| agent-sessions: An agent session starts in the selected workspace | Start in a checkout | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | session/new receives cwd = workspace path (fixture reports it); launcher Claude Code opens a new tab with a chat pane bound to the selected workspace | green |
| agent-sessions: An agent session starts in the selected workspace | No workspace selected | packages/desktop/test/workbench_test.dart | Personal with no workspace marks Claude Code as needing one with Open folder and sends no agent/start | green |
| agent-sessions: An agent session starts in the selected workspace | Workspace unavailable | packages/host/test/it/agent_test.dart | agent/start for a deleted workspace folder is refused workspace-unavailable with no unit or record | green |
| agent-sessions: An agent session starts in the selected workspace | Codex launcher | packages/desktop/test/codex_agent_test.dart | Codex: Codex launcher | green |
| agent-sessions: An agent session starts in the selected workspace | Codex without a workspace | packages/desktop/test/codex_agent_test.dart | Codex: Codex without a workspace | green |
| agent-sessions: One turn runs at a time | Send while running | packages/desktop/test/agent_test.dart; packages/host/test/agent/agent_session_test.dart | focused agent UI Send disabled while running keeps unsent text; refusal and errors retain sent prompt; agent/prompt while running refused turn-running | green |
| agent-sessions: One turn runs at a time | Turn ends with a refusal | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | stopReason refusal returns to idle; focused agent UI Send disabled while running keeps unsent text; refusal and errors retain sent prompt | green |
| agent-sessions: One turn runs at a time | Prompt fails | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | prompt error returns idle with turnEnded error and preserves unmatched code/message; focused agent UI Send disabled while running keeps unsent text; refusal and errors retain sent prompt | green |
| agent-sessions: One turn runs at a time | Explicit steering is separate from Send | packages/desktop/test/codex_agent_test.dart | Codex: Explicit steering is separate from Send | green |
| agent-sessions: Reopen shows saved sessions and continues only on request | Continue through load | packages/host/test/it/agent_continue_test.dart; packages/desktop/test/agent_test.dart | Continue with load: replay start, replayed user agent tool events, replay end then idle; no prompt sent; agent controller Continue load shows ordered history and resume notice without sending a prompt | green |
| agent-sessions: Reopen shows saved sessions and continues only on request | Continue through resume | packages/host/test/it/agent_continue_test.dart; packages/desktop/test/agent_test.dart | Continue with resume only: notice earlier messages not shown then idle; next prompt reaches same native session; agent controller Continue load shows ordered history and resume notice without sending a prompt | green |
| agent-sessions: Reopen shows saved sessions and continues only on request | Reopen starts nothing | packages/desktop/integration_test/agent_reopen_test.dart | three saved chats and terminal split reopen unchanged with no agent unit; explicit Continue loads history | green |
| agent-sessions: Reopen shows saved sessions and continues only on request | Codex restores through native history | packages/desktop/test/codex_agent_test.dart | Codex: Codex restores through native history | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Stop a running turn | packages/host/test/it/agent_test.dart | Stop with a pending request delivers cancelled before cancel and keeps the same unit alive | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Turn finished first | packages/host/test/agent/agent_session_test.dart | prompt answered end_turn after Stop yields finishedFirst | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Adapter ignores the cancel | packages/host/test/agent/agent_session_test.dart; packages/host/test/it/agent_test.dart | Stop cancelled after deadline classifies actual result once; no answer by the stop deadline yields notConfirmed, stopping and no termination; close still ends it | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Turn errors after Stop | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | error answer after Stop yields endedWithError late; focused agent UI Stop button sends once, cancellation is visible, and late result replaces the deadline | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Turn ends after the stop deadline | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | Stop cancelled after deadline classifies actual result once; agent controller Stop outcome stopped is visible and late result replaces deadline line | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Codex native interruption completes | packages/desktop/test/codex_agent_test.dart | Codex: Codex native interruption completes | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | Root idle with active child | packages/desktop/test/codex_agent_test.dart | Codex: Root idle with active child | green |
| agent-sessions: Stop interrupts the turn and reports the actual result | One child interruption is unsupported | packages/desktop/test/codex_agent_test.dart | Codex: One child interruption is unsupported | green |
| agent-sessions: Closing a running agent asks for confirmation | Close an idle session | packages/desktop/test/codex_agent_test.dart | Codex: Close an idle session | green |
| agent-sessions: Closing a running agent asks for confirmation | Cancel closing a running session | packages/desktop/test/agent_test.dart | agent controller cancel close of running keeps split and sends nothing; idle confirmation rechecks evidence | green |
| agent-sessions: Closing a running agent asks for confirmation | Confirm closing a running session | packages/host/test/it/agent_close_test.dart | running close cancels permissions before cancel, terminates the tree and retains changed files and record | green |
| agent-sessions: Closing a running agent asks for confirmation | Tab with a running agent and a live terminal | packages/desktop/test/workbench_test.dart | agent launcher and generic close hook closing a tab with a running session and a live terminal shows one dialog naming both; confirm closes both and the tab | green |
| agent-sessions: Closing a running agent asks for confirmation | Turn ends while the confirmation is open | packages/desktop/test/agent_test.dart | agent controller cancel close of running keeps split and sends nothing; idle confirmation rechecks evidence | green |
| agent-sessions: Closing a running agent asks for confirmation | Close idle root with running child | packages/desktop/test/codex_agent_test.dart | Codex: Close idle root with running child | green |
| agent-sessions: Native authentication is reported, never managed | Not signed in | packages/host/test/it/agent_test.dart; packages/desktop/test/agent_test.dart | observed session/new authentication error reports auth-required and cleans up without a record; focused agent UI start failure Retry and typed authentication guidance preserve native error | green |
| agent-sessions: Native authentication is reported, never managed | Sign-in expires mid-session | packages/host/test/agent/agent_session_test.dart; packages/desktop/test/agent_test.dart | observed prompt authentication error returns idle with auth-required and exact native diagnostics; focused agent UI start failure Retry and typed authentication guidance preserve native error | green |
| agent-sessions: Native authentication is reported, never managed | Codex authentication is required | packages/desktop/test/codex_agent_test.dart | Codex: Codex authentication is required | green |
| agent-sessions: Native authentication is reported, never managed | Unrecognized Codex auth-like error | packages/desktop/test/codex_agent_test.dart | Codex: Unrecognized Codex auth-like error | green |
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
| agent-tool-access: Native audit coverage is explicit and bounded | Explicit changed-artifact coverage | packages/host/test/agent/native_home_audit_test.dart; packages/host/test/it/codex_tools_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex changed artifacts: selection | green |
| agent-tool-access: Native audit coverage is explicit and bounded | Legacy and invalid coverage selection | packages/host/test/it/codex_tools_test.dart; packages/host/test/it/release_contract_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex changed artifacts: binding | green |
| agent-tool-access: Native audit coverage is explicit and bounded | Protected entries or inventory bounds prevent completeness | packages/host/test/agent/native_home_audit_test.dart; packages/host/test/it/codex_tools_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex changed artifacts: refusal | green |
| agent-tool-access: Native audit coverage is explicit and bounded | Normal native home coverage | packages/host/test/agent/native_home_audit_test.dart; packages/host/test/it/codex_tools_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex normal home: | green |
| agent-tool-access: Native audit coverage is explicit and bounded | Native home sockets | packages/host/test/agent/native_home_audit_test.dart; packages/host/test/it/codex_tools_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex native sockets: | green |
| agent-tool-access: Native audit coverage is explicit and bounded | Removed native entries | packages/host/test/agent/native_home_audit_test.dart; packages/host/test/it/codex_tools_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex removed entries: | green |
| app-exit: Quitting with no affected work asks nothing | Quit with idle work | packages/desktop/test/exit_test.dart | Codex: Quit with idle work | green |
| app-exit: Quitting with no affected work asks nothing | Activity cannot be read in time | packages/desktop/test/exit_test.dart | activity timeout lists the terminal as may be running programs | green |
| app-exit: Quitting with no affected work asks nothing | Quit with idle root and active child | packages/desktop/test/exit_test.dart | Codex: Quit with idle root and active child | green |
| app-exit: The exit dialog lists every affected item | Agent turn and terminal program | packages/desktop/test/exit_test.dart | dialog lists running agent and vim with per-item Stop, bulk and Cancel | green |
| app-exit: The exit dialog lists every affected item | Item finishes while the dialog is open | packages/desktop/test/exit_test.dart | Codex: Item finishes while the dialog is open | green |
| app-exit: The exit dialog lists every affected item | Another quit while the dialog is open | packages/desktop/test/exit_test.dart | second quit request focuses the open dialog | green |
| app-exit: The exit dialog lists every affected item | Root finishes before child | packages/desktop/test/exit_test.dart | Codex: Root finishes before child | green |
| codex-sessions: Codex uses its native App Server connection | Start native Codex | packages/host/test/it/codex_test.dart | Codex: Start native Codex | green |
| codex-sessions: Codex uses its native App Server connection | Initialization fails | packages/host/test/it/codex_test.dart | Codex: Initialization fails | green |
| codex-sessions: Codex capability claims name the native runtime version | Qualified native recovery | packages/host/test/it/codex_test.dart | Codex: Qualified native recovery | green |
| codex-sessions: Codex capability claims name the native runtime version | Unsupported recovery | packages/host/test/it/codex_test.dart | Codex: Unsupported recovery | green |
| codex-sessions: Native turn acceptance and completion are distinct | Start acknowledgement precedes output | packages/host/test/it/codex_test.dart | Codex: Start acknowledgement precedes output | green |
| codex-sessions: Native turn acceptance and completion are distinct | Native input is full | packages/host/test/it/codex_test.dart | Codex: Native input is full | green |
| codex-sessions: Native turn acceptance and completion are distinct | Native transport breaks after admission | packages/host/test/it/codex_test.dart | Codex: Native transport breaks after admission | green |
| codex-sessions: Codex approvals and questions require explicit answers | Approve a command | packages/host/test/it/codex_test.dart; packages/desktop/test/codex_agent_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex: Approve a command; Codex: Ordinary command defaults require an explicit answer; Codex: Explicit command decisions remain authoritative; Codex: Empty or malformed command decisions stay unavailable; Codex: Special approvals do not use ordinary defaults; Codex decision display: | green |
| codex-sessions: Codex approvals and questions require explicit answers | Complete decision details do not fit | packages/host/test/it/codex_test.dart; tool/test/qualify_codex_app_server_test.dart | Codex decision overflow: | green |
| codex-sessions: Codex approvals and questions require explicit answers | Answer a structured question | packages/host/test/it/codex_test.dart | Codex: Answer a structured question | green |
| codex-sessions: Codex approvals and questions require explicit answers | Request is retired before answer | packages/host/test/it/codex_test.dart | Codex: Request is retired before answer | green |
| codex-sessions: Codex approvals and questions require explicit answers | Unknown native request | packages/host/test/it/codex_test.dart | Codex: Unknown native request | green |
| codex-sessions: Stop interrupts work without substituting process termination | Native interruption succeeds | packages/host/test/it/codex_test.dart | Codex: Native interruption succeeds | green |
| codex-sessions: Stop interrupts work without substituting process termination | Interruption cannot be confirmed | packages/host/test/it/codex_test.dart | Codex: Interruption cannot be confirmed | green |
| codex-sessions: Steering is an explicit operation on the current turn | Steer running work | packages/host/test/it/codex_test.dart | Codex: Steer running work | green |
| codex-sessions: Steering is an explicit operation on the current turn | Turn ended before steering | packages/host/test/it/codex_test.dart | Codex: Turn ended before steering | green |
| codex-sessions: Continue restores native history without executing it | Continue a saved thread | packages/host/test/it/codex_test.dart | Codex: Continue a saved thread | green |
| codex-sessions: Continue restores native history without executing it | Missing native history | packages/host/test/it/codex_test.dart | Codex: Missing native history | green |
| codex-sessions: Continue restores native history without executing it | Empty native thread has no resumable history | packages/host/test/it/codex_test.dart | Codex: Empty native thread has no resumable history | green |
| codex-sessions: Continue restores native history without executing it | Interactive capacity reached | packages/host/test/it/codex_test.dart | Codex: Interactive capacity reached | green |
| codex-sessions: Continue restores native history without executing it | Untracked child asks permission | packages/host/test/it/codex_test.dart | Codex: Untracked child asks permission | green |
| codex-sessions: Continue restores native history without executing it | Another runtime profile is the default | packages/host/test/it/codex_test.dart | Codex: Another runtime profile is the default | green |
| codex-sessions: Delegated activity preserves child identity | Child emits output | packages/host/test/it/codex_test.dart | Codex: Child emits output | green |
| codex-sessions: Delegated activity preserves child identity | Parent information is missing | packages/host/test/it/codex_test.dart | Codex: Parent information is missing | green |
| codex-sessions: Delegated activity preserves child identity | Nested and restored children | packages/host/test/it/codex_test.dart | Codex: Nested and restored children | green |
| codex-sessions: Child requests retain root authority and truthful status | Child asks permission | packages/host/test/it/codex_test.dart | Codex: Child asks permission | green |
| codex-sessions: Child requests retain root authority and truthful status | Root closes during child work | packages/host/test/it/codex_test.dart | Codex: Root closes during child work | green |
| codex-sessions: Child requests retain root authority and truthful status | Child outcome is unknown | packages/host/test/it/codex_test.dart | Codex: Child outcome is unknown | green |
| codex-sessions: Real Codex qualification is recorded separately from regression tests | Real Windows evidence passes | tool/test/check_qualification_test.dart; docs/qualification/codex-app-server.md | Codex: Real Windows evidence passes (checker); approved Windows section recorded by 8.3 (`mise run audit`: CODEX OBSERVATIONS: 0.166.0 windows: PASS) | green |
| codex-sessions: Real Codex qualification is recorded separately from regression tests | Tests pass but walk is unrun | tool/test/check_qualification_test.dart; packages/host/test/it/codex_profiles_test.dart | required unverified is INCOMPLETE without admission failure; absent native observations do not gate later compatible versions; Codex: Codex follows minimum-version compatibility codex-cli 0.167.0 | green |
| codex-sessions: Codex updates do not require a Kumiko version allowlist | Newer untested installed version | packages/host/test/it/codex_profiles_test.dart; tool/test/check_qualification_test.dart | Codex: Codex follows minimum-version compatibility codex-cli 0.167.0; absent native observations do not gate later compatible versions | green |
| codex-sessions: Codex updates do not require a Kumiko version allowlist | Experimental metadata changes in a newer version | packages/host/test/it/codex_test.dart | Codex: Experimental metadata changes in a newer version | green |
| codex-sessions: Codex updates do not require a Kumiko version allowlist | Missing or invalid version | packages/host/test/it/codex_profiles_test.dart | Codex: Missing or invalid version | green |
| codex-sessions: Codex updates do not require a Kumiko version allowlist | Initialization version mismatch | packages/host/test/it/codex_profiles_test.dart | Codex: Initialization version mismatch | green |
| codex-sessions: Codex updates do not require a Kumiko version allowlist | Below minimum | packages/host/test/it/codex_profiles_test.dart | Codex: Missing or invalid version codex-cli 0.165.99 | green |
| codex-sessions: Codex authentication stays native | Known Codex authentication failure | packages/host/test/it/codex_test.dart | Codex: confirmed account-unauthenticated refuses Start before thread/start; Codex: confirmed turn-http-401 classifies | green |
| codex-sessions: Codex authentication stays native | Unknown auth-like diagnostic | packages/host/test/it/codex_test.dart | Codex: Unknown auth-like diagnostic | green |
| desktop-host-protocol: Native Codex additions require a compatible peer | Compatible peers | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Compatible peers | green |
| desktop-host-protocol: Native Codex additions require a compatible peer | Older desktop | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Compatible peers; Codex: Older desktop missing | green |
| desktop-host-protocol: Extended control is sequenced and scoped to the native run | Answer the current question | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Answer the current question; Codex: Answer a structured question | green |
| desktop-host-protocol: Extended control is sequenced and scoped to the native run | Prior run sends a late answer | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Answer the current question; Codex: Prior run sends a late answer and steer without native writes | green |
| desktop-host-protocol: Child events retain attribution under bounded delivery | Two children use the same tool identifier | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Two children use the same tool identifier | green |
| desktop-host-protocol: Child events retain attribution under bounded delivery | Attribution capacity is exceeded | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart | Codex: Attribution capacity is exceeded | green |
| desktop-host-protocol: Codex control keeps the shared responsiveness contract | Stop while Codex output is stalled | packages/host/test/it/agent_qualification_test.dart | Codex: Stop while Codex output is stalled | green |
| desktop-host-protocol: Codex control keeps the shared responsiveness contract | Stalled native input | packages/host/test/it/agent_qualification_test.dart | Codex: Stalled native input | green |
| desktop-host-protocol: Active native turn identity reaches the desktop | Running turn identity published | packages/host_protocol/test/codex_messages_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: Running turn identity published | green |
| desktop-host-protocol: Active native turn identity reaches the desktop | Delayed prior-turn state | packages/host_protocol/test/codex_messages_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: Running turn identity published; Codex: Delayed prior-turn state | green |
| desktop-host-protocol: Delegated activity is reported in sequenced state | Child starts | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: Child starts | green |
| desktop-host-protocol: Delegated activity is reported in sequenced state | Child starts with no transcript credit | packages/host_protocol/test/codex_messages_test.dart; packages/host/test/it/codex_test.dart; packages/desktop/test/codex_agent_test.dart | Codex: Child starts with no transcript credit | green |

## 1. Record the reviewed architecture decision

- [x] 1.1 Write ADR 0015 from design D1-D7, including minimum Codex 0.166.0 with no pin/allowlist, limited supersessions and child identity. Update architecture diagrams, contracts, bounds and ADR index together. Verify ADR 0004/0005/0012/0013/0014 files remain byte-identical and every departure is indexed; run strict OpenSpec validation and git diff --check.
- [x] 1.2 Record the minimum installed executable version and its generated stable/needed experimental schema in docs/qualification/codex-app-server.md as contract research, with no provider observation claimed. Verify schema requests/responses for core and optional methods, safe private MCP config, version grammar (including prereleases), history omission/paging and npm native-launch environment. Resolve unsupported essential core contracts before coding; optional limitations use the reviewed unavailable behavior. No copied/ported reference implementation or generated source adoption without the existing license/approval rules.

## 2. Add the bounded native wire client

- [x] 2.1 Add red native transport tests in packages/host/test/agent/codex_client_test.dart and a scripted native App Server fixture. Cover initialize/initialized, optional unknown events, malformed core versus optional fields, request-before-response races, EOF/exit, post-response write failure and bounded request/input/output admission. Verify each behavior fails for the expected missing implementation before building it. Contained version-probe timeout and shared-start cleanup are verified in group 4, after their prerequisites.
- [x] 2.2 Implement the bounded native client and only wire mechanics actually needed by both clients. Define the narrow driver seam with AgentService/AgentSession retaining lifecycle ownership, preserving existing ACP behavior; native production startup/mapping is connected in group 4. Verify 2.1 plus acp_client_test.dart, agent_session_transport_test.dart, agent_event_relay_test.dart and agent_session_test.dart directly, then mise run check and mise run test:host before committing. Document ownership and bounds; no generic plugin framework or independently owned lifecycle. This group exposes no production Codex start.

## 3. Establish additive protocol contracts and pre-spawn gates

- [x] 3.1 Add failing codec and real Connection-pair tests in packages/host_protocol/test/codex_messages_test.dart and affected host/desktop suites, then implement additive capability gates, sequenced run/turn identity, questions/resolutions and steer DTOs. Verify missing agent/codex/agent-extensions-v1 refuses Codex start/Continue before any spawn, stale-run controls cause no native write, and Claude/terminals still work. No compatible native start is claimed before group 4. Run host-protocol and affected desktop suites; keep complete scenario-map rows red until their named end-to-end checks pass in groups 4-7.

- [x] 3.2 Correct terminal input qualification measurement (owner-approved 2026-11-10). Measure host-owned retained input directly, including queued/paused delivery and the writer-owned chunk, against the unchanged 576 KiB bound; keep aggregate completed writes and OS-dependent acceptance separate. Preserve the real fixture's byte-order and every-accepted-byte drain checks. Add meaningful red-first accounting/backpressure tests and expose measurements through test-host-only diagnostics without a new production control method or flow-policy change. Record the original 2,816 KiB versus 704 KiB failure and the isolated 8,192 KiB unobservable/skipped rerun in docs/qualification/windows-terminal-input-measurement.md; the skip does not clear the failure. Run affected tests directly, the terminal qualification file, mise run check and mise run test:host before ticking either group 3 task. Keep accepted ADRs and buffer limits unchanged; report any actual host-bound breach rather than weakening the check.

## 4. Integrate shared native startup, profiles and root controls

- [x] 4.1 Extend test-host scripting only, with real contained pipes; release binaries must reject fixtures/candidate overrides from the first fixture addition. Add failing shared AgentService startup rows in packages/host/test/it/codex_test.dart for startup failure, unit/channel release, contained version-probe timeout/cleanup. Verify these new rows fail before the corresponding implementation in 4.4. Rerun the group 3 capability-refusal rows through shared AgentService start and Continue as regressions that must stay green (not red-first rows here); the refusal precedes the contained version probe as well as the App Server spawn, with no unit launched and no channel left reserved. Add red rows proving that, until task 6.3 passes, a Codex start or Continue with the endpoint available registers no usable ToolGrant (or revokes it before any native write), sends no kumiko entry or secret in any native request, argv or environment, and reports tools unavailable with a Codex safe-delivery reason rather than endpoint-unavailable. A standalone UnitManager/client test does not satisfy shared-start admission or cleanup; no bare runtime version probe outside UnitManager. Codex discovery honours the existing test runtime PATH/DIRS overrides, and every fixture start selects its scripted profile explicitly (ADR 0012), so no test can launch an installed real Codex or make a provider call.
- [x] 4.2 Write red agent-runtimes rows in packages/host/test/it/codex_profiles_test.dart for discovery without npm execution, Windows native binary resolution, no Tern private scan, unsupported kind, existing-default preservation, host-side kind filtering for start/fresh recovery/Continue, and 0.166.0/newer/below-minimum/invalid/mismatched versions. Verify expected failures before implementation in 4.4. Compatible picker UI is verified in group 5; complete Continue/history is verified in group 6, without claiming those full scenarios here.
- [x] 4.3 Add red host native turn/approval/question/Stop/steering rows from codex-sessions and shared agent-sessions in codex_test.dart. Cover native ordering, request retirement, multi-turn races, atomic Stop admission, four aggregate outcomes, late completion/timeout, actual native choices, unsupported request denial, capacity refusal, secret redaction and stale async answers. Verify each fails for the expected missing behavior before implementation in 4.4. Desktop forms/Steer/drafts are verified in group 5; descendant aggregation is completed in group 7, with unknown child requests refused and attributed visibly from first native integration. Add red rows proving that items, deltas and tool updates from any non-root native thread are never appended to the root reply before group 7: they produce the bounded unknown-child notice and are withheld within the Resource Bounds unknown-child budget. Include the host rows Known Codex authentication failure and Unknown auth-like diagnostic for start and turn errors, with any signature supplied only through the test-host candidate override and never through Claude's classifier.
- [x] 4.4 Connect the narrow Codex driver through AgentService/AgentSession, implement detection/profile routing, the contained version probe and native root mapping/run-turn-request fencing together. Preserve existing reservations, legacy Claude rows, argv/env isolation, permission/Stop/draft ownership and the group 3 gates; do not create a duplicate test-only lifecycle. Verify 4.1-4.3 and retained green runtime-profile/qualification rows, existing Claude permission/Stop/draft tests and host release-capability tests pass. Document install/custom-profile/minimum-version guidance, driver ownership/bounds and core versus optional compatibility. Check native npm launcher environment behavior without copying code. Unknown optional shapes disable only their feature; tools remain visibly unavailable until safe delivery is proven in group 6. Run affected files directly, mise run check and mise run test:host before committing this group.

## 5. Connect the desktop to the usable native host path

- [x] 5.1 Add desktop Codex launcher/profile editing and runtime-specific native sign-in guidance with failing widget tests in packages/desktop/test/codex_agent_test.dart before implementation. Verify Codex starts in the selected workspace, no-workspace starts nothing, incompatible defaults open a compatible picker, and Claude New session/fresh recovery never switches runtime. Show Codex sign-in guidance only for a signature confirmed by recorded real evidence, applying a confirmed signature to every admitted Codex version (D7); unknown auth-like errors remain native diagnostics. Run existing agent_profiles_test.dart and agent_test.dart after implementation. Continue profile selection is exercised here; restored history is verified in group 6.
- [x] 5.2 Add failing codex_agent_test.dart rows for native approval choices, question forms, explicit Steer, sequenced run/turn identity and draft preservation, then implement the desktop controls against groups 3-4. Verify stale answers/turns cannot write natively, ordinary Send remains idle-only, and all host/desktop portions of the root interaction scenarios pass. Rerun existing Claude permission/Stop/draft and affected protocol regressions; keep child-dependent rows red until group 7.

## 6. Restore native history and deliver root-scoped tools

- [x] 6.1 Add failing recovery rows in packages/host/test/it/codex_test.dart, plus existing Continue regressions. Cover missing/empty native history, original target checks, duplicate Continue, compatible profile fallback, no prompt replay, snapshot/live deduplication and oversized history. Implement native restoration using the minimum schema's bounded history path. Verify red rows pass and legacy Claude load/resume tests still pass; document supported history limitations. Add and pass the desktop row Codex restores through native history in packages/desktop/test/codex_agent_test.dart.
- [x] 6.2 Add red agent-tool-access rows in packages/host/test/it/codex_tools_test.dart. Cover entry-only secret delivery, unrelated process/MCP environments, runtime-written file canaries, no safe-config path, existing user kumiko conflict, pending thread binding, revocation and the existing 4-connection grant cap. Verify failures before implementing per-run native config. No secret in parent env, argv, persisted config or logs; unsupported safe delivery stays visibly unavailable.
- [x] 6.3 Implement native MCP configuration and tool-status/failure routing without changing authorization. Verify 6.2 tests and every retained green agent-tool-access row pass, including session_info returning codex/codex-app-server/exact runtime version with the immutable root target and waiting for thread binding. Document the effective-config and canary verification procedures with no secret contents in output.

## 7. Preserve child activity and make close/quit truthful

- [x] 7.1 Add red child attribution/lifecycle rows in packages/host/test/it/codex_test.dart, delegated-state codec/routing rows in codex_messages_test.dart and desktop close/quit rows in codex_agent_test.dart and exit_test.dart. Test nested/replayed relationships, child tool-ID collisions, unknown parent, registry overflow, child requests, child bridge cap, Idle root with active children, Codex native interruption completes, One child interruption is unsupported and stalled transcript credit. Verify expected failures before implementation.
- [x] 7.2 Implement the bounded child registry/event identity and AgentSession-owned sequenced delegated summary. Render only the root delegated-activity summary and attributed child interactions; no full child browser or targeted child controls. Verify 7.1 rows turn green, conservative incomplete-state warnings remain and native loss never fabricates success. Keep the existing shared close/quit confirmation and settlement paths.
- [x] 7.3 Run retained app-exit, shared Stop/close and related root/child process tests. Verify root close kills all contained descendants, unresolved cleanup remains gated and no host/desktop transcript persistence was added. Update event/control and lifecycle documentation in this group, preserving ADR 0014's unaffected draft/terminal behavior.

## 8. Integrate evidence checks and qualify the completed path

- [x] 8.1 Add failing mechanical observation-checker rows in tool/test/check_qualification_test.dart for Codex PASS/INCOMPLETE/FAIL sections, required versus optional items, auth signature provenance, Windows scope and exact failure diagnostics; keep the map's Recorded failure matches evidence on Claude only. Implement backward-compatible checker/registry parsing and docs/qualification/codex-app-server.md procedure. Verify absent real observations stay unverified and do not block compatible Codex versions; existing Claude checker tests remain green.
- [x] 8.2 Rerun every retained green row's named suite and all new affected files directly through mise from their package directories. Then run mise run check, mise run test:host, mise run audit, openspec validate --all --strict and git diff --check. Verify all completed commands pass; rerun loaded-machine timing failures alone and retain any real breach rather than relabeling it. Do not claim unrun OS results.

  Reverified after the audit-budget implementation and guard corrections: affected direct suites, mise run check, mise run test:host (883 passed, 13 platform skips), audit, strict validation and diff checks pass. Native Windows observations remain INCOMPLETE.

  Reverified again after attempt 5's content-free refusal/error diagnostics: affected host and tool suites, mise run check (including 412 desktop tests), mise run test:host (899 passed, 13 platform skips), audit, strict validation and diff checking pass. All 46 cases matched by the audit-budget map prefixes pass without skips. Refusal/cancellation and audit read/selection semantics remain unchanged; these diagnostics do not reconstruct the missing historical causes or qualify the real path.

  Reverified after the decision display and changed-artifact amendment (2026-11-11). The credential/configuration filename research gate was completed first from installed 0.166.0 material: seven protected basenames, recorded in docs/qualification/codex-app-server.md. Then the work was implemented test-first. Direct suites passed: codex_test, codex_tools_test and release_contract_test (189 passed, 1 platform skip), native_home_audit_test and tool_file_audit_test (51), codex_agent_test (54), and the helper and checker tests (160). mise run check passed (414 desktop tests), as did mise run test:host (941 passed, 13 platform skips), audit, strict validation and diff checking. Every test matching the Codex decision display/overflow and Codex changed artifacts prefixes exists in each named file and passes, so map rows for those scenarios are green. Red-first evidence was observed for the unit, helper, desktop and host decision tests. The changed-artifact integration rows in codex_tools_test were first run after implementation. The release row passes unchanged, because release hosts already deny test methods. No real native-home metadata or content was read and no provider walk ran, so Windows remains INCOMPLETE.

  Owner-approved attempt 7 (manifest 8e12e774…, changed-artifacts-v1, large-native-home) aborted at the baseline preflight with 8 errors. No provider work or content scan ran, and the record and receipt hold it as INCOMPLETE. Two offline corrections followed, verified test-first: the preparation echo now carries content-free baseline category counters, and a baseline abort leaves launch unverified. Both gates were rerun afterwards. Owner-approved attempt 8 (manifest fb2c0359…) aborted the same way, with categories recorded: 1 metadataLimit and 7 nonRegular. Under the unchanged bounds, this native home cannot complete changed-artifacts-v1. The owner then chose to keep the normal home. The reviewed changed-artifacts-v2 amendment (Round 7, CHANGES_APPLIED yes) is implemented test-first: 65,536 entries, a counted retained-string budget, and unchanged root links accounted for through a no-follow FindFirstFileW observation. The coordinator fixed an extended-length path prefix bug, with a long-path real junction test seen failing first. The v2 integration rows in codex_tools_test and release_contract_test were first run after implementation. Reverified: affected host suites (268 passed, 1 platform skip), helper and checker (172), desktop codex_agent_test (54), mise run check (414 desktop tests), mise run test:host (969 passed, 13 platform skips), audit, strict validation and diff checking. No native-home read or provider walk ran for this verification. Owner-approved attempt 9 (manifest 56dac86c…, v2) aborted at the baseline with 2 nonRegular errors; an owner-approved metadata-only diagnostic identified 2 Unix-domain sockets. The reviewed socket amendment (Round 8, CHANGES_APPLIED yes) adds changed-artifacts-v3, implemented test-first with a real bound Windows AF_UNIX socket fixture (not skipped). Reverified: native_home_audit_test (60), helper tests (105), mise run check, mise run test:host (985 passed, 13 platform skips), audit, strict validation and diff checking. Owner-approved attempt 10 (manifest 9aa62426…, v3) had a complete baseline and passed launch, streaming and tool activity with 0 canary matches, but stayed incomplete on 5 removed entries and an unmatched canary command approval. The reviewed amendment (Round 9, CHANGES_APPLIED yes) adds changed-artifacts-v4 and a per-check approval diagnostic, implemented test-first; a v4 refusal guard covers the 65,536 bound and protected removals. Reverified: native_home_audit_test, tool tests (281), mise run check, mise run test:host (998 passed, 13 platform skips), audit, strict validation and diff checking. Owner-approved attempt 11 (manifest f8905414…, v4) failed before any session: its empty workspace folder had vanished between preparation and walk (target-unavailable), so no provider work or scan ran. The helper now refuses a walk before the claim unless the manifest workspace is still an existing, empty, ordinary directory, so such a fault cannot spend an approval; verified test-first (red: the walk claimed without the check), with tool tests (284), mise run check and audit. Owner-approved attempt 12 (manifest c7fc01bb…, v4) produced the first complete normal-home audit (0 errors, 101 files, 0 canary matches) and passed launch, streaming and tool activity; the per-check diagnostic shows the canary approval failing only commandMatches, because Codex's first preview line neither contains nor starts with the approved command. The reviewed native command wrapper amendment (Rounds 10 and 11 REVISE; owner decision on administrator trust; Round 12 APPROVE_WITH_CHANGES, CHANGES_APPLIED yes) keeps the exact rule and adds one exact registry-trusted PowerShell wrapper form, implemented test-first (red: the wrapper API was missing). Reverified: the `Codex approval wrapper:` tests (47, with real junction and registry fixtures on Windows), tool tests (331), mise run check, audit, strict validation and diff checking. Owner-approved attempt 13 (manifest a2ef2382…, v4) passed launch, streaming, tool activity and, for the first time, command approval, with a complete audit (106 files, 0 canary matches). Stop stayed unverified because the helper reads the running marker only from tool events tagged as command executions, while streamed output deltas arrive untagged; close containment and the kumiko tool call stayed unverified because the MCP environment probe wrote no report. Two offline corrections followed, test-first: the helper now reads command markers through a per-id tracker that joins untagged streamed output deltas with the command item they belong to (bounded carry, split markers and early deltas covered; red: the tracker was missing), and the MCP probe rewrites its report at each stage (started, initialized, listed, called) with boolean flags and its own identity only, which the walk records as a content-free mcpProbeStage with an mcpToolEvents count (red: no report before a call). Reverified: tool tests (helper suite plus 8 new rows), the two probe rows in codex_tools_test, mise run check, mise run test:host (999 passed, 13 platform skips; the saturating-terminal 250 ms row failed under load and passed alone), audit, strict validation and diff checking. No native-home read or provider walk ran for this verification. Owner-approved attempt 14 (manifest a4cc1d2d…, v4) passed launch, streaming, tool activity, command approval and, for the first time, Stop and close/descendant containment, with a complete audit (59 files, 0 canary matches). The kumiko tool call stayed unverified: the probe reached `listed` but was never called. Its tool declared no annotations, so Codex's default auto MCP approval mode asked for approval, which the host cancels as an unsupported elicitation. Two offline corrections followed, test-first: the probe declares `env_presence` read-only (readOnlyHint true, destructiveHint and openWorldHint false), as Kumiko's own read-only tools do (red: no annotations in the listing), and the walk diagnostics flag the cancellation notice as mcpElicitationCancelled (red: no flag). The always-zero mcpToolEvents counter was removed, because the host forwards only command and file-change items. Reverified: helper tests (184), the probe rows in codex_tools_test, mise run check, mise run test:host (999 passed, 13 platform skips; the same saturating-terminal timing row failed under load and passed alone), audit, strict validation and diff checking. Owner-approved attempt 15 (manifest 1e7c42ac…, v4) passed all seven walked required rows: launch, streaming, tool activity, command approval, Stop, close/descendant containment and the kumiko tool call (probe called, secret and endpoint absent), with a complete audit (59 files, 0 canary matches). Windows stays INCOMPLETE only on auth-required, which needs the separate isolated authentication experiment; that experiment is not approved.
- [x] 8.3 Prepare the bounded real Windows Codex walk, stating workspace, native version, operations and possible provider cost. Obtain the existing required approval before provider calls or isolated auth experiments. Record actual streaming, tool/approval, Stop, close/descendants, MCP and auth results; optional recovery/steering/questions/child observations stay separate. Scan Codex-written and Kumiko-profile files for the run-secret canary without printing it. If approval is deferred, leave this task unfinished and evidence unverified; never promote fixture results to real evidence.
- [x] 8.4 Verify scenario-map completeness mechanically, turn rows green only after their full named checks pass, and reconcile failed/unrun observations and future child-browser scope with the final documentation. Main three-OS CI and owner Windows daily use remain milestone-close evidence; this change must not claim them from local tests. No release bump: releases are disabled.

  Done (2026-11-13): all 138 delta scenarios have exactly one map row. Every
  named test was matched against the passing results of all suites (JSON
  reporter), plus the `agent_reopen_test` integration test with the test host.
  The only skip is the POSIX-only detector row, skipped on Windows. The
  "Known Codex authentication failure" row now names the structured-signal
  tests that replaced the old one. "Real Windows evidence passes" turned
  green on the audit's `0.166.0 windows: PASS`. The final status of the
  qualification record is in `docs/qualification/codex-app-server.md`.

## Task-order amendment traceability (2026-11-10)

At the task-order amendment checkpoint, completed tasks 1.1/1.2 and their
commit evidence were unchanged, and no other task had been ticked or
implemented. Its map changes were the Round 3 end-to-end file additions;
the table below preserves the mapping from every former pending task to its
revised owner. Subsequent verification changes are noted below.

| Former task | Revised task(s) |
|---|---|
| 2.1 transport and probe tests | 2.1 transport; 4.1 contained probe timeout/cleanup |
| 2.2 client/driver seam and mapping | 2.2 wire client/seam; 4.4 shared native integration |
| 2.3 fixture and shared-start integration | 4.1 red fixtures/startup; 4.4 green integration and release fence |
| 3.1 runtime/profile tests | 4.2 host tests; 5.1 picker/fresh recovery UI; 6.1 full Continue |
| 3.2 detection/routing/probe | 4.4 |
| 3.3 desktop launcher/profiles/guidance | 5.1 |
| 4.1 host and desktop control tests | 4.3 host; 5.2 desktop; 7.1 descendant cases |
| 4.2 mapping/fencing/negative cases | 4.3 red; 4.4 green; 5.2 desktop |
| 4.3 protocol/gates | 3.1 contracts/refusal; 4.1/4.4 native startup/routing; 5.2 controls; 7.1 delegated delivery |
| 5.1, 5.2, 5.3 | 6.1, 6.2, 6.3 respectively |
| 6.1, 6.2, 6.3 | 7.1, 7.2, 7.3 respectively |
| 7.1, 7.2, 7.3, 7.4 | 8.1, 8.2, 8.3, 8.4 respectively |
| Research record "group 3 fixtures" (docs/qualification/codex-app-server.md:111) | 4.2 red version/mismatch rows; 4.4 implementation |
| Owner-approved terminal qualification measurement correction (2026-11-10) | New task 3.2; existing host input bound and byte-order contract retained |

Group 8's executed file/name reconciliation later bound Tests pass but walk is
unrun to codex_profiles_test.dart and the checker. Stop while Codex output is
stalled and Stalled native input now name agent_qualification_test.dart rather
than the codec file, because their full checks exercise the shared live path.
Those reference corrections preserve scenario coverage and do not claim new
real-runtime or OS evidence. The command-approval row additionally follows the
reviewed clarification and its own new regression evidence below.

## Approval clarification amendment (owner-approved 2026-11-11)

Pending group 8 owns the new regression cases and correction for the expanded
Approve a command scenario. Historical task ticks and commit coverage remain
unchanged. After the amended design passes review, add and observe the failing
absent/null-default and explicit-list/refusal cases before implementing them.
Preserve the existing offered-choice regression. Verify no implicit answer,
native one-shot accept/cancel only for ordinary missing-list requests, unchanged
explicit lists, refusal of empty/malformed lists (native `decline` once, bounded
notice, run continues, including non-list, over-bound, non-string/non-object
entries and absent/null lists on non-ordinary command requests) and no ordinary
fallback for other command approval kinds or permission contexts. Preserve
well-formed unknown decision values verbatim. Retain run/thread/turn/request
fences, lifecycle retirement and no persistent default grant. Rerun the affected
host files, mise run check and mise run test:host before completing task 8.3.
The expanded map row stays red until its full named checks pass. Task 8.2 must
be reverified after code changes; tasks 8.3/8.4 remain unfinished. This amendment
authorizes no further real walk or isolated authentication experiment.
The planned Special approvals case covers command approvals only and does not
verify or modify the file-change choice set.

## Qualification audit budget amendment (owner-approved 2026-11-11)

Pending group 8 owns the D5 opt-in audit-budget correction before task 8.3 can
complete. The four consumed attempts and their failed/incomplete observations
remain unchanged; the fourth attempt's large mutable state/history files do
not fit the original audit limits. Keep default scans at 16 MiB/file and
32 MiB total, and add only the explicit large-native-home profile at 256 MiB/file
and 512 MiB total. Retain 4096 files, four confined roots and existing metadata
traversal bounds. Preparation stores the preset in scan.auditProfile, never the
top-level host-profile directory key profile; omitted prepare-only --audit-profile
records default and prints the effective limits with the hash. Validate the
option before creating artifacts. Add genuine failing scanner/manifest tests
before implementing: default/large selection; unknown/inconsistent limits;
legacy schema-2 without scan.auditProfile (default numbers only, top-level
profile unchanged); validated scan.roots used directly; rejection before attempt
claim or provider startup; --walk refusing any budget option before claim.
Bind auditProfile once through test/codex.audit.prepare before any agent run/scan,
reject unknown/late/repeated bindings, and forbid all budget overrides in
test/agent.stats. Test effective-limit echoes from preparation and scans; the
helper rejects a missing/mismatched preparation echo before agent startup or
content I/O, and a scan echo mismatch stays incomplete/unverified with a canary
failure preserved. Keep legacy unprepared fixture scans on the immutable default.
Test only owned synthetic files and injected I/O. Verify each read request is
at most min(1 MiB, remaining file allowance, remaining aggregate allowance).
An exactly 256 MiB stable file and exact aggregate-limit completion succeed
without an extra probe beyond the bound. Pre-read per-file oversize is unread
and incomplete; aggregate overflow reads only its remaining allowance and is
incomplete. After exhaustion, enumerate bounded metadata only; stable empty
files still count, nonempty/unknown sizes remain outstanding. Test every canary
split offset 1..length-1 across a chunk boundary and one-byte short reads; retain
matches even if that file then grows, fails or exhausts the budget. Reset carry
per file: a prefix and suffix split across two files must not match. A link or
non-regular leaf in workspace/profile or any other root is never followed and
makes the scan incomplete; normal directories are metadata traversal containers.
Use a chunked scanner with bounded memory; keep stable scannedBytes, returned
readBytes and conservative chargedBytes distinct, reserving attempted reads
before I/O and retaining the charge on a failed read with unknown byte count.
The test entrypoint admits only the two known profiles;
release hosts retain no audit RPC or budget control. Relevant implementation
files are agent_service.dart, a focused internal tool_file_audit.dart module
with an injectable stat/open/read interface used only by tool_file_audit_test.dart
and unreachable through RPC. Deterministically test throw-after-reservation
(full charge kept, chargedBytes > readBytes), short reads and post-read
instability, asserting scannedBytes <= readBytes <= chargedBytes <= maxTotalBytes
in every case. Cover the scanner in tool_file_audit_test.dart, test_hooks.dart
in the retained Codex tool/release tests, and the qualification helper in
tool/test/qualify_codex_app_server_test.dart.
Extend release_contract_test.dart with preset-bearing prepare/stats requests
and any preset environment input; release replies stay methodNotAvailable and
hello gains no capability. Prefixes in the privacy map row mean EVERY matching
test must exist and pass, covering every listed case; a passing subset cannot
turn the row green. The helper issues one actual scan per walk, with no retry.
The expanded privacy map row is red until every named suite passes; task 8.2
must be reverified with affected direct tests, mise run check, mise run test:host,
audit, strict validation and diff checking. Tasks 8.3/8.4 stay open. Review this
amendment before implementation. Preparation/review and offline fixture tests
authorize no real native-file content scan, provider walk, authentication
isolation or tracker write. Any later walk needs fresh exact-manifest approval
stating the larger limits; do not reuse any consumed approval.

## Complete decision display and changed-artifact amendment (owner-approved planning 2026-11-11)

Attempt 6 is recorded INCOMPLETE in the qualification record and its durable
receipt. Its 406-byte option name exceeds the unchanged 256-byte cap; the
580-byte preview fits. Its two audit errors identify changed model-cache and
other-directory classes, not clean content. Preserve all six attempt manifests,
observations and failure/incomplete states. This amendment invalidates the
earlier design verdict until a fresh external review passes. Historical task
ticks and commits remain intact; group 8 owns the follow-up before 8.3/8.4 can
complete. The changed Approve a command row and four new scenarios are red.
The 8.2 counts above describe the earlier frozen source; reverification of this
amendment remains pending. Planning/review authorizes no implementation, real
native-home metadata/content reads, provider walk, authentication experiment,
tracker write or reuse of a consumed approval.

After reviewed planning and a separate apply instruction, add genuine failing
tests before implementation in runtime_driver.dart/agent_session.dart and the
qualification helper. For object-containing command decision lists, keep
string names unchanged, index object labels by original position and append
the complete ordered JSON decision array to the preview. Test >256-byte JSON
objects with fitting full previews, unknown/nested values, exact ordered opaque
responses, root and child identities, current/retired requests, explicit-only
answers, absent/null defaults, file-change/additional-permission non-regression,
live/revoked secret redaction, multibyte strings and newline escaping. Assert every object kind is conservative allow_always, never allow_once, while exact response values and string kind mapping remain unchanged. Test a native string colliding with an indexed object label after redaction; cancel visibly with no partial offer. Keep the
existing final fidelity guard; test raw/JSON-encoded preview overflow, oversize
string names and no partial-scope offer. Use Codex decision display: in
packages/host/test/it/codex_test.dart, packages/desktop/test/codex_agent_test.dart
and tool/test/qualify_codex_app_server_test.dart; use Codex decision overflow:
in the host/helper files. Desktop coverage must show the full decision preview,
ordered options and exact selected opaque token without choosing anything
automatically. Include a command and an object decision containing triple
backticks and newlines, asserting the complete permission preview appears
unchanged as plain selectable text; do not use the transcript fence renderer
for permission display. The helper accepts only one literal string accept for the exact
approved canary/Stop command and cwd; reject object/session/policy-only choices,
duplicates, appended/malformed/ambiguous sections, different commands or cwd,
children, truncation and additional requests. A label index or allow_once kind
alone never authorizes a qualification answer.

Add failing Codex changed artifacts: selection tests in native_home_audit_test,
codex_tools_test and the helper tests. Cover explicit changed-artifacts-v1,
new/changed model cache and unclassified-directory descendants, unchanged parent
metadata with a changed child, metadata-equal ordinary files outside the
always-scan union and the recorded detector limit, legacy always-scan
union/deduplication, SQLite/WAL/SHM files inside unclassified subdirectories
whose metadata is unchanged, ordinary fully-accounted directory changes, no content in
diagnostics and selected-file canary matches through the existing scanner.
Codex changed artifacts: binding cases in codex_tools_test, release_contract_test
and helper tests cover absent/legacy defaults and old manifests, prepare-only
--native-selection validation before artifact creation, unknown/non-string
values, --walk/stats overrides, once-only closed two-key preparation, effective
echoes, missing/mismatched echoes, late/repeated preparation, sticky failures
and release denial with no new capability or environment control. Echo
baselineComplete/baselineErrorCount and refuse incomplete wider-mode baselines
before App Server/provider startup, with no fallback or prompt spent. Assert
the already-durable claim remains consumed and a failed baseline produces an
INCOMPLETE receipt with counters, baseline-preflight stage and explicit
no-provider/no-content-scan indicators; reuse is refused and another attempt
requires fresh exact-manifest approval. The binding helper tests assert the
fixed wider-read disclosure beside the hash in changed-artifacts-v1, its
absence in legacy, canonical scan.nativeScope validation before claim, and
that the text enumerates the effective protected set and warns that other
credential-bearing stores may be read. Before implementation, complete the
minimum-version credential/configuration filename research record from
documentation/installed protocol evidence and extend the closed protected
set, disclosure and tests for every other known name; unresolved known names
block implementation. No native-home inspection is authorized by that research.

Codex changed artifacts: refusal cases in native_home_audit_test, codex_tools_test
and helper tests cover auth.json/config.toml leaves at every depth (Windows
case-insensitivity), changed/new/removed protected entries, removed ordinary
entries, missing/unstable files, directory membership changing mid-enumeration,
symlinks/junctions/nonregular entries, metadata admission overflow and existing
byte/file exhaustion. Use only owned fixtures/injected I/O. Test iterative
4096-entry admission including duplicates/directories, upstream stop, no growing
pending queue and no protected content reads, including under always-scan paths. Observe
maximum pending entries/depth through a test-only injected lister, not merely
the absence of a recursion error.
Retain scanner resource/match tests and counters. Every matching case in every
named file must pass; do not promote a row from a subset. Reverify affected
direct suites, mise run check, mise run test:host, audit, strict validation,
scenario-map completeness and whitespace before updating 8.2's receipt. A
separate exact-manifest approval must disclose the broader private-content
scope before any later real metadata inventory/content scan or provider walk.

## Normal-home amendment (owner-approved 2026-11-12)

The owner chose to qualify against the normal native home rather than a
dedicated one. Attempts 7 and 8 stay recorded as INCOMPLETE, and their
manifests keep their changed-artifacts-v1 meaning. An owner-approved count-only
listing (13,116 non-link entries, 7 links) sized the new bound. Design D5's
normal-home bullet adds changed-artifacts-v2. Its inventory bound is 65,536
entries. Unchanged native-home-root links are accounted for as no-follow leaf
metadata, including their target text, which is never emitted. The disclosure
adds the unchanged-link and concurrent-writer limits and the owner pause of
other Codex sessions. The "Protected entries or inventory bounds" row is red
again, because its wording changed. The new "Normal native home coverage" row
is red.

After review and a separate apply instruction, add genuine failing tests
before implementing. Name them `Codex normal home:` in native_home_audit_test,
codex_tools_test and the helper tests. Cover:
- 4097..65,536 admitted entries and overflow at 65,536 (including directories,
  links and duplicates), with v1 still stopping at 4096.
- Unchanged links accounted for, and added, removed and retargeted links.
- Type and metadata changes of a link.
- Links named like protected leaves.
- Other non-regular entries.
- Links in workspace and profile roots, still refused.
- Target text absent from every echo, receipt, diagnostic and summary.
- No link followed or opened, through an injected lister.
- v2 echo, binding, manifest and canonical-disclosure validation, with v1
  and legacy unchanged.
- Baseline preflight and INCOMPLETE receipt for v2.
- Storage budget: deterministic long-path and long-target cases, the
  4096-byte string bound, exhaustion of the per-inventory and the combined
  budget while the baseline is live, upstream stop and the `metadataStorage`
  category, with v1 unaffected.
- Link acquisition: separate owned real Windows junction and symlink fixtures
  through the real `observeLink`. Also injected failures, unsupported kinds and
  an unstable re-observation (`linkObservation`), link/file/directory
  transitions, protected-name links, and non-Windows links staying
  `nonRegular`. Comparison tests with injected observations alone do not
  satisfy acquisition coverage.
- Receipts and the canonical disclosure carry the fixed link and
  concurrent-writer detector limits, with no target text or arbitrary names.
  The helper allowlists `metadataStorage` and `linkObservation`.

Keep all scanner file and byte limits. Reverify affected direct suites, mise
run check, mise run test:host, audit, strict validation and diff checking
before updating 8.2's receipt. A later walk needs fresh exact-manifest approval
that states the v2 disclosure and the pause of other Codex sessions. Planning
and review authorize no implementation or native-home read.

## Socket amendment (owner-approved 2026-11-12)

Attempt 9 (v2) stopped at the baseline with 2 `nonRegular` errors. An
owner-approved metadata-only diagnostic found two Unix-domain sockets. Design
D5's socket bullet adds changed-artifacts-v3; v2 keeps its meaning for the
consumed attempt-9 manifest. The new "Native home sockets" row is red.

After review, add genuine failing tests named `Codex native sockets:` in
native_home_audit_test and the helper tests, then implement. Cover:
- An unchanged socket accounted for (`socketsAccounted`), and added, removed
  and metadata-changed sockets counted in `socketsChanged` without an error
  and never selected.
- Acquisition through the real find-data path, never a target read: the
  AF_UNIX tag is supported; another tag, a missing record, a missing
  reparse-point attribute or a differing immediate re-observation (tag, type
  or metadata change) is `linkObservation`.
- A real Windows AF_UNIX socket the test binds in an owned short temporary
  folder, observed through the real `FsNativeInventoryIo`. If binding is
  impossible on the machine the test records a skip and Windows acquisition
  stays unverified: the row is not green on injected records alone.
- Protected-name sockets, socket/file/directory/link transitions, sockets on
  other operating systems and under v2 staying `nonRegular`.
- No socket name, path or extension in any echo, receipt or summary.
- v3 echo, binding, manifest and canonical-disclosure validation; the helper
  allowlists `socketsAccounted` and `socketsChanged`; v2, v1 and legacy
  unchanged.
- Host boundary (codex_tools_test): v3 preparation and result echoes,
  once-only binding, baseline refusal and release denial.

Reverify the direct suites, mise run check, mise run test:host, audit, strict
validation and diff checking before updating 8.2's receipt. Attempt 10 needs
fresh exact-manifest approval stating the v3 disclosure and the pause of other
Codex sessions.

## Removed-entry and approval-diagnostic amendment (owner-approved 2026-11-12)

Attempt 10 (v3) passed launch, streaming and tool activity with a complete
baseline and 0 canary matches. It stayed incomplete on 5 `removedEntry` errors
and on a canary command approval refused as `outside-approved-request`, with
no way to tell which match check failed. Design D5's removed-entries bullet
adds changed-artifacts-v4 and a per-check approval diagnostic. v3 keeps its
meaning for the consumed attempt-10 manifest. The new "Removed native entries"
row is red, and the "Protected entries or inventory bounds" row is red again
because its wording now names v4.

After review, add genuine failing tests named `Codex removed entries:` in
native_home_audit_test, codex_tools_test and the helper tests, then implement.
Cover:
- Removed non-protected file, directory (with descendants), link and socket
  counted in `removedEntries` with no error and nothing selected.
- Removed protected file, link and socket still `protectedEntry`.
- Traversal, metadata, storage and admission errors that drop entries from
  the after-run inventory still counted in their own categories and
  incomplete.
- A canary moved to a new file is scanned and matched.
- Earlier selections keep their removal behaviour: v3 keeps `removedEntry`
  errors for removed files, directories and links and keeps counting a removed
  non-protected socket in `socketsChanged`; v2, v1 and legacy keep
  `removedEntry` for every removed entry they inventoried, with their existing
  unsupported-socket behaviour unchanged.
- No removed name or path in any echo, receipt or summary.
- v4 echo, binding, manifest, canonical disclosure, baseline preflight and
  release denial.
- Helper: the command-approval refusal diagnostic carries one boolean per match
  check, the contains/starts-with flags and the line and option counts. It
  carries no command, path, option name or decision value. It also covers the
  remaining guards (valid operation, configured command is a string, no CR or
  LF in it) next to the existing title and truncation fields. Each check is
  exercised failing alone. The diagnostic never takes part in selection, and
  the match rule refuses exactly as before.

Reverify the direct suites, mise run check, mise run test:host, audit, strict
validation and diff checking before updating 8.2's receipt. Attempt 11 needs
fresh exact-manifest approval stating the v4 disclosure and the pause of other
Codex sessions.

## Native command wrapper amendment (owner-approved 2026-11-12, revised after Rounds 10 and 11)

Attempt 12 (v4, Codex 0.166.0) produced the first complete normal-home audit
and passed launch, streaming and tool activity. Its canary approval failed only
the command check; the observed form was not recorded. A study of Codex 0.165
source suggests, without proving it for 0.166.0, that the approval command is a
POSIX shell-word join of Codex's PowerShell wrapper argv around the approved
command. Design's "Qualification answer fence: native command wrapper" bullet
keeps the exact rule and adds one exact wrapper form with a registry-trusted
shell, under the owner's administrator trust assumption (ACLs not inspected). No spec scenario changes; this is a helper rule.

After review, add genuine failing tests named `Codex approval wrapper:` in the
helper tests, then implement. Cover:
- The exact rule still matches as before and records no wrapper fields.
- A join of `[<trusted powershell.exe>, -Command, <approved>]` and of
  `[<trusted pwsh.exe>, -NoProfile, -Command, <approved>]` matches, for both
  the canary and the Stop command, in several valid quoting styles, including
  a differently cased spelling of the trusted path.
- Decoder table: quoted empty words, adjacent quoted and unquoted fragments,
  escaped operators outside quotes, double-quoted backslash before special and
  ordinary characters, single-quote literals, trailing escape, unterminated
  quotes, runs of spaces, leading and trailing spaces, tab, newline, NUL and
  U+007F, each refused unquoted operator or expansion character, unescaped `$`
  and backquote inside double quotes, and input with no words.
- Refused shells: a path absent from the trusted set (including one with a
  PowerShell basename), relative, drive-relative, root-relative, UNC, `\?\`
  and `\.\` forms, `/` separators, `.` or `..` segments, doubled separators,
  and a non-ASCII lookalike. Refused shapes: other, repeated or lowercase
  flags, `-EncodedCommand`, a flag after `-Command`, missing `-Command`, extra
  words and a last word differing in one code unit. An empty trusted set never
  matches.
- Trusted-set resolution through a registry seam, each candidate judged on
  its own: Windows PowerShell and each PowerShell 7 install location are
  admitted only as existing regular drive-letter files reached without any
  link, junction or reparse point in the file or an ancestor directory. A
  missing file, a file link, an ancestor junction, a non-drive path and a
  failed registry query each exclude only their own candidate; a mixed case
  keeps the valid one. Real resolution on Windows finds Windows PowerShell.
- The walk refuses before the claim, with the approval unspent, when the
  trusted set is empty.
- Valid wrappers report `wrapperMatches: true` with `wrapperNoProfile: false`
  for the three-word shape and `true` for the four-word shape.
- Diagnostic positions for parsed but malformed shapes: an extra word, a
  misplaced flag and `-NoProfile` without `-Command` each give the positional
  flags of design item 6.
- One synthetic full wrapper join with a shell path containing spaces and an
  approved script containing single quotes, dollar signs and backslashes.
- The unchanged fence: a wrapper match with a wrong title, truncation, an
  invalid operation, an invalid configured command, a wrong working directory,
  layout, reason line, decisions line or accept option is refused, and the
  caller still refuses a second approval request.
- The diagnostic fields follow design item 6 exactly (absent after an exact
  match; parse failure gives 0 words and false flags), carry no text, path or
  command, and never select an option.

Reverify the helper tests, mise run check, audit, strict validation and diff
checking before updating 8.2's receipt. Attempt 13 needs fresh exact-manifest
approval stating the v4 disclosure and the pause of other Codex sessions.

## Structured authentication signal amendment (owner-approved 2026-11-12)

Attempt 15 passed every walked required row; only auth-required stayed
unverified. An owner-approved isolated observation showed that signed-out Codex
0.166.0 never answers a request with an error. It reports `account/read`
`account: null` with `requiresOpenaiAuth: true`, and fails the turn with
`codexErrorInfo` `httpConnectionFailed` 401 after retries. Design D7's
"Structured authentication signals" bullet replaces Codex (code, message) pairs
with the closed signals `account-unauthenticated` and `turn-http-401`. No spec
scenario changes.

After review, add genuine failing tests, then implement. Cover:
- Driver preflight (Start only): `config/read` for the start `cwd` and
  `account/read` with `refreshToken: false` run before `thread/start`. A
  confirmed `account-unauthenticated` fails Start with auth-required, with no
  `thread/start` and no new record. Each of these lets the start continue
  unchanged:
  - an unconfirmed signal;
  - an effective `model_provider` other than absent or `openai`;
  - an unreadable configuration;
  - a present account;
  - `requiresOpenaiAuth` false or absent;
  - a malformed result, a native error, method-not-found or a timeout.

  Continue never runs the preflight: a saved conversation resumes even when
  the default account is unauthenticated (regression case), and its next turn
  is classified by `turn-http-401`.
- Turn signal: a failed `turn/completed` whose `codexErrorInfo` is one of the
  four status variants with `httpStatusCode` 401 ends auth-required when
  confirmed, with the record unchanged and the root Idle when no Stop is
  pending. The same completion after Stop keeps D4's aggregation: Stopping
  while an addressed child is outstanding, and *Stop not confirmed* for a
  completion after the Stop deadline, each with the auth guidance. Other
  statuses, the `unauthorized` string, extra keys, a non-integer status, `willRetry` error
  notifications, and an unconfirmed signal stay bounded native errors.
- Registry and override: tuples carry signal names; the projection keeps names
  only; the test-host override accepts a JSON list of known names and refuses
  unknown names; release builds refuse the override.
- Checker: a Codex auth-required pass names known signals, in fixed order, in
  the Auth code cell with an empty message cell. Registry tuples and recorded
  passes must match both ways. Unknown names, duplicates, a non-empty message
  cell, wrong order, and a pass naming no signal fail. Claude rows are
  unchanged.
- Desktop: the existing Codex sign-in guidance and Retry appear for both
  signals.
- Helper auth experiment: prepare and walk modes with their own manifest and
  exact approval. Each isolated home must be owned, empty and distinct from
  the native home, at prepare and at walk. The host environment carries no
  `OPENAI` or `CODEX` variables apart from `KUMIKO_TEST_*`, and the walk
  refuses before the claim otherwise. Operation A expects auth-required at
  Start before `thread/start`, operation B auth-required on the turn. Content-free outcomes are
  recorded, the canary scan covers the owned roots, and the isolated homes are
  deleted afterwards.

Reverify the affected host, desktop and tool tests, mise run check, mise run
test:host, audit, strict validation and diff checking. The real experiment
needs fresh exact-manifest approval.

Done (2026-11-12): implemented test-first and reverified (mise run check,
mise run test:host, audit, strict validation, diff check). The signal enum
lives in `codex_auth_signal.dart`, so the registry file stays a pure literal
for the checker. `HostLauncher` gained `includeParentEnvironment` so the
experiment host starts without inherited OpenAI or Codex variables. The
checker reads the default registry only together with the Codex record. The
owner approved experiment manifest `d06cce69…19b6f`. Operation B observed
`turn-http-401` through Kumiko. Operation A's preflight failed open (Start
succeeded), so `account-unauthenticated` stays unobserved and unregistered.
The registry holds `('0.166.0', 'windows', 'turn-http-401')`, and Windows
0.166.0 is PASS (receipt
`docs/qualification/codex-app-server-windows-auth-experiment-2026-11-12.json`).

## Workflow follow-up

- Every group that changes packages/host, packages/host_protocol or process containment runs mise run check and mise run test:host before it is ticked and committed; desktop-only groups run mise run check plus the affected flutter test files.

- Apply uses group commits and fresh workers where required by the installed apply skill; the coordinator verifies before ticking and committing.
- After all implementation and evidence tasks are satisfied, run the separate verification/archive/PR workflows. Planning completion authorizes no implementation, archive, push or merge.
- The future subagent browser reads preserved native child identities/history; its UX, targeted child controls and independent child authority need a separately reviewed change.
