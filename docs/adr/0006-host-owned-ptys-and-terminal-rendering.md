# ADR 0006: Host-owned PTYs with desktop-side terminal emulation

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D7, D9, D30; ADR 0001, ADR 0002

## Context

Terminals must run any installed shell with full interactive behaviour: PowerShell, Nushell, bash, zsh, fish, and fullscreen TUIs. The terminal must also be a first-class surface equal to Chat (D30). D9 splits terminals into three pieces:
- a Flutter view;
- an emulation core;
- a PTY backend, which is ConPTY on Windows and the native PTY on POSIX.

Candidates: `flutter_alacritty` (Alacritty core via Rust FFI with a pluggable PTY backend) and `xterm.dart` (pure Dart). Neither is qualified.

## Decision

1. **PTYs and shell processes belong to the host** (ADR 0001). The host launches from a **shell profile**:
   - an executable;
   - an argument list, never an assembled command string;
   - a working directory;
   - environment overrides.

   An unknown but launchable shell runs as a basic terminal.
2. **Emulation and rendering run in the desktop.** The host relays raw PTY bytes in both directions on a dedicated ADR 0002 channel, plus resize and exit as control messages. It does not interpret terminal sequences.
3. **Engine choice is made by an M1 qualification spike** comparing the candidates on all three OSes:
   - PowerShell/Nushell/fish/bash;
   - vim and lazygit;
   - resize, keyboard and IME, selection/paste, Unicode/CJK;
   - large-output throughput.

   The chosen engine must accept bytes from an external source. A candidate that only works with its own in-process PTY fails this requirement. The terminal change records the choice as a follow-up ADR.
4. **Close semantics (D7):** closing a terminal tab, pane or group warns that its running processes will end. Confirming makes the host terminate those process trees. Reopen restores the arrangement only. It never restarts previous programs or commands.
5. The human's interactive shell profile does not define the shell agents use to run commands.

## Rejected alternatives

- **PTY in the desktop process.** It puts process ownership back in the UI and breaks ADR 0001's lifetime guarantee.
- **Emulation in the host with rendered cell grids sent to the UI.** Doubles the work for a local peer. Revisit only for a remote host if bandwidth demands it.
- **Process stdout piping instead of a PTY** (rejected in D9).

## Consequences

- Scrollback lives in the desktop's emulator. The host keeps only a bounded in-flight buffer, so a desktop crash loses scrollback, consistent with D7's layout-only reopen.
- If the spike picks `flutter_alacritty`, the desktop build takes on Rust/FFI toolchain upkeep on three platforms.

## Reversal cost

Medium for the engine (behind one widget boundary). High for PTY ownership and the byte-channel contract.
