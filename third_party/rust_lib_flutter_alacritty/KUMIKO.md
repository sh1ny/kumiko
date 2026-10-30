# Vendored `rust_lib_flutter_alacritty`

The native half of `flutter_alacritty`, version 0.2.2 from pub.dev (MIT,
`LICENSE`), used through `dependency_overrides` in the workspace
`pubspec.yaml`. Two changes:

- `rust/Cargo.toml` takes `alacritty_terminal` from
  `../../alacritty_terminal` (see its `KUMIKO.md`) instead of the git pin;
  `rust/Cargo.lock` follows.
- `rust/cargokit.yaml` (the precompiled-binary source) is removed, so the
  crate always builds from source with the patch in.
