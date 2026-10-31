# Vendored `rust_lib_flutter_alacritty`

The native half of `flutter_alacritty`, version 0.2.2 from pub.dev (MIT,
`LICENSE`), used through `dependency_overrides` in the workspace
`pubspec.yaml`. Five changes:

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
