import 'package:flutter_alacritty/controller/terminal_controller.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/ime_session.dart';
import 'package:flutter_alacritty/input/mouse_input.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored engine's input and search, where Kumiko patched them.
void main() {
  group('UTF-8 mouse mode (DEC 1005)', () {
    const click = kModeMouseClick | kModeUtf8Mouse;

    test('a coordinate past 95 is sent as a UTF-8 character', () {
      // Column 100 + 32 = 132 = U+0084, row 5 + 32 = 37.
      expect(encodeMouse(0, MouseAction.down, 100, 5, modeFlags: click), [
        0x1b, 0x5b, 0x4d, 32, 0xc2, 0x84, 37, //
      ]);
    });

    test('a coordinate past 223 keeps its position', () {
      // Column 300 + 32 = 332 = U+014C.
      expect(encodeMouse(0, MouseAction.down, 300, 1, modeFlags: click), [
        0x1b, 0x5b, 0x4d, 32, 0xc5, 0x8c, 33, //
      ]);
    });

    test('without it, a coordinate is one byte', () {
      expect(
        encodeMouse(0, MouseAction.down, 100, 5, modeFlags: kModeMouseClick),
        [0x1b, 0x5b, 0x4d, 32, 132, 37],
      );
    });
  });

  group('IME commit', () {
    test('a commit without the sentinel is sent whole', () {
      final committed = <String>[];
      final session = ImeSession(
        onCommit: committed.add,
        onPreeditChanged: (_) {},
        onBackspace: () {},
      );
      session.updateEditingValue(const TextEditingValue(text: '你好世界'));
      session.updateEditingValue(const TextEditingValue(text: '  abc'));
      expect(committed, ['你好世界', 'abc']);
    });
  });

  group('search', () {
    test('emptying the pattern clears the engine search', () {
      final engine = _Engine();
      final controller = TerminalController()..attach(engine);
      addTearDown(controller.dispose);

      controller.searchSet('needle');
      controller.searchSet('');
      expect(engine.calls, ['set needle', 'clear']);

      // Closing the bar afterwards has nothing left to clear.
      controller.searchClear();
      expect(engine.calls, ['set needle', 'clear']);
    });
  });
}

class _Engine extends Fake implements TerminalEngine {
  final calls = <String>[];

  @override
  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) {
    calls.add('set $pattern');
    return true;
  }

  @override
  void searchClear() => calls.add('clear');
}
