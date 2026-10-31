import 'dart:convert';
import 'dart:ui' as ui;

import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart' show RustLib;
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The adopted engine's view as the app shows it (ADR 0010), in a real
/// window with the platform's renderer: what the scripted bar items read
/// from the grid cannot show.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The engine applies output on post-frame callbacks.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(RustLib.init);

  Future<(AlacrittySurface, GlobalKey)> show(WidgetTester tester) async {
    final surface = AlacrittySurface();
    addTearDown(surface.dispose);
    final key = GlobalKey();
    // A MaterialApp, as the app gives it: the search bar is a text field.
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 400,
            child: RepaintBoundary(key: key, child: surface.view),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    return (surface, key);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('pending rises on feed and returns to 0 once the grid holds '
      'every byte, before and after the engine binds', (tester) async {
    final surface = AlacrittySurface();
    addTearDown(surface.dispose);
    expect(surface.pending.value, 0);

    // Before the view gives the engine a size, the bytes are held.
    final early = utf8.encode('\x1b[2J\x1b[Hearly\r\n');
    surface.feed(Uint8List.fromList(early));
    expect(surface.pending.value, early.length);

    await tester.pumpWidget(
      MaterialApp(home: SizedBox(width: 800, height: 400, child: surface.view)),
    );
    await settle(tester);
    expect(surface.pending.value, 0, reason: 'applied at the first size');
    expect(
      surface.engine.grid.codepointAt(0, 0),
      0x65,
      reason: 'the held bytes',
    );

    // Bound: queued bytes count at once, and drain to 0.
    final lines = utf8.encode('line\r\n' * 2000);
    surface.feed(Uint8List.fromList(lines));
    expect(surface.pending.value, lines.length);
    for (var i = 0; i < 50 && surface.pending.value != 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(surface.pending.value, 0);
  });

  testWidgets('output held by synchronized output that never ends is shown '
      'once its deadline has passed', (tester) async {
    final (surface, _) = await show(tester);
    String row0() => String.fromCharCodes([
      for (var c = 0; c < 6; c++) surface.engine.grid.codepointAt(0, c),
    ]);
    surface.feed(utf8.encode('\x1b[2J\x1b[H'));
    await settle(tester);
    // The program begins a synchronized update and dies before ending it.
    // The engine's own tests show the hold; here the view catches up once
    // the update's deadline has passed, with no further output.
    surface.feed(utf8.encode('\x1b[?2026hfrozen'));
    for (var i = 0; i < 30 && row0() != 'frozen'; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(row0(), 'frozen');
  });

  testWidgets('a query sent in a synchronized update that never ends is '
      'answered once its deadline has passed', (tester) async {
    final (surface, _) = await show(tester);
    final sent = <int>[];
    final sub = surface.input.listen(sent.addAll);
    addTearDown(sub.cancel);
    surface.feed(utf8.encode('\x1b[2J\x1b[H'));
    await settle(tester);
    // The program asks for the cursor position inside the update and waits
    // for the reply, with no further output.
    surface.feed(utf8.encode('\x1b[?2026h\x1b[6n'));
    for (var i = 0; i < 30 && sent.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(latin1.decode(sent), '\x1b[1;1R');
  });

  testWidgets('a mouse drag selects text', (tester) async {
    final (surface, key) = await show(tester);
    surface.feed(utf8.encode('\x1b[2J\x1b[H${'hello\r\n' * 3}'));
    await settle(tester);

    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final drag = await tester.startGesture(
      origin + const Offset(1, 12),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    for (var x = 20.0; x <= 300; x += 20) {
      await drag.moveTo(origin + Offset(x, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await settle(tester);

    expect(surface.engine.selectionText(), 'hello');
  });

  testWidgets('a right click goes to a program that asked for mouse reports', (
    tester,
  ) async {
    final (surface, key) = await show(tester);
    final sent = <int>[];
    final sub = surface.input.listen(sent.addAll);
    addTearDown(sub.cancel);
    // Click reporting in SGR encoding, as a TUI turns it on.
    surface.feed(utf8.encode('\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006h'));
    await settle(tester);

    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final click = await tester.startGesture(
      box.localToGlobal(const Offset(40, 40)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await click.up();
    await settle(tester);

    // Button 2 pressed, then released, at the same cell.
    expect(
      latin1.decode(sent),
      matches(RegExp(r'^\x1b\[<2;(\d+;\d+)M\x1b\[<2;\1m$')),
    );
  });

  testWidgets('Ctrl+Shift+F opens a search that marks the matches', (
    tester,
  ) async {
    final (surface, key) = await show(tester);
    surface.feed(utf8.encode('\x1b[2J\x1b[Halpha\r\nneedle here\r\nomega\r\n'));
    await settle(tester);

    // A click focuses the view.
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final click = await tester.startGesture(
      box.localToGlobal(const Offset(400, 300)),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await click.up();
    await settle(tester);

    expect(find.byType(TextField).hitTestable(), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);

    final field = find.byType(TextField).hitTestable();
    expect(field, findsOneWidget);
    await tester.enterText(field, 'needle');
    await settle(tester);

    final grid = surface.engine.grid;
    final marked = [
      for (var c = 0; c < 11; c++)
        isMatch(grid.flagsAt(1, c)) || isCurrentMatch(grid.flagsAt(1, c)),
    ];
    expect(marked, [...List.filled(6, true), ...List.filled(5, false)]);
  });

  testWidgets('adjacent rows of one background colour leave no seam', (
    tester,
  ) async {
    final (surface, key) = await show(tester);
    // Every cell gets the same non-default background.
    surface.feed(utf8.encode('\x1b[48;2;0;0;200m\x1b[2J\x1b[H'));
    await settle(tester);

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Fractional and whole pixel ratios put row edges between pixels.
    for (final ratio in [1.0, 1.25, 1.5]) {
      final image = await boundary.toImage(pixelRatio: ratio);
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final seams = <String>[];
      for (final x in [image.width ~/ 4, image.width * 3 ~/ 4]) {
        // Outside the grid (the view's leftover padding) is not painted; the
        // grid's first and last pixel rows are its outer edge, not a seam
        // between rows.
        bool opaque(int y) =>
            rgba.getUint8((y * image.width + x) * 4 + 3) == 255;
        final top = List.generate(image.height, (y) => y).firstWhere(opaque);
        final bottom = List.generate(image.height, (y) => y).lastWhere(opaque);
        for (var y = top + 1; y < bottom; y++) {
          final o = (y * image.width + x) * 4;
          final rgb = (
            rgba.getUint8(o),
            rgba.getUint8(o + 1),
            rgba.getUint8(o + 2),
          );
          if (rgb != (0, 0, 200)) seams.add('($x,$y) $rgb');
        }
      }
      image.dispose();
      expect(seams, isEmpty, reason: 'pixel ratio $ratio');
    }
  });
}
