# M1 walk

Record of the M1 exit-criteria walk for change `app-exit-and-reopen` (task 8.2, design D6). Every criterion in `openspec/roadmap.md` (M1 exit criteria) has one row per OS. M1 cannot close while any row is `unverified`, `pending` or `fail`.

## How to read this record

- **Result:** `pass`, `fail`, `unverified` or `pending`.
  - `pass` needs evidence that was opened and checked: the test asserts the criterion and runs on that OS.
  - `unverified` means no one has verified it. For Linux and macOS user items that is the user's decision of 2026-11-02. For other rows the evidence column says why.
  - `pending` is used only for Windows user items still to be run with the user. It is replaced by `pass` or `fail` before task 8.2 is complete.
- **Kind:** `agent` (scripted or automated) or `user` (a person at the app), as the roadmap marks each criterion.
- **Verifier:** `agent (Claude)`, `user`, or `none` (nobody; the row is `unverified`).
- **Date:** the date of the verification. For `unverified` Linux and macOS rows it is the date of the user's decision. `-` for `pending`.
- **Test paths** are relative to `packages/`. **CI** is the run [42486331623][ci] (2026-11-08, `workflow_dispatch` on branch `ci/app-exit-verify`), green on `windows-latest`, `ubuntu-latest` and `macos-latest`, at commit `5f724ba` (feature tip `15a2e91` plus the uncommitted task 8.1 tests). Where a row cites a test as passing on an OS, the test's line is in that job's log under the `Test` step (`mise run test`) or the `Desktop integration test` step. I read those logs and confirmed the test passed and was not skipped on that OS.
- Windows-only skip annotations and `testOn` were checked for each cited test. Where a test is skipped on an OS, the row says so.

[ci]: https://github.com/sh1ny/kumiko/actions/runs/42486331623

## Exit criteria

### 1. CI builds the desktop app with its bundled host on three OSes

`.github/workflows/ci.yml` step "Build desktop release with the host bundled" runs `flutter build`, `tool/bundle_host.dart --skip-build`, checks the bundled host is executable (and on Windows that `conpty.dll` and `OpenConsole.exe` are beside it), then uploads the archive. All steps of every job in the CI run succeeded.

The criterion says "from main". The latest main run, 42457769893 (commit `ba7a5de`, 2026-11-08), is red: one Linux test failed (`agent_test.dart`, "unlisted version claims the baseline only"), so the Linux build step did not run there (see the intermittent failures section). The last green main run is [41753030815](https://github.com/sh1ny/kumiko/actions/runs/41753030815) (`313ea3d`, 2026-11-04), whose build steps succeeded on all three OSes. A green main run on the merged result still has to follow the merge.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| CI builds desktop with bundled host | Windows | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] job `build (windows-latest)`, step "Build desktop release with the host bundled"; main run 41753030815 |
| CI builds desktop with bundled host | Linux | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] job `build (ubuntu-latest)`; main run 41753030815 |
| CI builds desktop with bundled host | macOS | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] job `build (macos-latest)`; main run 41753030815 |

### 2. The dependency audit finds no analytics, crash-report or remote-logging package

`mise run audit` runs `tool/audit_dependencies.dart` (a denylist of exact names and the substrings `analytics`, `crashlytics`, `telemetry`, `crash_report`, `sentry`, `bugsnag`, `datadog`, over the resolved graph with dev dependencies). The log of each job prints `Checked 125 packages` and `Dependency audit passed.` The tool's own tests are `tool/test/audit_dependencies_test.dart` ("denylisted transitive package fails with path", "substring pattern matches and allowlist overrides it").

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Dependency audit finds no analytics, crash-report or remote-logging package | Windows | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] step "Audit dependencies": "Dependency audit passed." |
| Dependency audit finds no analytics, crash-report or remote-logging package | Linux | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] step "Audit dependencies": "Dependency audit passed." |
| Dependency audit finds no analytics, crash-report or remote-logging package | macOS | agent | pass | agent (Claude) | 2026-11-08 | [CI][ci] step "Audit dependencies": "Dependency audit passed." |

### 3. First launch opens Personal with no prompt, and a terminal opens at once

Automated support, not a substitute for the user item: `desktop/integration_test/workbench_reopen_test.dart` "fresh profile opens Personal with no tab, the empty state and no prompt" and `desktop/integration_test/terminal_test.dart` "terminal first launch shows the empty state; New terminal opens a terminal in Personal and Split right a second shell" both passed on all three OSes in [CI][ci].

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| First launch: Personal, no account/project/server/network prompt, terminal at once | Windows | user | pass | user | 2026-11-08 | User walk step 1, fresh profile, release build of 15a2e91: "yes" |
| First launch: Personal, no account/project/server/network prompt, terminal at once | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| First launch: Personal, no account/project/server/network prompt, terminal at once | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 4. Terminals run the user's shell from an argv profile

Automated support, not a substitute: `host/test/it/terminal_test.dart` "terminal runs the profile executable under a PTY (isatty true, fixture shell prints its argv and cwd)" passed on all three OSes. `host/test/it/profiles_test.dart` "Windows with pwsh and Nushell installed: three built-ins with resolved paths" checks detection with stand-in executables, not the real shells. No automated test starts PowerShell, Nushell, bash, fish or zsh as the user's shell through the app.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Terminal runs the user's shell from an argv profile: PowerShell | Windows | user | pass | user | 2026-11-08 | User walk step 2, idle then closed: "as expected"; the profile `builtin:pwsh` is in the walked layout |
| Terminal runs the user's shell from an argv profile: Nushell | Windows | user | pass | user | 2026-11-08 | User walk step 2, idle then closed: "as expected"; the profile `builtin:nu` is in the walked layout |
| Terminal runs the user's shell from an argv profile: bash | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Terminal runs the user's shell from an argv profile: fish or zsh | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 5. The adopted terminal engine passes the daily-driver bar

The bar and its adoption record are in `openspec/changes/archive/2026-10-31-host-terminals/spike-results.md` (adopted candidate `flutter_alacritty (patched)`, ADR 0006 and 0010). Linux and macOS user items there read `unproven` since 2026-10-29. Here they read `unverified`, user decision 2026-11-02. The record's Windows user items were passed by the user on 2026-10-30. They are `pending` here because the engine and host have changed since, and the user decides whether that run stands or is repeated.

Agent items were re-run in [CI][ci]:
- Colour, Unicode and bracketed paste: `desktop/integration_test/terminal_bar_test.dart`, tests "colour: 256 indexed and 24-bit colours" (all 256 indexed foregrounds and the true-colour samples read back from the grid), "unicode: wide characters and emoji widths" (CJK and emoji take two cells with a spacer, ASCII one), "input: bracketed paste arrives wrapped once" (the program receives `ESC[200~` text `ESC[201~` once). All passed on the three OSes.
- Throughput: `desktop/integration_test/profile/terminal_throughput_test.dart` "throughput: 100 MB cat completes; Ctrl+C ends it in 1 s", in the CI step "Desktop integration test (profile)". The test requires exit status 0, every byte received, and Ctrl+C ending a still-running writer in under 1 s. It prints frame times without judging them on CI (software rendering).
  - Windows: 107,507,368 of 105,902,742 bytes in 5,363 ms; Ctrl+C 46 ms.
  - Linux: 107,507,329 bytes in 12,263 ms; Ctrl+C 29 ms.
  - macOS: 107,509,069 bytes in 3,887 ms; Ctrl+C 20 ms.
- vttest subset: `terminal_bar_test.dart` "conformance: vttest subset, replayed transcripts" passed on all three OSes. "conformance: vttest subset, live through the host" passed on Linux and macOS (vttest 2.7) and is skipped on Windows (`skip: host.os == HostOs.windows`), where only the replay runs, as the host-terminals record specifies. The 22 screens, the 16 judged and the exclusions are in the record's "vttest subset" section.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux; modifiers, function and navigation keys; mouse reporting | Windows | user | pass | user | 2026-11-08 | User walk step 3: reported working. The user did not name the programs; tmux does not run natively on Windows and was not separately confirmed. Earlier user pass 2026-10-30 used Midnight Commander, Neovim, Helix (spike-results.md) |
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux; modifiers, function and navigation keys; mouse reporting | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux; modifiers, function and navigation keys; mouse reporting | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Colour: 256 colours and 24-bit true colour | Windows | agent | pass | agent (Claude) | 2026-11-08 | desktop/integration_test/terminal_bar_test.dart "colour: 256 indexed and 24-bit colours"; [CI][ci] |
| Colour: 256 colours and 24-bit true colour | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Colour: 256 colours and 24-bit true colour | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Input: bracketed paste | Windows | agent | pass | agent (Claude) | 2026-11-08 | desktop/integration_test/terminal_bar_test.dart "input: bracketed paste arrives wrapped once"; [CI][ci] |
| Input: bracketed paste | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Input: bracketed paste | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Input: CJK IME composition commits the right text | Windows | user | pass | user | 2026-11-08 | User walk step 3: "even japanese works" |
| Input: CJK IME composition commits the right text | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Input: CJK IME composition commits the right text | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Unicode: wide characters and emoji widths | Windows | agent | pass | agent (Claude) | 2026-11-08 | desktop/integration_test/terminal_bar_test.dart "unicode: wide characters and emoji widths"; [CI][ci] |
| Unicode: wide characters and emoji widths | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Unicode: wide characters and emoji widths | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Throughput: 100 MB cat completes, Ctrl+C interrupts promptly | Windows | agent | pass | agent (Claude) | 2026-11-08 | desktop/integration_test/profile/terminal_throughput_test.dart "throughput: 100 MB cat completes; Ctrl+C ends it in 1 s"; 5,363 ms, Ctrl+C 46 ms; [CI][ci] |
| Throughput: 100 MB cat completes, Ctrl+C interrupts promptly | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; 12,263 ms, Ctrl+C 29 ms; [CI][ci] |
| Throughput: 100 MB cat completes, Ctrl+C interrupts promptly | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; 3,887 ms, Ctrl+C 20 ms; [CI][ci] |
| Throughput: UI does not freeze (frames under 100 ms) on real hardware | Windows | user | pass | agent (Claude), on the user's machine | 2026-11-08 | `flutter drive --profile` with `KUMIKO_GATE_FRAMES=true` on the user's Windows machine, 2026-11-08: `BAR throughput: pass`, 107,507,368 bytes in 1,626 ms, 215 frames, worst 24 ms, 0 at or over 100 ms; `BAR interrupt: pass`, 15 ms after Ctrl+C |
| Throughput: UI does not freeze (frames under 100 ms) on real hardware | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Throughput: UI does not freeze (frames under 100 ms) on real hardware | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Resize: rapid resize storm leaves shell and TUI consistent | Windows | user | pass | user | 2026-11-08 | User walk step 3: reported working |
| Resize: rapid resize storm leaves shell and TUI consistent | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Resize: rapid resize storm leaves shell and TUI consistent | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Conformance: vttest subset (cursor movement, screen features, character sets) | Windows | agent | pass | agent (Claude) | 2026-11-08 | desktop/integration_test/terminal_bar_test.dart "conformance: vttest subset, replayed transcripts"; replayed, not through ConPTY (live test is skipped on Windows); [CI][ci] |
| Conformance: vttest subset (cursor movement, screen features, character sets) | Linux | agent | pass | agent (Claude) | 2026-11-08 | same file, "replayed transcripts" and "live through the host" (vttest 2.7); [CI][ci] |
| Conformance: vttest subset (cursor movement, screen features, character sets) | macOS | agent | pass | agent (Claude) | 2026-11-08 | same file, "replayed transcripts" and "live through the host" (vttest 2.7); [CI][ci] |
| Selection, copy and scrollback search | Windows | user | pass | user | 2026-11-08 | User walk step 3: reported working |
| Selection, copy and scrollback search | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Selection, copy and scrollback search | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 6. Control stays responsive under saturation and a stalled consumer (ADR 0002)

The criterion has three parts, each with its own test, because they fail independently.
- **(a) Stop and permission replies.** `host/test/it/agent_qualification_test.dart` "saturating terminal A, stalled session B: Stop and permissionReply in C ack worst of 100 each <= 250 ms and C events keep flowing" asserts worst-of-100 acks for Stop and permission reply at or under 250 ms while C's events keep flowing. Measured in [CI][ci]: Windows 1.5 ms and 2.2 ms, Linux 1.6 ms and 2.4 ms, macOS 3.1 ms and 2.8 ms.
- **(b) Terminal resize and close.** `host/test/it/terminal_qualification_test.dart` "saturating A and stalled B: control terminal C resize and close ack worst <= 250 ms, C output flows; closing stalled B acks <= 250 ms and ends within the deadline". It bounds `worst`, the largest acknowledgement of 40 resizes of C plus the close of B and the close of C, and separately the close ack of stalled B, both at 250 ms. It also requires A to keep flowing and C's output to arrive. The bound is a wall-clock round trip on a shared CI VM and is the ADR 0002 criterion itself.
- **(c) Protocol level.** `host/test/it/protocol_qualification_test.dart` "control round-trip ≤ 250 ms under saturating channel" and "stalled channel stops at credit; other channel and control flow".

Windows (b) is not recorded as a pass. That test passed in [CI][ci], with a worst resize ack of 8 ms. It failed on Windows in an earlier run of the same branch: [42474936125](https://github.com/sh1ny/kumiko/actions/runs/42474936125), attempt 1, commit `2725f23`, assertion at line 121 (the `worst` bound), actual 359.3 ms against 250 ms. The same test printed a worst resize ack of 10 ms, so the 359 ms was a close acknowledgement, of B or C (the test does not record which). Locally it has also been seen at 2.02 s under load (reported, not re-run for this record). The roadmap criterion is a bound, and a bound that one run in an unknown number misses is not evidenced by one green run. It stays `unverified` until the cause is understood or the bound is restated by the user. Linux and macOS (b) have no failure on record and passed in [CI][ci]; their measured worst resize acks were 2 ms and 12 ms, the close acks are asserted but not printed.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| ADR 0002 (a): Stop and permission replies complete under saturation; other channels flow | Windows | agent | pass | agent (Claude) | 2026-11-08 | host/test/it/agent_qualification_test.dart (test named above); [CI][ci] |
| ADR 0002 (a): Stop and permission replies complete under saturation; other channels flow | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| ADR 0002 (a): Stop and permission replies complete under saturation; other channels flow | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| ADR 0002 (b): terminal resize and close complete under saturation and a stalled consumer | Windows | agent | unverified | agent (Claude) | 2026-11-08 | host/test/it/terminal_qualification_test.dart (test named above): green in [CI][ci], but 359.3 ms close ack against the 250 ms bound in run 42474936125; see text above |
| ADR 0002 (b): terminal resize and close complete under saturation and a stalled consumer | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci]; worst resize ack 2 ms |
| ADR 0002 (b): terminal resize and close complete under saturation and a stalled consumer | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci]; worst resize ack 12 ms |
| ADR 0002 (c): control round trip and non-saturated channels under a saturating or stalled channel | Windows | agent | pass | agent (Claude) | 2026-11-08 | host/test/it/protocol_qualification_test.dart (two tests named above); [CI][ci]. AGENTS.md lists this 250 ms row as load-sensitive |
| ADR 0002 (c): control round trip and non-saturated channels under a saturating or stalled channel | Linux | agent | pass | agent (Claude) | 2026-11-08 | same tests; [CI][ci] |
| ADR 0002 (c): control round trip and non-saturated channels under a saturating or stalled channel | macOS | agent | pass | agent (Claude) | 2026-11-08 | same tests; [CI][ci] |

### 7. A Claude Code ACP session streams, shows tool activity, raises a permission request and stops mid-turn

Windows has an earlier user-confirmed record: `docs/qualification/claude-agent-acp.md`, adapter `@agentclientprotocol/claude-agent-acp` 0.99.1, Windows rows `launch`, `streaming`, `tool activity`, `permission request`, `Stop`, `close with confirmation`, `load`, `resume` and `auth-required observed` all `pass`, 2026-11-02, "user confirmed pass". The record's Linux and macOS rows are `unproven`. The Windows row here is `pending` because the walk runs it again against the current build. The user may instead state that the 2026-11-02 record stands. The criterion also says "The Stop result reported is the actual one", which the earlier record's single `Stop` row does not separate.

Automated support with a fake adapter, not a substitute: `desktop/integration_test/agent_test.dart` "real app streams tool activity answers permission stops and confirms close" and `host/test/it/agent_test.dart` passed on all three OSes in [CI][ci].

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| In a checkout, a Claude Code ACP session streams a reply, shows tool activity, raises a permission request, and Stop mid-turn reports the actual result | Windows | user | pass | user | 2026-11-08 | User walk step 4: "works"; the session created ABOUT.md in the checkout (removed afterwards) |
| In a checkout, a Claude Code ACP session streams a reply, shows tool activity, raises a permission request, and Stop mid-turn reports the actual result | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02; docs/qualification/claude-agent-acp.md Linux rows `unproven` |
| In a checkout, a Claude Code ACP session streams a reply, shows tool activity, raises a permission request, and Stop mid-turn reports the actual result | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02; docs/qualification/claude-agent-acp.md macOS rows `unproven` |

### 8. An existing agent session keeps its original checkout as its target (ADR 0004)

Agent half: `host/test/it/agent_test.dart` "selecting workspace B then sending a prompt keeps cwd A and the stored target A" (the fixture reports cwd A and the stored record names A), `desktop/test/agent_test.dart` "agent controller selecting workspace B then sending a prompt sends the same session id", and `host/test/it/agent_tools_test.dart` "result names the original target after another workspace is focused". All passed on the three OSes in [CI][ci]. The user half is "observed once"; rows are per OS here for uniformity.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Existing session keeps its original checkout after focusing another workspace: automated test | Windows | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Existing session keeps its original checkout after focusing another workspace: automated test | Linux | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Existing session keeps its original checkout after focusing another workspace: automated test | macOS | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Existing session keeps its original checkout after focusing another workspace: observed once | Windows | user | pass | user | 2026-11-08 | User walk step 4: "works" |
| Existing session keeps its original checkout after focusing another workspace: observed once | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Existing session keeps its original checkout after focusing another workspace: observed once | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 9. Kumiko tool delivery (ADR 0005)

- **Secret check.** `host/test/it/tool_auth_test.dart` "wrong secret is refused before any MCP message" (the host answers `unauthenticated` and closes, and the grant is never marked authenticated) and "MCP without preamble or silence past the deadline closes the connection" (a missing secret: MCP without a preamble, junk, and a silent client are all closed, the silent one at the 5 s deadline). Both passed on the three OSes in [CI][ci].
- **Tool call or reported unavailable.** `host/test/it/agent_tools_test.dart` "kumiko_session_info returns id, role, runtime, adapter and target", "status not yet used until the first successful call, then connected", "listed version failure shows unavailable with recorded text" and "endpoint down sends empty mcpServers and status unavailable" passed on the three OSes, against the fixture adapter. The real adapter is only recorded in `docs/qualification/claude-agent-acp.md`: Windows `kumiko tool call` is `pass` (2026-11-02, real run of the driver's `tool` step, status connected, user confirmed, native history does not contain the secret). Linux and macOS are `unproven`, so the real adapter has not been shown to call the tool or to report a failure on them.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| A call with a wrong or missing session secret is rejected | Windows | agent | pass | agent (Claude) | 2026-11-08 | host/test/it/tool_auth_test.dart (two tests named above); [CI][ci] |
| A call with a wrong or missing session secret is rejected | Linux | agent | pass | agent (Claude) | 2026-11-08 | same tests; [CI][ci] |
| A call with a wrong or missing session secret is rejected | macOS | agent | pass | agent (Claude) | 2026-11-08 | same tests; [CI][ci] |
| Claude Code session calls the read-only Kumiko tool, or the UI reports Kumiko tools unavailable with the observed failure | Windows | agent | pass | user (qualification driver `tool/qualify_claude_acp.dart`) | 2026-11-02 | docs/qualification/claude-agent-acp.md, adapter 0.99.1, Windows `kumiko tool call` pass; fixture tests above pass in [CI][ci] |
| Claude Code session calls the read-only Kumiko tool, or the UI reports Kumiko tools unavailable with the observed failure | Linux | agent | unverified | none | 2026-11-02 | fixture tests above pass in [CI][ci]; real adapter not run on Linux (record row `unproven`, user decision 2026-11-02) |
| Claude Code session calls the read-only Kumiko tool, or the UI reports Kumiko tools unavailable with the observed failure | macOS | agent | unverified | none | 2026-11-02 | fixture tests above pass in [CI][ci]; real adapter not run on macOS (record row `unproven`, user decision 2026-11-02) |

### 10. Close confirmations

New with this change: an idle terminal closes without a warning, and a terminal holding a program besides its shell warns and names it (ADR 0014, decisions 4 to 7). Automated support, not a substitute: `desktop/test/terminal_test.dart` "close of a busy terminal warns naming its program", "idle terminal closes without a warning", "close cancel keeps the pane, its place in the split, link and channels untouched"; `desktop/test/agent_test.dart` "rejected pending prompt restores idle close without confirmation" and "cancel close of running keeps split and sends nothing"; `host/test/it/terminal_activity_test.dart` (idle, busy with name, background job). These passed on the three OSes in [CI][ci]. The desktop widget tests use a mocked host.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Closing a working agent asks for confirmation, an idle one does not, Cancel keeps it running | Windows | user | pass | user | 2026-11-08 | User walk step 5: "works" |
| Closing a working agent asks for confirmation, an idle one does not, Cancel keeps it running | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Closing a working agent asks for confirmation, an idle one does not, Cancel keeps it running | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Closing a terminal with running processes warns about process loss, an idle one does not, Cancel keeps it running | Windows | user | pass | user | 2026-11-08 | User walk step 5: "works" |
| Closing a terminal with running processes warns about process loss, an idle one does not, Cancel keeps it running | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Closing a terminal with running processes warns about process loss, an idle one does not, Cancel keeps it running | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 11. Quit and reopen

Agent half (the store round trip), all passing on the three OSes in [CI][ci]:
- `desktop/integration_test/workbench_reopen_test.dart` "quit and reopen restores tab order, a split tab with its direction and ratio, panes, the active tab and the focused pane";
- `desktop/integration_test/terminal_reopen_test.dart` "a tab of four terminal panes reopens with the same tree and ratios, each ended, not restored, and the host runs no terminal unit";
- `desktop/integration_test/agent_reopen_test.dart` "three saved chats and terminal split reopen unchanged with no agent unit; explicit Continue loads history" (asserts *Saved, not running*, no agent unit until Continue, then history loaded);
- `desktop/integration_test/exit_reopen_test.dart` "stopped panes reopen in place with the layout", "composer text returns after quit and reopen", "restored pane shows draft before Continue; nothing sent".

The user rows are split by the three things the criterion promises.

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Quit and reopen: store round trip of layout, saved agent sessions and terminal arrangement | Windows | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Quit and reopen: store round trip of layout, saved agent sessions and terminal arrangement | Linux | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Quit and reopen: store round trip of layout, saved agent sessions and terminal arrangement | macOS | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Quit and reopen restores the tab and split layout | Windows | user | pass | user | 2026-11-08 | User walk step 6: "works" |
| Quit and reopen restores the tab and split layout | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Quit and reopen restores the tab and split layout | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Agent tabs show *saved, not running* and continue through the qualified resume path, or show *resume unavailable* | Windows | user | pass | user | 2026-11-08 | User walk step 6: "works" |
| Agent tabs show *saved, not running* and continue through the qualified resume path, or show *resume unavailable* | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Agent tabs show *saved, not running* and continue through the qualified resume path, or show *resume unavailable* | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Terminals restore arrangement only, no programs re-run | Windows | user | pass | user | 2026-11-08 | User walk step 6: "works" |
| Terminals restore arrangement only, no programs re-run | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Terminals restore arrangement only, no programs re-run | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

### 12. Process cleanup and the single host (ADR 0001), per OS

All of these are agent criteria. Tests passed and were not skipped on the three OSes in [CI][ci]. The task 8.1 test is uncommitted at the time of writing and was part of the tested commit `5f724ba`.

- **Killing the desktop leaves no host, agent or shell process.**
  - `host/test/it/lifecycle_test.dart` "killed stand-in desktop leaves no host, shell, child or adapter process" starts a real terminal running a child and a fake-ACP session with a process tree, kills the stand-in, and checks by pid and start time that the host, shell, child and adapter processes are gone and `exit_kind` is null.
  - Also "killed desktop stand-in leaves no host or marked process" and "desktop closing input without app/quit ends every unit, no dialog path", and `agent_close_test.dart` "killing the stand-in desktop during a turn leaves no adapter child or grandchild process" and `terminal_close_test.dart` "desktop and host loss killing the stand-in desktop leaves no terminal process (shell and child)".
- **Killing the host ends with every unit cleaned or the workspace *cleanup unresolved* and refusing launches.**
  - `host/test/it/reconcile_test.dart` "killed host's units cleaned or unresolved; no launch before reconcile".
  - `terminal_close_test.dart` "desktop and host loss killed host: the next host settles terminal units or marks the workspace cleanup unresolved".
  - `agent_close_test.dart` "killed host: next host settles the agent unit or gates unresolved cleanup and refuses start".
  - `lifecycle_test.dart` "unendable unit at quit is cleanup unresolved at next launch" (asserts the workspace's `unresolvedWorkspaces`, the ledger state `unresolved`, and `cleanupUnresolved` on a launch).
- **Two simultaneous launches yield one host.** `host/test/it/lock_test.dart` "two simultaneous launches yield one host", with "locked host replies profile-locked and exits" and "refused launch leaves profile byte-identical".

| Criterion | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Killing the desktop leaves no host, agent or shell process | Windows | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Killing the desktop leaves no host, agent or shell process | Linux | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Killing the desktop leaves no host, agent or shell process | macOS | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Killing the host ends with every unit cleaned, or the workspace cleanup unresolved and refusing new launches | Windows | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Killing the host ends with every unit cleaned, or the workspace cleanup unresolved and refusing new launches | Linux | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Killing the host ends with every unit cleaned, or the workspace cleanup unresolved and refusing new launches | macOS | agent | pass | agent (Claude) | 2026-11-08 | tests named above; [CI][ci] |
| Two simultaneous launches yield one host | Windows | agent | pass | agent (Claude) | 2026-11-08 | host/test/it/lock_test.dart "two simultaneous launches yield one host"; [CI][ci] |
| Two simultaneous launches yield one host | Linux | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |
| Two simultaneous launches yield one host | macOS | agent | pass | agent (Claude) | 2026-11-08 | same test; [CI][ci] |

## Behaviour added by this change (not roadmap rows)

The roadmap's quit and reopen criteria do not name the exit dialog, drafts or the previous-exit notice, but this change adds them and the walk is where a person sees them. Automated support, not a substitute, passing on the three OSes in [CI][ci]: `desktop/test/exit_test.dart` (dialog, per-item Stop, Cancel, bulk), `desktop/test/draft_test.dart`, `desktop/test/cleanup_list_test.dart` (notice), `host/test/it/draft_store_test.dart`, `host/test/it/previous_exit_test.dart`, and `desktop/integration_test/exit_reopen_test.dart`.

| Behaviour | OS | Kind | Result | Verifier | Date | Evidence |
|---|---|---|---|---|---|---|
| Quit with a running agent turn and a busy terminal shows the exit dialog: per-item Stop, bulk action, Cancel | Windows | user | pass | user | 2026-11-08 | User walk step 6: "works" |
| Quit with a running agent turn and a busy terminal shows the exit dialog: per-item Stop, bulk action, Cancel | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Quit with a running agent turn and a busy terminal shows the exit dialog: per-item Stop, bulk action, Cancel | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Unsent composer text is back on reopen, before Continue, and nothing is sent | Windows | user | pass | user | 2026-11-08 | User walk step 6: "works" |
| Unsent composer text is back on reopen, before Continue, and nothing is sent | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| Unsent composer text is back on reopen, before Continue, and nothing is sent | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| After the desktop is killed, reopening shows *Kumiko did not close normally last time* with the cleanup outcome | Windows | user | pass | user | 2026-11-08 | User walk step 7: "works" |
| After the desktop is killed, reopening shows *Kumiko did not close normally last time* with the cleanup outcome | Linux | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |
| After the desktop is killed, reopening shows *Kumiko did not close normally last time* with the cleanup outcome | macOS | user | unverified | none | 2026-11-02 | user decision, 2026-11-02 |

## Busy-rule cases the walk records (ADR 0014 decision 7, design D2 and Risks)

The busy rule marks a terminal busy when its contained unit holds a process besides its shell, and on POSIX when the leader's image is no longer the expected shell. What was actually observed, and what is inferred:

| Case | OS | Expected from the design | Observed? | Evidence |
|---|---|---|---|---|
| Idle shell reads idle | Windows | idle | Observed, in tests only | `process_containment/test/unit_processes_test.dart` "an idle PowerShell unit lists only its shell; the console host is not in the unit job" (PowerShell with `-NoProfile`); `host/test/it/terminal_activity_test.dart` "idle shell reads idle" (the fixture shell). No test runs a user's PowerShell profile or Nushell. |
| Idle shell reads idle | Linux | idle | Observed, in tests only | `unit_processes_test.dart` "an idle shell lists only its leader, running the shell" and `terminal_activity_test.dart` (`/bin/sh -i`, `PS1` set), [CI][ci] |
| Idle shell reads idle | macOS | idle | Observed, in tests only, with rc files skipped | Same tests, started as `/bin/bash --norc --noprofile -i`, [CI][ci]. Commit `24c9587`: "On the macOS CI image an interactive bash showed two child bash processes at its prompt, so the idle shell test saw it as busy." It runs bash without rc files now. What those two processes were was not diagnosed. |
| A profile whose executable is a script runs its interpreter as the leader image; the terminal reads busy at its prompt and the warning names the interpreter | Windows | Not applicable by design: Windows has no `exec`, so the leader is always the shell (design D2) | Not observed | no test |
| Same | Linux | busy, naming the interpreter | **Inferred, not observed.** No test or run used a script-executable profile. Nearest evidence: `terminal_activity_test.dart` "exec replaces leader image and reads busy (POSIX)" and "startup-file exec reads busy against resolved executable (POSIX)", which exercise the same image comparison with `exec sleep`. | [CI][ci] |
| Same | macOS | busy, naming the interpreter | **Inferred, not observed** for a script. The launcher case below is the same mechanism and was observed. | below |
| A `/bin/sh` launcher profile on macOS reads busy at its prompt | macOS | busy: `/bin/sh` re-executes the real shell, so the leader image differs from the profile executable (commit `c457586`) | **Observed in CI, not by a person in the app.** Two `unit_processes_test.dart` idle-shell tests started as `sh` read `LeaderState.replaced` instead of `shell`: [run 42465353375](https://github.com/sh1ny/kumiko/actions/runs/42465353375) attempt 10, macOS job. The tests now start bash on macOS. | `process_containment/test/unit_processes_test.dart` |
| Shells with resident helpers (Nushell plugins with a plugin GC timeout, `ssh-agent` started by a profile) read busy at their prompt | Windows, Linux, macOS | busy, naming the helper. This is the evidence ADR 0014 names as reopening decision 4. | **Not observed on any OS.** Nushell was never started in an activity read. The rule's behaviour for a background process is tested with stand-ins: `terminal_activity_test.dart` "background sleep reads busy" (passes on all three OSes, [CI][ci]). The macOS bash observation above shows that real profiles can leave non-shell processes at a prompt, but it was not caused by Nushell or `ssh-agent`. | Windows walk step 2 (user, 2026-11-08): idle PowerShell and Nushell behaved "as expected"; no helper-naming warning was reported, and no plugin or `ssh-agent` profile was tried, so resident helpers stay unobserved. Linux and macOS: `unverified`, user decision 2026-11-02 |

## No real power cut was tested

The draft store's guarantee that a committed removal leaves no copy of the text rests on SQLite's documented contract for `journal_mode = DELETE`, `synchronous = EXTRA` and `secure_delete = ON` (`EXTRA` also syncs the directory after the journal is deleted). No power cut, forced VM reset or fsync failure was applied on any OS. This is inferred from the documentation and from the following, which were observed (passing on the three OSes in [CI][ci]):
- `host/test/agent/draft_store_worker_test.dart` "draft schema v1 and the three settings are read back": the effective settings are asserted after opening;
- the same file, "a hot journal is rolled back on open": a transaction is cut off with the journal and database copied mid-transaction, and the next open restores the earlier content. That is a crash image, not a power cut;
- `host/test/it/draft_store_test.dart` "draft saved by the stand-in desktop survives its kill" (a process kill), "canary d1f9 absent from every profile file after ack" and "empty save tombstones and the text is absent from every file" (the text is absent from every file after the removal commits, in a running filesystem).

Disk write-cache and filesystem behaviour on each OS were not examined.

## Intermittent failures seen on CI (2026-11-08)

Runs of branch `ci/app-exit-verify` before the green run. I read the failing logs for each item below except where marked as reported.

| Test | OS | What was seen | Run | In green run 42486331623 | Effect on this record |
|---|---|---|---|---|---|
| `host/test/it/terminal_qualification_test.dart` "saturating A and stalled B: control terminal C resize and close ack worst <= 250 ms, C output flows; closing stalled B acks <= 250 ms and ends within the deadline" | Windows | Close ack 359.3 ms against the 250 ms bound at line 121 (the `worst` assertion). The same run printed a worst resize ack of 10 ms. Locally 2.02 s under load (reported, not re-run). | [42474936125](https://github.com/sh1ny/kumiko/actions/runs/42474936125) attempt 1 | passed (worst resize ack 8 ms) | ADR 0002 (b) on Windows is `unverified` (section 6). This is the ADR 0002 criterion. |
| `host/test/it/draft_store_test.dart` "send order held commit refuses send draft-unavailable within the deadline" | Windows | failed once, no assertion text kept in the log excerpt | [42476799443](https://github.com/sh1ny/kumiko/actions/runs/42476799443) attempt 1 | passed on all three OSes | None on a roadmap row. Drafts are this change's addition. |
| `host/test/it/agent_continue_test.dart` "Continue load replay uses bounded ordinary relay and delivers every event after credit resumes" | Windows | failed once | [42481631558](https://github.com/sh1ny/kumiko/actions/runs/42481631558) attempt 1 | passed on all three OSes | The resume path is checked by the quit/reopen agent rows, which passed; this test is on the Continue relay. |
| `host/test/it/terminal_test.dart` "open no terminal start leaves a reserved channel behind" | macOS | expected `executable-not-found`, got `cleanup-unresolved` | [42481631558](https://github.com/sh1ny/kumiko/actions/runs/42481631558) attempt 1 | passed on all three OSes | None on a row. The cause was not diagnosed. |
| `host/test/it/terminal_close_test.dart` "close escaped marked descendant: exited{closed} only after the scan killed it" | local, under load | 1.06 s (reported, not re-run; no CI failure of it found) | local | passed on all three OSes | None. |
| `desktop/integration_test/exit_reopen_test.dart` launch | not known | launch timeout once (reported). I found no log of it in the runs I read. | not located | passed on all three OSes | None on a row, but the agent rows for quit and reopen rest on one green run. |

Other failures of the same branch that were not intermittent:
- `process_containment/test/pty_windows_test.dart` "a pseudo-console is hosted by the bundled OpenConsole.exe" failed on every attempt of run 42481631558 after the first, on Windows. It was fixed in `15a2e91`.
- macOS idle-shell tests failed in runs 42465353375 and 42474936125 and were fixed in `c457586` and `24c9587` (see the busy-rule section).
- Several runs failed in the step "Install tools from mise.toml" on all or some jobs (run 42465353375, attempts 1 to 9), which is not a test result.

Other observations from the same logs:
- Main run 42457769893 (`ba7a5de`, a push to main on 2026-11-08) failed on Linux in `host/test/it/agent_test.dart` "unlisted version claims the baseline only; start names the version without load or resume" (525 passed, 1 failed). Earlier main runs failed on macOS in `agent_runtime_environment_test.dart` (run 41484032925) and `agent_continue_test.dart` (run 41375938184). The intermittent failures are not limited to this change.
- Draft save latency in [CI][ci] on Windows: median 58.2 ms, p95 99.0 ms, max 160.3 ms (removal median 63.9 ms, p95 91.9 ms, max 106.1 ms); a save under saturated output, worst of 20, was 97.1 ms. ADR 0014 records 5.2 ms on the Windows dev machine and says a cost above 100 ms per save reopens decision 12. The unit test fails above a 100 ms median, so the median held, but the p95 and max on the Windows CI VM are at or over 100 ms. Linux was 1.3 ms median and macOS 1.1 ms.

## Windows walk steps (user items, for use with the user)

Each step lists what is done and what to observe. The result goes into the rows named above.

1. **Fresh launch** (a profile that has never been used; set the existing Kumiko profile folder aside first). Start Kumiko. Observe: Personal opens with no account, project, server or network prompt. Press New terminal: a shell opens at once.
2. **Shells** (same session). Open a terminal with the PowerShell profile and run a command. Open one with the Nushell profile and run `version`. Leave each idle at its prompt for a minute, then close each terminal pane. Observe: each runs its shell; closing an idle terminal shows no warning. If a warning appears at an idle prompt, write down what program it names (this is the resident-helper observation; repeat with a profile that starts `ssh-agent` if one exists).
3. **Terminal bar interactive items** (same session; `tmux` does not run natively on Windows, so use it through WSL or MSYS2 if installed, otherwise the user says whether the 2026-10-30 set of Midnight Commander, Neovim and Helix stands).
   - Fullscreen TUIs: vim or Neovim, lazygit, btop (or htop), tmux. Observe correct rendering, modifier keys (Ctrl, Alt, Shift with arrows), function and navigation keys, and mouse clicks and wheel.
   - CJK IME: switch to a Japanese IME, type `nihon`, Space, Enter in the shell. Observe `日本` committed.
   - Resize: drag the window edge rapidly for several seconds with a TUI running, then release. Observe the shell and TUI end consistent at the new size.
   - Selection, copy, search: select text with the mouse, copy with Ctrl+Shift+C and paste it; press Ctrl+Shift+F and search the scrollback. Observe matches marked.
   - Frames: run the profile throughput drive on this machine, from `packages/desktop`, with `KUMIKO_GATE_FRAMES=true` (the exact command is in `integration_test/profile/terminal_throughput_test.dart` and `.github/workflows/ci.yml`). The user confirms this is real hardware. Observe `BAR throughput: pass` with 0 frames at or over 100 ms.
4. **Agent session and target** (same session). Open a checkout, then a Claude Code chat. Send a prompt that makes it read files and edit one. Observe: the reply streams, tool activity appears, a permission request appears and answering it lets the work continue. Start a second turn and press Stop mid-turn. Observe the Stop result shown (stopped, or not confirmed) matches what happened. Ask it to call the Kumiko session tool; observe Kumiko tools show connected. Then open or focus a second workspace B, send another prompt in the same session, and observe it still works in checkout A (ask it for its working directory).
5. **Close confirmations** (same session). Start a long turn and close the agent pane: observe a confirmation; Cancel and observe the turn still running. When idle, close the pane: no confirmation. In a terminal run `ping -n 600 127.0.0.1` and close its pane: observe a warning naming `PING.EXE`; Cancel and observe it still running. Close an idle terminal: no warning.
6. **Quit and reopen** (restart 1). Set up a split tab with two terminals and a tab with a chat; leave a program running in one terminal, a turn running in the chat, and unsent text in a second chat's composer. Close the window. Observe the exit dialog lists the running turn and the terminal program, with per-item Stop, a bulk action and Cancel. Cancel and observe nothing was stopped. Close again, Stop one item, then choose the bulk action. Reopen. Observe: the same tabs, splits and ratios; chat tabs show *Saved, not running* and Continue loads history (or shows *resume unavailable*); terminals show *Ended, not restored* with Start shell and no program re-run; the unsent text is back in the composer before Continue and nothing was sent.
7. **Kill the desktop** (restart 2). Run a program in a terminal and a chat turn. In Task Manager end the `kumiko.exe` process (not the host). Observe after a few seconds that `kumiko_host.exe`, the shell, the program and the agent adapter processes are gone. Reopen. Observe the notice *Kumiko did not close normally last time* with the cleanup outcome (all cleaned, or the unresolved workspaces with *Show cleanup list*).
