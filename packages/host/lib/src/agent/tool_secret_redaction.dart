import 'dart:math';

/// Removes known run secrets before strings leave the host.
///
/// Native errors, metadata and stderr may already be clipped. Remove matching
/// boundary fragments of at least four characters, as the streaming redactor
/// does for an unfinished token, so clipping cannot expose most of a secret.
String redactToolSecrets(
  String text,
  Iterable<String> secrets, {
  bool clippedBoundaries = true,
}) {
  var result = text;
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    result = result.replaceAll(secret, '<redacted>');
    if (!clippedBoundaries) continue;
    for (
      var length = min(secret.length - 1, result.length);
      length >= 4;
      length--
    ) {
      if (result.endsWith(secret.substring(0, length))) {
        result = '${result.substring(0, result.length - length)}<redacted>';
        break;
      }
    }
    for (
      var length = min(secret.length - 1, result.length);
      length >= 4;
      length--
    ) {
      if (result.startsWith(secret.substring(secret.length - length))) {
        result = '<redacted>${result.substring(length)}';
        break;
      }
    }
  }
  return result;
}
