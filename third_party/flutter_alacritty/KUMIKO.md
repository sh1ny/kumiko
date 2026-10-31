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
arrives. It then routes the engine's events, as an advance does, so a reply
to a query held in the update (a cursor position report) reaches the program
waiting on it. Tests: `packages/desktop/integration_test/terminal_surface_test.dart`
(output held by synchronized output that never ends is shown; a query sent in
a synchronized update that never ends is answered).

**A right click goes to a program that asked for mouse reports**
(`lib/ui/terminal_view_pointer.dart`). The view kept every right click for
its local menu, even when the program had turned on mouse reporting, so a
TUI never saw button 2. It now reports the press and release, as it does for
the other buttons; Shift still opens the local menu, as Shift still selects
locally. Test: `packages/desktop/integration_test/terminal_surface_test.dart`
(a right click goes to a program that asked for mouse reports).

**A move with no button held is reported under all-motion mode**
(`lib/ui/terminal_view.dart`, `lib/ui/terminal_view_pointer.dart`). Flutter
delivers such a move as a hover, which the view used only for its cursor, so
a program that turned on DEC 1003 never saw one. The hover now reports the
motion too, as a move with no button does. Test:
`packages/desktop/integration_test/terminal_surface_test.dart` (moving with
no button held is reported under all-motion mode).

**Underlined and struck-through blanks keep their lines**
(`lib/render/terminal_painter.dart`). The painter skipped a space or empty
cell before it reached the decorations, so underlined spaces drew no
underline and an underlined phrase had gaps between its words. A blank now
skips only the glyph. Test:
`packages/desktop/integration_test/terminal_surface_test.dart` (underlined
spaces draw their underline).

**Scrolls applied before a paint add up** (`lib/render/mirror_grid.dart`).
The mirror kept only the last scroll's delta for the painter, which shifts
its retained frame by it, though every scroll since the last paint had
rotated the rows; rows marked for repaint before a scroll kept their old
index. The delta now accumulates until the painter takes it, and the marked
rows move with the content. Test: `packages/desktop/test/mirror_grid_test.dart`.

**UTF-8 mouse coordinates** (`lib/input/mouse_input.dart`,
`lib/input/term_mode.dart`). A program that turned on DEC 1005 got the
one-byte legacy encoding, so a column or row past 95 arrived as a malformed
byte and one past 223 at the wrong position. In that mode each value is now
sent as a UTF-8 character. Test: `packages/desktop/test/vendored_input_test.dart`.

**An emptied search clears the engine's** (`lib/controller/terminal_controller.dart`).
The engine compiles an empty pattern as an active search, and closing the bar
then found nothing to clear, so every later update stayed a full, searched
snapshot. An empty pattern now clears the engine's search. Test:
`packages/desktop/test/vendored_input_test.dart`.

**An IME commit without the sentinel is sent whole** (`lib/input/ime_session.dart`).
A commit longer than the two-space sentinel lost its first two characters
even when the IME had not kept the sentinel. They are now dropped only when
the text starts with it. Test: `packages/desktop/test/vendored_input_test.dart`.

To move to a newer upstream version, copy its `lib/`, `pubspec.yaml` and
licence again and re-apply the patch until upstream carries the fix.
