# Terminal engine spike results

Recorded by the `host-terminals` engine spike (tasks 6.x) and checked mechanically by `tool/check_spike_results.dart` (`dart run tool/check_spike_results.dart [path]`). The checker is expected to fail until the spike has filled this file.

## Conventions

- `Adopted candidate:` below names the candidate under evaluation (`flutter_alacritty`, `xterm.dart`, or `flutter_alacritty (patched)` after the user chose to patch). The checker reads only rows whose Candidate cell equals it. Fill in the Candidate cell of every row of that candidate. If a candidate fails, keep its rows (with `fail`) and add a second set of rows for the next candidate, or record them in a separate copy, then change the adopted line.
- Each daily-driver bar item (roadmap M1 exit criteria) appears exactly once per OS per candidate. Item names are fixed; do not reword them.
- Kind is `agent` (agent-scripted, run by the integration test and tools) or `user` (user-verified on that OS). Frame times during the throughput run are a `user` item: CI VMs render in software, so CI prints them without judging them, and they are judged on real hardware with the profile throughput test and `--dart-define=KUMIKO_GATE_FRAMES=true` (user decision 2026-10-30).
- Result is exactly `pass`, `fail` or `unproven`. A blank cell fails the check. `unproven` is allowed only for `user` items on Linux or macOS; it stays listed and does not count as passed. Windows has no `unproven`.
- Any `fail` on any OS blocks adoption (ADR 0010). ADOPTABLE means only Linux or macOS user items are `unproven`; QUALIFIED means nothing is `unproven` and is required before M1 closes.

Adopted candidate: flutter_alacritty (patched)

`flutter_alacritty (patched)` is `flutter_alacritty` 2.4.1 with its native crate built from source against a vendored `alacritty_terminal` that carries one fix: vertical cursor moves stop at the scroll margins (`third_party/alacritty_terminal/KUMIKO.md`). The user chose to patch after both published candidates failed (2026-10-30); see Failed candidates. Its Dart package is vendored too, with one fix: cell backgrounds are drawn as one triangle batch, so Impeller leaves no seam between rows (`third_party/flutter_alacritty/KUMIKO.md`; user decision 2026-10-30, after the first Windows user run).

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
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user | flutter_alacritty (patched) | pass | Midnight Commander, Neovim (LazyVim) and Helix in pwsh render and take input. The first run showed a dark line between every row (Impeller anti-aliased the painter's background rects); fixed by the painter patch (6.9). User run on Windows 11 (2026-10-30), with the bundled ConPTY and the 6.9 fixes. |
| Colour: 256 colours and 24-bit true colour | agent | flutter_alacritty (patched) | pass | All 256 indexed colours and the 24-bit samples read back from the grid. On this machine with the bundled ConPTY (design D2). |
| Input: bracketed paste | agent | flutter_alacritty (patched) | pass | The program received the text wrapped once in `ESC[200~`/`ESC[201~`. ConPTY passes the markers only to a program that enables VT input, as the fixture does. On this machine with the bundled ConPTY (design D2). |
| Input: CJK IME composition | user | flutter_alacritty (patched) | pass | Microsoft Japanese IME: `nihon`, Space, Enter committed exactly `日本` (two wide cells) to pwsh. Cyrillic layout input also works. User run on Windows 11 (2026-10-30), with the bundled ConPTY and the 6.9 fixes. |
| Unicode: wide characters and emoji widths | agent | flutter_alacritty (patched) | pass | CJK and emoji take two cells with a spacer; ASCII one. On this machine with the bundled ConPTY (design D2). |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent | flutter_alacritty (patched) | pass | Profile build (`flutter drive --profile`) on this machine with the bundled ConPTY. 105,902,742 bytes written in 1 MiB blocks (`block_cat.dart`; `cmd`'s `type` writes in small pieces): 107,507,368 bytes relayed (ConPTY re-renders) in 1.8 s, exit 0; 222 frames, worst 40 ms (frames are judged in the real-hardware row). A program still writing ended 25 ms after Ctrl+C. CI VM: 100 MB in 8.5 s, Ctrl+C 118 ms. |
| Throughput: frames under 100 ms during the 100 MB cat, on real hardware | user | flutter_alacritty (patched) | pass | `flutter drive --profile` with `KUMIKO_GATE_FRAMES=true`: 107,507,368 bytes relayed in 1,361 ms, exit 0; 223 frames, worst 21 ms, none at or over 100 ms. Ctrl+C ended the writer in 16 ms. User run on Windows 11 (2026-10-30), with the bundled ConPTY and the 6.9 fixes. |
| Resize: rapid resize storm | user | flutter_alacritty (patched) | pass | Resizing is fast and ends correct. While the edge is dragged, reflowed lines show garbled until ConPTY or the program repaints at the new size, as in Windows Terminal. User run on Windows 11 (2026-10-30), with the bundled ConPTY and the 6.9 fixes. |
| Conformance: vttest subset | agent | flutter_alacritty (patched) | pass | vttest 2.7 (20230201), replayed, not through ConPTY. All 22 screens ran; 16 judged and matched, 6 not judged (1.2, 1.4, 2.3, 2.4, 2.5, 2.14: outside the bar). |
| Selection, copy and scrollback search | user | flutter_alacritty (patched) | pass | Mouse selection and Ctrl+Shift+C copy work; Ctrl+Shift+F opens the search bar and marks matches in scrollback (current match distinct). The first run had no selection (the adapter's controller was not attached) and no search bar (the host must supply it); both fixed in 6.9. User run on Windows 11 (2026-10-30), with the bundled ConPTY and the 6.9 fixes. |

## linux

| Item | Kind | Candidate | Result | Notes |
|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user | flutter_alacritty (patched) | unproven | Not yet run on Linux (user decision 2026-10-29). |
| Colour: 256 colours and 24-bit true colour | agent | flutter_alacritty (patched) | pass | All 256 indexed colours and the 24-bit samples read back from the grid. CI run 41081829846. |
| Input: bracketed paste | agent | flutter_alacritty (patched) | pass | The program received the text wrapped once in `ESC[200~`/`ESC[201~`. CI run 41081829846. |
| Input: CJK IME composition | user | flutter_alacritty (patched) | unproven | Not yet run on Linux (user decision 2026-10-29). |
| Unicode: wide characters and emoji widths | agent | flutter_alacritty (patched) | pass | CJK and emoji take two cells with a spacer; ASCII one. CI run 41081829846. |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent | flutter_alacritty (patched) | pass | Profile build on the CI VM. `cat` of 105,902,742 bytes: 107,507,329 bytes relayed in 27.1 s, exit 0; 1,012 frames, worst 257 ms on the VM (not judged). `yes` ended 57 ms after Ctrl+C. CI run 41081829846. |
| Throughput: frames under 100 ms during the 100 MB cat, on real hardware | user | flutter_alacritty (patched) | unproven | Not yet run on Linux (user decision 2026-10-29). |
| Resize: rapid resize storm | user | flutter_alacritty (patched) | unproven | Not yet run on Linux (user decision 2026-10-29). |
| Conformance: vttest subset | agent | flutter_alacritty (patched) | pass | vttest 2.7 (20251205), live through the host's pseudo-terminal at 80x24, and the transcripts replayed. All 22 screens ran; 16 judged and matched, 6 not judged (1.2, 1.4, 2.3, 2.4, 2.5, 2.14: outside the bar). CI run 41081829846. |
| Selection, copy and scrollback search | user | flutter_alacritty (patched) | unproven | Not yet run on Linux (user decision 2026-10-29). |

## macos

| Item | Kind | Candidate | Result | Notes |
|---|---|---|---|---|
| Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with modifiers, function and navigation keys; mouse reporting) | user | flutter_alacritty (patched) | unproven | Not yet run on macOS (user decision 2026-10-29). |
| Colour: 256 colours and 24-bit true colour | agent | flutter_alacritty (patched) | pass | All 256 indexed colours and the 24-bit samples read back from the grid. CI run 41081829846. |
| Input: bracketed paste | agent | flutter_alacritty (patched) | pass | The program received the text wrapped once in `ESC[200~`/`ESC[201~`. CI run 41081829846. |
| Input: CJK IME composition | user | flutter_alacritty (patched) | unproven | Not yet run on macOS (user decision 2026-10-29). |
| Unicode: wide characters and emoji widths | agent | flutter_alacritty (patched) | pass | CJK and emoji take two cells with a spacer; ASCII one. CI run 41081829846. |
| Throughput: 100 MB cat and Ctrl+C interrupt | agent | flutter_alacritty (patched) | pass | Profile build on the CI VM. `cat` of 105,902,742 bytes: 107,509,061 bytes relayed in 8.3 s, exit 0; 556 frames, worst 50 ms on the VM (not judged). `yes` ended 17 ms after Ctrl+C. CI run 41081829846. |
| Throughput: frames under 100 ms during the 100 MB cat, on real hardware | user | flutter_alacritty (patched) | unproven | Not yet run on macOS (user decision 2026-10-29). |
| Resize: rapid resize storm | user | flutter_alacritty (patched) | unproven | Not yet run on macOS (user decision 2026-10-29). |
| Conformance: vttest subset | agent | flutter_alacritty (patched) | pass | vttest 2.7 (20251205), live through the host's pseudo-terminal at 80x24, and the transcripts replayed. All 22 screens ran; 16 judged and matched, 6 not judged (1.2, 1.4, 2.3, 2.4, 2.5, 2.14: outside the bar). CI run 41081829846. |
| Selection, copy and scrollback search | user | flutter_alacritty (patched) | unproven | Not yet run on macOS (user decision 2026-10-29). |

## Failed candidates

Agent-scripted items only: each failed before the user-verified items were reached. Windows, 2026-10-30, same bar test and fixtures.

| Item | flutter_alacritty 2.4.1 (published) | xterm.dart 4.0.0 |
|---|---|---|
| Colour: 256 colours and 24-bit true colour | pass | fail: index 15 (bright white) renders `#e5e5e5`, the theme's white |
| Input: bracketed paste | pass | pass |
| Unicode: wide characters and emoji widths | pass | pass |
| Throughput: 100 MB cat and Ctrl+C interrupt | pass (worst frame 26 ms; Ctrl+C 15 ms) | pass (worst frame 50 ms; Ctrl+C 17 ms) |
| Conformance: vttest subset | fail: 2.7 and 2.9; in origin mode with region 12-13, CUU 24 leaves the region for row 1 | fail: 1.1, 1.3, 1.5, 2.1, 2.2, 2.7, 2.9, 2.11, 2.13, 2.15, 3.1 (no DECALN, no clear on DECCOLM, no tab-stop set/clear, control characters inside CSI misread) |
