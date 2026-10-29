# Proposal

## Why

After `local-store-and-workbench-shell`, Kumiko has a workbench with tabs, splits and layout restore, but there is nothing to run in it: no terminal, no shell, and no data channel that carries live bytes. This is change 3 of **M1 - Local development loop (walking skeleton)**. It delivers host-owned terminals (ADR 0006) and qualifies the terminal engine, the riskiest UI dependency in M1.

It advances these M1 exit criteria:
- **First launch opens Personal ... and a terminal can be opened at once** (user, per OS): the terminal half that change 2 left open.
- **Terminals run the user's shell from an argv profile** (user, per OS): PowerShell and Nushell on Windows, bash on Linux, fish or zsh on macOS.
- **The adopted terminal engine passes the daily-driver bar on each OS** (user and agent, per OS): the spike, its per-OS results recorded in this change, and the follow-up ADR. An engine that fails any item is not adopted (ADR 0006).
- **Stop, permission replies, resize and close still complete with one terminal saturating output and another's consumer stalled** (agent, ADR 0002): the terminal-level demonstration that `scaffold-desktop-and-host` deferred here. Stop and permission replies arrive with change 4; this change proves the property for resize, close and other channels.
- **Closing a terminal with running processes warns about process loss; Cancel keeps everything running** (user).
- **Quit and reopen ... terminals restore arrangement only, with no programs re-run** (user per OS; agent for the store round-trip).
- **Killing the desktop leaves no ... shell process; killing the host cleans every unit** (agent, per OS, ADR 0001): terminal shells become contained units under the existing ledger.

## What Changes

- **Engine qualification before any terminal UI.** The host PTY and terminal channel pipeline is built and tested headless first, so the spike qualifies each engine on real shells fed through Kumiko's own channels, not through the engine's in-process PTY. Then run the lead candidate `flutter_alacritty`, then the fallback `xterm.dart` if needed, against every item of the M1 daily-driver bar on Windows, Linux and macOS. The chosen engine must render bytes from an external source. Scripted items are run by the agent; interactive items are run by the user on each OS. Agent-scripted items run on all three OSes in CI. The change pauses after the spike for the user's interactive results. **User decision (2026-10-29):** Linux and macOS user-verified items are recorded as `unproven` for now and the change finishes on Windows user results; they stay listed, are never counted as passed, and are run before M1 closes. The engine is adopted provisionally until then. If both candidates fail, the change escalates to the user with the observed results (fork the widget, or build one on `alacritty_terminal`) instead of adopting either.
- **Shell profiles.** A profile is an executable, an argument list (never an assembled command string), a working directory and environment overrides. The host detects installed shells (PowerShell / pwsh, Nushell, bash, zsh, fish) as built-in profiles. The user can add, edit and remove their own profiles and choose a default. Profiles are host-owned and stored in the local store (schema v3). A profile whose executable is missing reports that failure; Kumiko never substitutes another shell.
- **Host PTYs.** The host launches a profile's shell under a pseudo-terminal: ConPTY on Windows, the native PTY on Linux and macOS. Each terminal is a contained unit in the existing ledger, with the same cleanup on close, host exit, desktop death and reconciliation as other units. Terminal launch follows the existing unit cap and workspace cleanup gate.
- **Terminal channels.** Each terminal gets a pair of ADR 0002 data channels, one per direction, carrying raw bytes under per-channel credit. Resize, exit status and close are control messages naming the terminal. The host never interprets terminal sequences, and stops reading a PTY while its channel has no credit.
- **Terminal tabs.** The group launcher gains **Terminal**, opening the default profile in the group's workspace, with a choice of profile. A terminal can be opened at once in Personal with no workspace (home directory). Running a coding-agent CLI in a terminal needs no project, repository or adapter.
- **Close-loss warnings.** Closing a terminal tab whose shell is alive asks for confirmation, naming the process loss. Closing a group or split that holds several live terminals names all of them in one warning. Cancel keeps everything running; confirm terminates those process trees. A terminal whose shell has exited closes without a prompt.
- **Layout-only reopen.** Quit and reopen restores terminal tabs in their places, each shown as *ended, not restored* with its profile and a **Start shell** button. Nothing launches until the user asks, and no earlier program or command is re-run.
- **Protocol:** new capability-gated methods for profiles and for terminal open, resize, close and exit, plus host-allocated channel ids for desktop-to-host channels (ADR 0002 additive change, no version bump).
- **New ADR (written during apply):** the adopted terminal engine, with the per-OS spike results (ADR 0006 follow-up).

## Capabilities

### New Capabilities
- `terminal-sessions`: interactive terminals from shell profiles, host-owned PTY processes, the daily-driver bar the adopted engine meets, terminals distinct from agent tool shells, terminal-native CLIs in Personal, close-loss warnings for tabs, groups and splits, and layout-only reopen with an explicit Start. Carries from `document-kumiko-direction` `terminal-sessions`: "Interactive terminals are shell agnostic", "Shell integration is optional" (basic terminal only; no integrations ship), "Terminals and agent tool shells remain distinct", "Terminal-native agents are first-class without a Chat UI adapter", "Closing terminals warns about affected running processes" and "Reopening restores terminal arrangement rather than processes". Decisions D7, D9, D30. "Personal terminals are not team-server streams" is left for M4, when a team server exists.
- `shell-profiles`: built-in detection of installed shells, user-defined argv profiles, the default profile, validation, and the missing-executable failure. Carries the profile shape from "Interactive terminals are shell agnostic" and D9.

### Modified Capabilities
- `desktop-host-protocol`: adds terminal channels (one data channel per direction under per-channel credit, ids allocated by the host so the peers never collide) and terminal control messages. Existing requirements are unchanged.
- `workbench-layout`: adds the Terminal launcher entry, the terminal tab kind, the *ended, not restored* state on reopen, and close confirmations for tabs, groups and splits holding live terminals. Existing requirements are unchanged.

## Impact

- **Code:**
  - `process_containment`: PTY spawn on both platforms (ConPTY pseudo-console attribute on Windows; controlling-terminal setup in the existing exec shim on POSIX), resize, and PTY I/O.
  - `host_protocol`: profile and terminal messages, the capability, and desktop-to-host channel allocation.
  - `host`: store migration v3 (profiles), shell detection, the terminal service with PTY to channel relay and backpressure.
  - `domain`: profile model and validation (pure).
  - `desktop`: the terminal view behind one widget boundary, the launcher entry and profile picker, the profile editor, close confirmations, and the restored *ended* state.
- **Dependencies:** the adopted engine (`flutter_alacritty`, with Rust/FFI toolchain upkeep in CI on three OSes, or `xterm.dart`). It must pass the dependency audit, and the audit's desktop dependency rule (D1) gains the engine as an allowed dependency.
- **Planning files during apply:** the engine ADR, `openspec/architecture.md` (index row, terminal resource-bound rows with real numbers, profile state row), and the spike results recorded in this change.
- **Not in this change:**
  - optional shell integrations (prompt marks, cwd tracking);
  - restoring scrollback, or any process surviving close or exit;
  - whole-app exit decisions and bulk stop (change 6);
  - agent tool shells and ACP sessions (change 4);
  - terminals in a remote or team-server context (M4).
