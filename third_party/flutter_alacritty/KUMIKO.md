# Vendored `flutter_alacritty`

The terminal engine's Dart package (ADR 0010), vendored so Kumiko can carry
a fix the published package does not have. Its native crate is vendored
beside it (`../rust_lib_flutter_alacritty/KUMIKO.md`).

- **Source:** `flutter_alacritty` 2.4.1 from pub.dev (archive SHA-256
  `6a1f0bfcaacd98f2fe3a9a625fbe606028ecb0ac1bf61eaa17fd23eff1a9926c`),
  https://github.com/hhoao/flutter_alacritty. Only `lib/`, `pubspec.yaml`
  and the licence are kept; every file but the patched one is unchanged.
- **Licence:** MIT (`LICENSE`).

## Patch

**Cell backgrounds are drawn as one triangle batch**
(`lib/render/terminal_painter.dart`, `_RectBatch`). The painter drew each
background run, selection run and dirty-row clear as its own `drawRect`
with `isAntiAlias = false`. Impeller, Flutter's renderer on Windows and
macOS, still anti-aliases those edges, so where a row edge falls between
pixels both rows half-cover the shared pixel row and the default background
shows through: a dark line between every row of a fullscreen program. The
runs are now collected and drawn with one `drawVertices` per pass; triangles
of one draw that share an edge cover each pixel exactly once. Test:
`packages/desktop/integration_test/terminal_surface_test.dart` (no seam
between rows at pixel ratios 1.0, 1.25 and 1.5).

To move to a newer upstream version, copy its `lib/`, `pubspec.yaml` and
licence again and re-apply the patch until upstream carries the fix.
