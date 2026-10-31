import 'package:host/src/terminal/terminal_environment.dart';
import 'package:test/test.dart';

void main() {
  group('terminalEnvironment', () {
    test('POSIX terminals default to TERM=xterm-256color and '
        'COLORTERM=truecolor', () {
      expect(terminalEnvironment(posix: true, profileEnv: const {}), {
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
      });
    });

    test(
      'a profile TERM wins over the POSIX default; other entries are kept',
      () {
        expect(
          terminalEnvironment(
            posix: true,
            profileEnv: const {'TERM': 'screen', 'EDITOR': 'hx'},
          ),
          {'TERM': 'screen', 'COLORTERM': 'truecolor', 'EDITOR': 'hx'},
        );
      },
    );

    test('Windows terminals get no TERM or COLORTERM', () {
      expect(terminalEnvironment(posix: false, profileEnv: const {}), isEmpty);
      expect(
        terminalEnvironment(posix: false, profileEnv: const {'EDITOR': 'hx'}),
        {'EDITOR': 'hx'},
      );
    });
  });
}
