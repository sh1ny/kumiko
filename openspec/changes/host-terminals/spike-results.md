# Terminal engine spike results

Recorded by the `host-terminals` engine spike (tasks 6.x) and checked mechanically by `tool/check_spike_results.dart` (`dart run tool/check_spike_results.dart [path]`). The checker is expected to fail until the spike has filled this file.

## Conventions

- `Adopted candidate:` below names the candidate under evaluation (`flutter_alacritty` or `xterm.dart`). The checker reads only rows whose Candidate cell equals it. Fill in the Candidate cell of every row of that candidate. If a candidate fails, keep its rows (with `fail`) and add a second set of rows for the next candidate, or record them in a separate copy, then change the adopted line.
- Each daily-driver bar item (roadmap M1 exit criteria) appears exactly once per OS per candidate. Item names are fixed; do not reword them.
- Kind is `agent` (agent-scripted, run by the integration test and tools) or `user` (user-verified on that OS).
- Result is exactly `pass`, `fail` or `unproven`. A blank cell fails the check. `unproven` is allowed only for `user` items on Linux or macOS; it stays listed and does not count as passed. Windows has no `unproven`.
- Any `fail` on any OS blocks adoption (ADR 0010). ADOPTABLE means only Linux or macOS user items are `unproven`; QUALIFIED means nothing is `unproven` and is required before M1 closes.

Adopted candidate: 

## vttest subset

Run from the vttest main menu, every screen of each item, no skipping:
1. main menu item 1, "Test of cursor movements";
2. main menu item 2, "Test of screen features";
3. main menu item 3, "Test of character sets".

The conformance row passes only when every screen reached through those three items renders as vttest describes, apart from the screens outside the bar below. The agent records the vttest version, the sub-screens it ran and the screens it excluded in Notes. Other main menu items (for example keyboard, terminal reports, VT52, non-VT100 tests) are outside the subset.

Outside the bar (user decision 2026-10-30): screens whose check depends on 132-column mode (DECCOLM), reverse-screen mode (DECSCNM), or a character set other than US ASCII and DEC Special Graphics (national replacement sets such as UK, alternate ROM). They still run, so they cannot hide a crash or a corrupted later screen, but their own rendering is not judged. Modern terminals (Alacritty, Windows Terminal, kitty) leave these out by design.

How it runs (user decision 2026-10-30): on Linux and macOS, vttest runs live through the host's pseudo-terminal with scripted keystrokes at 80x24. Each screen's output is also recorded as a byte transcript on Linux and committed; on Windows, which has no native vttest, the transcripts are replayed into the engine (Notes say "replayed, not through ConPTY"). Every screen is compared with a hand-written expected grid.

## windows

| Item | Kind | Candidate | Result | Notes |
|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user |  |  |  |
| Colour: 256 colours and 24-bit true colour | agent |  |  |  |
| Input: bracketed paste | agent |  |  |  |
| Input: CJK IME composition | user |  |  |  |
| Unicode: wide characters and emoji widths | agent |  |  |  |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent |  |  |  |
| Resize: rapid resize storm | user |  |  |  |
| Conformance: vttest subset | agent |  |  |  |
| Selection, copy and scrollback search | user |  |  |  |

## linux

| Item | Kind | Candidate | Result | Notes |
|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user |  |  |  |
| Colour: 256 colours and 24-bit true colour | agent |  |  |  |
| Input: bracketed paste | agent |  |  |  |
| Input: CJK IME composition | user |  |  |  |
| Unicode: wide characters and emoji widths | agent |  |  |  |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent |  |  |  |
| Resize: rapid resize storm | user |  |  |  |
| Conformance: vttest subset | agent |  |  |  |
| Selection, copy and scrollback search | user |  |  |  |

## macos

| Item | Kind | Candidate | Result | Notes |
|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user |  |  |  |
| Colour: 256 colours and 24-bit true colour | agent |  |  |  |
| Input: bracketed paste | agent |  |  |  |
| Input: CJK IME composition | user |  |  |  |
| Unicode: wide characters and emoji widths | agent |  |  |  |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent |  |  |  |
| Resize: rapid resize storm | user |  |  |  |
| Conformance: vttest subset | agent |  |  |  |
| Selection, copy and scrollback search | user |  |  |  |
