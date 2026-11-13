import 'package:host/src/agent/codex/codex_auth_signal.dart';
import 'package:host/src/agent/codex/codex_auth_signatures.dart';
import 'package:host/src/host_options.dart';
import 'package:test/test.dart';

void main() {
  test('confirmed signals project to names without a version gate', () {
    expect(
      HostOptions.projectCodexAuthSignatures([
        ('0.166.0', 'windows', 'turn-http-401'),
        ('0.167.0', 'linux', 'account-unauthenticated'),
        ('0.167.0', 'macos', 'turn-http-401'),
      ]),
      {CodexAuthSignal.turnHttp401, CodexAuthSignal.accountUnauthenticated},
    );
  });
  test('an unknown registry signal is refused', () {
    expect(
      () => HostOptions.projectCodexAuthSignatures([
        ('0.166.0', 'windows', 'unauthorized'),
      ]),
      throwsArgumentError,
    );
  });
  test('signal names are closed', () {
    expect(
      CodexAuthSignal.named('account-unauthenticated'),
      CodexAuthSignal.accountUnauthenticated,
    );
    expect(CodexAuthSignal.named('turn-http-401'), CodexAuthSignal.turnHttp401);
    expect(CodexAuthSignal.named('Turn-Http-401'), isNull);
  });
  test('the production registry projects only real observations', () {
    expect(
      const HostOptions().codexAuthSignatures,
      HostOptions.projectCodexAuthSignatures(confirmedCodexAuthSignatures),
    );
  });
}
