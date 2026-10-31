# ADR 0010: Terminal engine

- **Status:** accepted (2026-10-30), provisional until the Linux and macOS user-verified items pass
- **Date:** 2026-10-30
- **Source:** change `host-terminals` design D1, D7 and D10; ADR 0006 (engine choice by M1 qualification spike); ADR 0002 (raw terminal channels)

## Context

ADR 0006 puts PTYs in the host and emulation and rendering in the desktop, and defers the engine choice to an M1 qualification spike recorded as a follow-up ADR. This is that ADR.

Candidates:
- `flutter_alacritty`: the Alacritty core through Rust FFI with a pluggable PTY backend. It is the lead candidate. It adds a Rust toolchain to the desktop build on three OSes.
- `xterm.dart`: pure Dart. It is the fallback.

The engine must render bytes that the host relays from a PTY it owns. The desktop never spawns the shell.

## Decision

Adopt **`flutter_alacritty` (patched)**: `flutter_alacritty` 2.4.1 with its Dart package and native crate vendored under `third_party/`, the crate built from source against a vendored `alacritty_terminal` (hhoao/alacritty `e6cf18f`). Each vendored part's `KUMIKO.md` names its source and its one patch:
- `alacritty_terminal`: vertical cursor moves (CUU, CUD, CPL, CNL) stop at the scroll margins, as in xterm (vttest 2.7 and 2.9).
- `flutter_alacritty`: cell backgrounds are drawn as one triangle batch; Impeller anti-aliased the per-cell rects and left a dark line between rows.

The adoption is **provisional**: `tool/check_spike_results.dart` reports ADOPTABLE, not QUALIFIED. On Windows the host ships Microsoft's open-source ConPTY (change `host-terminals` design D2).

Results (`openspec/changes/archive/2026-10-31-host-terminals/spike-results.md`; agent items from CI and the user's machine, user items from the user's own run):

| Item | Kind | Windows | Linux | macOS |
|---|---|---|---|---|
| Fullscreen TUIs and input | user | pass | unproven | unproven |
| Colour: 256 and 24-bit | agent | pass | pass | pass |
| Input: bracketed paste | agent | pass | pass | pass |
| Input: CJK IME composition | user | pass | unproven | unproven |
| Unicode: wide characters and emoji | agent | pass | pass | pass |
| Throughput: 100 MB cat and Ctrl+C | agent | pass | pass | pass |
| Throughput: frames under 100 ms, real hardware | user | pass | unproven | unproven |
| Resize storm | user | pass | unproven | unproven |
| Conformance: vttest subset | agent | pass (replayed) | pass | pass |
| Selection, copy and scrollback search | user | pass | unproven | unproven |

Every `unproven` entry stays listed and does not count as passed. The engine is fully qualified only when each one is `pass`, which M1 needs before it closes. A later `fail` is handled by a superseding ADR.

Failed candidates: `xterm.dart` 4.0.0 (bright white colour and 11 vttest screens) and the published `flutter_alacritty` 2.4.1 (vttest 2.7 and 2.9); the results file keeps both.

Rules fixed before the spike ran:
1. **External bytes are required.** A candidate must accept bytes from an external source through `TerminalSurface.feed` and emit input bytes and size changes. A candidate that only works with its own in-process PTY is not adopted.
2. **The bar is the M1 daily-driver bar.** Every item listed in `spike-results.md` is recorded per OS as `pass`, `fail` or `unproven`.
3. **Any `fail` on any OS blocks adoption.** The change stops and escalates to the user with the observed results (fork the widget, or build our own on `alacritty_terminal`). The fallback candidate is then tried against the same bar.
4. **`unproven` is allowed only for user-verified items on Linux or macOS.** Adoption is provisional while any such item is `unproven`. The engine is fully qualified only when every item is `pass` on every OS, and that is required before M1 closes. An `unproven` item stays listed and never counts as passed.
5. `tool/check_spike_results.dart` checks the results file mechanically. It reports ADOPTABLE when only Linux or macOS user-verified items are `unproven`, and QUALIFIED when nothing is `unproven`.
6. **Boundary.** The engine sits behind one `TerminalSurface` widget in the desktop: `feed(Uint8List)`, `Stream<Uint8List> input`, `Stream<(int cols, int rows)> size`, `scrollbackLimit` and `dispose()`. Nothing outside the adapter imports the engine package.

## Rejected alternatives

- **Record the engine only in the change design.** ADR 0006 asks for a follow-up ADR, and the engine binds every later terminal feature.

## Consequences

- The desktop build carries Rust/FFI toolchain upkeep on three platforms (ADR 0006); CI installs and caches the Rust toolchain.
- Kumiko carries three vendored parts of the engine. Moving to a newer upstream means re-vendoring and re-applying each patch until upstream carries it; the patches can be offered upstream.
- Scrollback and search belong to the engine; the search bar is the engine's widget, placed by the adapter. The adapter's view needs a `MaterialApp` above it.

## Reversal cost

Medium for the engine, because it sits behind the single `TerminalSurface` boundary: a swap changes one adapter and its build setup. High for the byte-channel contract (ADR 0002, ADR 0006), which this ADR does not change.
