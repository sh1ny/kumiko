# Vendored `alacritty_terminal`

The terminal engine core behind `flutter_alacritty` (ADR 0010), vendored so
Kumiko can carry a fix the published plugin does not have.

- **Source:** `alacritty_terminal/` of https://github.com/hhoao/alacritty at
  `e6cf18ffcd099aa6118da35ea2476a50d54bd3b2`, the revision
  `rust_lib_flutter_alacritty` 0.2.2 pins. Only `src/`, `Cargo.toml` and the
  licence are kept; the workspace's `edition` and `rust-version` are written
  out and `readme` is dropped.
- **Licence:** Apache-2.0 (`LICENSE-APACHE`).

## Patch

**Vertical cursor moves stop at the scroll margins** (`src/term/mod.rs`).
`move_up`, `move_down`, `move_up_and_cr` and `move_down_and_cr` (CUU, CUD,
CPL, CNL) passed an absolute line to `goto`, which adds the origin-mode
offset again, so in origin mode CUU could leave the scroll region (vttest
2.7 and 2.9). They now go through `move_vertically`: a cursor at or below
the top margin stops at it moving up, one at or above the bottom margin
stops at it moving down, as in xterm. Test:
`vertical_moves_stop_at_the_scroll_margins`.

To move to a newer upstream revision, copy its `alacritty_terminal/` again
and re-apply the patch until upstream carries the fix.
