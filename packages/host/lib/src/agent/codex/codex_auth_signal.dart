/// Closed, structured Codex sign-in signals (design D7, structured
/// authentication signals). Exact request error pairs never classify Codex
/// authentication: signed-out Codex answers no request with an error.
enum CodexAuthSignal {
  /// Start-only preflight: the effective provider for the start folder is
  /// OpenAI, `account/read` reports no account and `requiresOpenaiAuth` true.
  accountUnauthenticated('account-unauthenticated'),

  /// A failed `turn/completed` whose structured error is an HTTP 401.
  turnHttp401('turn-http-401');

  const CodexAuthSignal(this.wireName);

  /// The name used by the registry, the record and the test override.
  final String wireName;

  /// The signal with [name], or null for any other name.
  static CodexAuthSignal? named(String name) {
    for (final signal in values) {
      if (signal.wireName == name) return signal;
    }
    return null;
  }
}
