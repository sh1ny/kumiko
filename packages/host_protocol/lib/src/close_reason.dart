/// Why a connection ended, observable by its owner.
class CloseReason {
  const CloseReason(this.kind, [this.detail = '']);

  /// The peer broke the wire contract.
  static const String protocolViolation = 'protocol-violation';

  /// Pending outbound control passed its bound: the peer counts as lost.
  static const String controlOverflow = 'control-overflow';

  /// The input ended.
  static const String inputClosed = 'input-closed';

  /// The output failed.
  static const String writeFailed = 'write-failed';

  /// The local owner closed the connection.
  static const String closedLocally = 'closed';

  final String kind;
  final String detail;

  @override
  String toString() => detail.isEmpty ? kind : '$kind: $detail';
}
