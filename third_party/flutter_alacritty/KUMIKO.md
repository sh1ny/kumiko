# Vendored `flutter_alacritty`

The terminal engine's Dart package (ADR 0010), vendored so Kumiko can carry
a fix the published package does not have. Its native crate is vendored
beside it (`../rust_lib_flutter_alacritty/KUMIKO.md`).

- **Source:** `flutter_alacritty` 2.4.1 from pub.dev (archive SHA-256
  `6a1f0bfcaacd98f2fe3a9a625fbe606028ecb0ac1bf61eaa17fd23eff1a9926c`),
  https://github.com/hhoao/flutter_alacritty. Only `lib/`, `pubspec.yaml`
  and the licence are kept; every file but the patched ones is unchanged.
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

**The engine reports the bytes it has not applied**
(`lib/engine/terminal_engine_client.dart`, `lib/engine/terminal_engine.dart`).
The client coalesces fed bytes and advances the engine off the UI thread, so
the host has no way to tell whether the engine keeps up with a flood. The
client now counts the bytes queued plus those of the advance in flight
(`pending`), and `TerminalEngine.pending` exposes it (before the first
`resize`, the bytes held for the binding). It reaches 0 once the grid holds
every byte fed. Kumiko's terminal controller pauses reading a host terminal
when it exceeds 1 MiB. Test:
`packages/desktop/integration_test/terminal_surface_test.dart` (pending rises
on feed and returns to 0).

**A held present is looked at again after the update's deadline**
(`lib/engine/terminal_engine_client.dart`). The client skipped presents while
the engine reported synchronized output and presented again only with the
next output. The native crate now applies an update whose deadline passed
(its `KUMIKO.md`); a timer takes a snapshot after that deadline, so a program
that died mid-update does not leave the view frozen until more output
arrives. Test: `packages/desktop/integration_test/terminal_surface_test.dart`
(output held by synchronized output that never ends is shown).

To move to a newer upstream version, copy its `lib/`, `pubspec.yaml` and
licence again and re-apply the patch until upstream carries the fix.
