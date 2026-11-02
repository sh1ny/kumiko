/// One accepted tool-endpoint connection, independent of the transport.
///
/// A POSIX unix `Socket` and a Windows named-pipe connection both adapt to
/// this. The service owns the connection after `ToolService.accept`: it
/// listens to [input] exactly once and closes the connection when done.
abstract interface class ToolConnection {
  /// Bytes from the peer. Done means the peer closed (EOF).
  Stream<List<int>> get input;

  /// Queues [bytes] for the peer. Must not block; may throw when closed.
  void add(List<int> bytes);

  /// Closes the transport. The future completes when the transport is fully
  /// closed (for a Windows pipe: its worker has been joined), so the service
  /// can count the connection slot free only then. Safe to call repeatedly.
  Future<void> close();
}
