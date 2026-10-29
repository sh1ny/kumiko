# ADR 0010: Terminal engine

- **Status:** proposed (2026-10-30)
- **Date:** 2026-10-30
- **Source:** change `host-terminals` design D1, D7 and D10; ADR 0006 (engine choice by M1 qualification spike); ADR 0002 (raw terminal channels)

## Context

ADR 0006 puts PTYs in the host and emulation and rendering in the desktop, and defers the engine choice to an M1 qualification spike recorded as a follow-up ADR. This is that ADR. It is a draft: the spike has not run.

Candidates:
- `flutter_alacritty`: the Alacritty core through Rust FFI with a pluggable PTY backend. It is the lead candidate. It adds a Rust toolchain to the desktop build on three OSes.
- `xterm.dart`: pure Dart. It is the fallback.

The engine must render bytes that the host relays from a PTY it owns. The desktop never spawns the shell.

## Decision

Pending spike results. Task 6.6 of `host-terminals` completes this section with the adopted engine and the per-OS results from `openspec/changes/host-terminals/spike-results.md`.

Rules fixed before the spike runs:
1. **External bytes are required.** A candidate must accept bytes from an external source through `TerminalSurface.feed` and emit input bytes and size changes. A candidate that only works with its own in-process PTY is not adopted.
2. **The bar is the M1 daily-driver bar.** Every item listed in `spike-results.md` is recorded per OS as `pass`, `fail` or `unproven`.
3. **Any `fail` on any OS blocks adoption.** The change stops and escalates to the user with the observed results (fork the widget, or build our own on `alacritty_terminal`). The fallback candidate is then tried against the same bar.
4. **`unproven` is allowed only for user-verified items on Linux or macOS.** Adoption is provisional while any such item is `unproven`. The engine is fully qualified only when every item is `pass` on every OS, and that is required before M1 closes. An `unproven` item stays listed and never counts as passed.
5. `tool/check_spike_results.dart` checks the results file mechanically. It reports ADOPTABLE when only Linux or macOS user-verified items are `unproven`, and QUALIFIED when nothing is `unproven`.
6. **Boundary.** The engine sits behind one `TerminalSurface` widget in the desktop: `feed(Uint8List)`, `Stream<Uint8List> input`, `Stream<(int cols, int rows)> size`, `scrollbackLimit` and `dispose()`. Nothing outside the adapter imports the engine package.

## Rejected alternatives

- **Record the engine only in the change design.** ADR 0006 asks for a follow-up ADR, and the engine binds every later terminal feature.

## Consequences

- If `flutter_alacritty` is adopted, the desktop build carries Rust/FFI toolchain upkeep on three platforms (ADR 0006).
- Scrollback and search belong to the engine, so the chosen engine must meet the selection, copy and search items.

## Reversal cost

Medium for the engine, because it sits behind the single `TerminalSurface` boundary: a swap changes one adapter and its build setup. High for the byte-channel contract (ADR 0002, ADR 0006), which this ADR does not change.
