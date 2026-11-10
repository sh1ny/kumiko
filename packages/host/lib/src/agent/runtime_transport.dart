import 'dart:async';

/// Concrete ownership seam for runtime-driver transports. Runtime drivers own
/// native mapping, AgentService/AgentSession own processes and turns. The
/// protocol-specific normalizers reduce envelopes under the line permit,
/// then consume bounded values outside it. No raw event stream, second queue
/// or independent lifecycle.
/// Operation-level native mapping attaches with shared startup in group 4.
abstract interface class RuntimeTransport {
  bool get isClosed;
  Object? get failure;
  Future<void> get done;
  set onFailure(void Function(Object error)? handler);
  set consumeNotification(FutureOr<void> Function(Object value)? handler);
  Future<void> close();
}
