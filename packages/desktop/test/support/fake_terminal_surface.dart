import 'dart:async';
import 'dart:convert';

import 'package:desktop/src/terminal/terminal_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A [TerminalSurface] without an engine. Consumption is instant until
/// [stall]; then fed bytes stay [pending] until [resume].
class FakeTerminalSurface implements TerminalSurface {
  FakeTerminalSurface(this.number, {this.scrollbackLimit = 10000});

  final int number;

  @override
  final int scrollbackLimit;

  /// Every fed chunk, in order.
  final List<Uint8List> fed = [];
  bool disposed = false;
  bool _stalled = false;
  final ValueNotifier<int> _pending = ValueNotifier(0);
  final StreamController<Uint8List> _input = StreamController.broadcast(
    sync: true,
  );
  final StreamController<(int, int)> _size = StreamController.broadcast(
    sync: true,
  );
  (int, int)? _lastSize = (100, 30);

  int get fedBytes => fed.fold(0, (n, c) => n + c.length);

  /// Everything fed, as one list.
  List<int> get fedAll => [for (final c in fed) ...c];

  /// Stops consuming: fed bytes stay pending.
  void stall() => _stalled = true;

  /// Applies every pending byte and consumes instantly again.
  void resume() {
    _stalled = false;
    _pending.value = 0;
  }

  /// The view reports a new grid size.
  void emitSize(int cols, int rows) => _size.add(_lastSize = (cols, rows));

  /// The user types or pastes [bytes].
  void type(Uint8List bytes) => _input.add(bytes);

  @override
  void feed(Uint8List bytes) {
    fed.add(bytes);
    if (_stalled) _pending.value += bytes.length;
  }

  @override
  ValueListenable<int> get pending => _pending;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Stream<(int cols, int rows)> get size async* {
    if (_lastSize case final last?) yield last;
    yield* _size.stream;
  }

  final FocusNode _focus = FocusNode();

  @override
  void requestFocus() {
    if (_focus.context != null) _focus.requestFocus();
  }

  /// Like a real terminal view, it turns every key press into input once it
  /// has the keyboard focus, so a test can tell whether a chord reached it.
  @override
  Widget get view => Directionality(
    textDirection: TextDirection.ltr,
    child: Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        // A real terminal sends nothing for a modifier on its own.
        if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
            event.logicalKey == LogicalKeyboardKey.controlRight ||
            event.logicalKey == LogicalKeyboardKey.shiftLeft ||
            event.logicalKey == LogicalKeyboardKey.shiftRight ||
            event.logicalKey == LogicalKeyboardKey.altLeft ||
            event.logicalKey == LogicalKeyboardKey.altRight ||
            event.logicalKey == LogicalKeyboardKey.metaLeft ||
            event.logicalKey == LogicalKeyboardKey.metaRight) {
          return KeyEventResult.ignored;
        }
        type(
          Uint8List.fromList(utf8.encode('key:${event.logicalKey.keyLabel}')),
        );
        return KeyEventResult.handled;
      },
      child: Text('surface $number', key: ValueKey('surface-$number')),
    ),
  );

  @override
  void dispose() {
    disposed = true;
    _focus.dispose();
  }
}

/// The factory a controller uses, remembering every surface it made.
class FakeSurfaces {
  final List<FakeTerminalSurface> made = [];

  FakeTerminalSurface call({int scrollbackLimit = defaultScrollbackLimit}) {
    final surface = FakeTerminalSurface(
      made.length + 1,
      scrollbackLimit: scrollbackLimit,
    );
    made.add(surface);
    return surface;
  }

  FakeTerminalSurface get last => made.last;
}
