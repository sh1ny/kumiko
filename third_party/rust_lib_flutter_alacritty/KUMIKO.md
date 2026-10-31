# Vendored `rust_lib_flutter_alacritty`

The native half of `flutter_alacritty`, version 0.2.2 from pub.dev (MIT,
`LICENSE`), used through `dependency_overrides` in the workspace
`pubspec.yaml`. Eight changes:

- `rust/Cargo.toml` takes `alacritty_terminal` from
  `../../alacritty_terminal` (see its `KUMIKO.md`) instead of the git pin,
  and adds `unicode-normalization` (below); `rust/Cargo.lock` follows.
- `rust/cargokit.yaml` (the precompiled-binary source) is removed, so the
  crate always builds from source with the patch in.
- An unfinished synchronized update is applied at its deadline
  (`rust/src/engine.rs`, `end_expired_sync`). alacritty's parser buffers
  every byte after `CSI ? 2026 h` until `CSI ? 2026 l` and leaves its 150 ms
  deadline to the caller, which the engine never checked: a program that died
  in between held all later output for good. The engine now applies an
  expired update before it parses new output and before a full snapshot, and
  reports synchronized output from the parser's own state. Test: the crate's
  `cargo test` (`a_synchronized_update_that_never_ends_is_applied_after_its_deadline`).
- Combining marks are composed into their cell's character
  (`rust/src/engine.rs`, `composed_codepoint`). A cell crosses the FFI as one
  codepoint, so the marks alacritty keeps beside it were dropped: `e` plus
  U+0301 showed as a bare `e`. The engine now composes each mark that has a
  composed form (`é`); a mark with none is still left out. Test:
  `combining_marks_are_composed_into_the_base_cell`.
- The hyperlink table is bounded (`rust/src/engine.rs`,
  `MAX_HYPERLINKS`). Every OSC 8 URL rendered was kept for the engine's
  lifetime, so a program printing endless distinct links grew it without
  limit. It now holds at most 4096 URLs and drops the least recently rendered
  quarter when full; ids are never reused, so an evicted id resolves to no
  link rather than to another URL. Test:
  `hyperlink_table_stays_bounded_and_never_reuses_an_id`.
- Concealed text is blank (`rust/src/engine.rs`, `cell_data`). alacritty
  marks SGR 8 cells hidden, but the engine exported their characters and
  dropped the mark, so concealed text was drawn. A hidden cell now crosses as
  a space with no underline or strikeout; its background still shows. Test:
  `concealed_text_is_rendered_blank_without_decorations`.
- A palette entry a program redefines is used for every index
  (`rust/src/engine.rs`, `xterm256`). The engine consulted the runtime OSC 4
  table only for entries 0-15, so a redefined entry from 16 to 255 still drew
  its standard color. Test: `osc4_overrides_every_indexed_color`.
- A scroll reports how far the viewport moved (`rust/src/engine.rs`,
  `scroll_lines`, `scroll_pixels`), not the delta asked for. alacritty
  clamps the display offset to the history, so a scroll with no history
  reported movement the view never made, and the Dart mirror rotated its rows
  anyway; a pixel scroll that snapped to the history's edge reported the
  movement before the snap. Tests: `a_clamped_scroll_reports_no_movement`,
  `a_pixel_scroll_snapped_to_the_history_top_reports_the_snap`.
