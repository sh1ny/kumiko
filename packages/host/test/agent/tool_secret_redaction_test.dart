import 'package:host/src/agent/codex/codex_client.dart';
import 'package:host/src/agent/tool_secret_redaction.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

// Synthetic 43-character token, never a live grant or provider credential.
const _secret = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

void main() {
  test(
    'untruncated streaming callback leaves boundary fragments to carry owner',
    () {
      final prefix = _secret.substring(0, 42);
      expect(
        redactToolSecrets(prefix, [_secret], clippedBoundaries: false) ==
            prefix,
        true,
      );
      expect(
        redactToolSecrets(_secret, [_secret], clippedBoundaries: false),
        '<redacted>',
      );
    },
  );
  test(
    'native error clamp cannot expose a near-complete run-secret prefix',
    () {
      final prefix = _secret.substring(0, _secret.length - 1);
      final error = CodexRemoteException(
        -32000,
        '${'!' * (4096 - prefix.length)}$_secret',
      );
      expect(error.messageTruncated, isTrue);
      final public = redactToolSecrets(error.message, [_secret]);
      expect(public.contains(prefix), isFalse);
      expect(public.endsWith('<redacted>'), isTrue);
    },
  );

  test('bounded metadata cannot expose a near-complete run-secret prefix', () {
    final prefix = _secret.substring(0, _secret.length - 1);
    final title = clampUtf8('${'!' * (4096 - prefix.length)}$_secret', 4096);
    final public = redactToolSecrets(title, [_secret]);
    expect(public.contains(prefix), isFalse);
    expect(public.endsWith('<redacted>'), isTrue);
  });

  test('stderr tail cannot expose a near-complete run-secret suffix', () {
    final suffix = _secret.substring(1);
    final raw = '$_secret${'!' * (4096 - suffix.length)}';
    final tail = raw.substring(raw.length - 4096);
    final public = redactToolSecrets(tail, [_secret]);
    expect(public.contains(suffix), isFalse);
    expect(public.startsWith('<redacted>'), isTrue);
  });

  test('every substantial boundary prefix and suffix is removed', () {
    for (var length = 4; length < _secret.length; length++) {
      final prefix = _secret.substring(0, length);
      final suffix = _secret.substring(_secret.length - length);
      final atEnd = redactToolSecrets('public: $prefix', [_secret]);
      final atStart = redactToolSecrets('$suffix public', [_secret]);
      expect(atEnd.endsWith(prefix), isFalse, reason: 'prefix length $length');
      expect(
        atStart.startsWith(suffix),
        isFalse,
        reason: 'suffix length $length',
      );
    }
  });

  test('full tokens in strings redact without changing unrelated text', () {
    expect(
      redactToolSecrets('before $_secret after', [_secret]),
      'before <redacted> after',
    );
    expect(
      redactToolSecrets('ordinary public diagnostic', [_secret]),
      'ordinary public diagnostic',
    );
    expect(
      redactToolSecrets('public ${_secret.substring(0, 3)}', [_secret]),
      'public ${_secret.substring(0, 3)}',
    );
    expect(
      redactToolSecrets('${_secret.substring(_secret.length - 3)} public', [
        _secret,
      ]),
      '${_secret.substring(_secret.length - 3)} public',
    );
    expect(redactToolSecrets('public', const []), 'public');
    expect(redactToolSecrets('public', const ['']), 'public');
  });

  test('all retained run secrets remain eligible at boundaries', () {
    const other = 'qrstuvwxyz0123456789_-abcdefghijklmnopqrstuv';
    final public = redactToolSecrets(
      '${other.substring(1)} body ${_secret.substring(0, 42)}',
      [_secret, other],
    );
    expect(public == '<redacted> body <redacted>', isTrue);
  });
}
