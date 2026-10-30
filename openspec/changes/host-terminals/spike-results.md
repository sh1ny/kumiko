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

The conformance row passes only when every screen reached through those three items renders as vttest describes, apart from what is outside the bar below. The agent records the vttest version, the screens it ran and what it left unjudged in Notes. Other main menu items (for example keyboard, terminal reports, VT52, non-VT100 tests) are outside the subset.

Outside the bar (user decisions 2026-10-30): 132-column mode (DECCOLM), reverse-screen mode (DECSCNM), text blink (SGR 5), and character sets other than US ASCII and DEC Special Graphics (British, DEC Alternate ROM). Modern terminals (Alacritty, Windows Terminal, kitty) leave these out by design. Every screen still runs, so an unjudged one cannot hide a crash or corrupt a later screen.

Screens of vttest 2.7 (20230201) answering as a VT100-family terminal, 22 in all:

| Screen | vttest check | Judged |
|---|---|---|
| 1.1 | border of `*` and `+`, frame of `E` (80 columns) | yes |
| 1.2 | the same in 132 columns | no: 132 columns |
| 1.3 | autowrap, mixing control and print characters (80 columns) | yes |
| 1.4 | the same in 132 columns | no: 132 columns |
| 1.5 | cursor-control characters inside escape sequences | yes |
| 1.6 | leading zeros in escape sequences | yes |
| 2.1 | wrap around mode | yes |
| 2.2 | tab setting and resetting | yes |
| 2.3 | 132 columns, light background | no: 132 columns, reverse screen |
| 2.4 | 80 columns, light background | no: reverse screen |
| 2.5 | 132 columns, dark background | no: 132 columns |
| 2.6 | 80 columns, dark background | yes |
| 2.7, 2.8 | soft scroll, region and full screen (final screen) | yes |
| 2.9, 2.10 | jump scroll, region and full screen | yes |
| 2.11, 2.12 | origin mode | yes |
| 2.13 | graphic rendition, dark background | yes, except blink |
| 2.14 | graphic rendition, light background | no: reverse screen |
| 2.15 | save and restore cursor | yes, except blink |
| 3.1 | installed character sets | US ASCII and DEC Special Graphics rows only |

How it runs (user decision 2026-10-30): on Linux and macOS, vttest runs live through the host's pseudo-terminal with scripted keystrokes at 80x24. Each screen's output is also recorded as a byte transcript on Linux and committed; on Windows, which has no native vttest, the transcripts are replayed into the engine (Notes say "replayed, not through ConPTY"). Every judged screen is compared with a hand-written expected grid.

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
