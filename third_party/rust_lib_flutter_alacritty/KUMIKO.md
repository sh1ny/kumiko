# Vendored `rust_lib_flutter_alacritty`

The native half of `flutter_alacritty`, version 0.2.2 from pub.dev (MIT,
`LICENSE`), used through `dependency_overrides` in the workspace
`pubspec.yaml`. Three changes:

- `rust/Cargo.toml` takes `alacritty_terminal` from
  `../../alacritty_terminal` (see its `KUMIKO.md`) instead of the git pin;
  `rust/Cargo.lock` follows.
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
