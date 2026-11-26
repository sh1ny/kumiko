import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import '../native_io.dart';
import '../runtime_transport.dart';

class OmpProtocolException implements Exception {
  OmpProtocolException(String message) : message = clampUtf8(message, 4096);

  final String message;

  @override
  String toString() => 'OMP protocol: $message';
}

class OmpRemoteException implements Exception {
  OmpRemoteException(String message, Object? code)
    : message = clampUtf8(message, 4096),
      code = code is String ? clampUtf8(code, 4096) : code;

  final String message;
  final Object? code;

  @override
  String toString() => 'OMP error${code == null ? '' : ' $code'}: $message';
}

/// Private v1 NDJSON transport. The driver owns the protocol's session and
/// event payloads; this client owns only framing, command admission and replies.
class OmpClient implements RuntimeTransport {
  OmpClient({
    required Stream<List<int>> input,
    required Future<void> Function(List<int>) write,
    LargeLinePermit? largeLinePermit,
  }) {
    _writer = NativeWriteAdmission(write, _fail, _closedError);
    _reader = NativeLineReader(
      input: input,
      permit: largeLinePermit ?? LargeLinePermit.shared,
      normalize: _decode,
      consume: _consume,
      protocolError: OmpProtocolException.new,
      onEof: _outputEnded,
      onError: _fail,
    )..start();
  }

  late final NativeLineReader _reader;
  late final NativeWriteAdmission _writer;
  final _pending = <String, _Pending>{};
  final _done = Completer<void>();
  int _issued = 0;
  Object? _failure;
  bool _shutdownEofExpected = false;
  bool _shutdownEofObserved = false;

  /// An ordinary EOF is otherwise a transport failure on a live run.
  void expectShutdownEof() => _shutdownEofExpected = true;
  bool get shutdownEofObserved => _shutdownEofObserved;

  void _outputEnded() {
    if (_shutdownEofExpected) {
      _shutdownEofObserved = true;
      _close();
    } else {
      _fail(OmpProtocolException('native output closed'));
    }
  }

  /// When installed by the driver, reduce event payloads before releasing the
  /// large-line permit and awaiting bounded consumption.
  Object? Function(Json frame)? normalizeNotification;

  @override
  FutureOr<void> Function(Object value)? consumeNotification;
  @override
  void Function(Object error)? onFailure;
  @override
  Object? get failure => _failure;
  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<void> get done => _done.future;

  Object _closedError() => _failure ?? OmpProtocolException('transport closed');

  Future<Object?> request(String type, [Json fields = const {}]) =>
      command(type, fields: fields);

  Future<Object?> command(
    String type, {
    Json fields = const {},
    Duration timeout = const Duration(seconds: 60),
    void Function(String id)? onIssued,
    Object? Function(Object? data)? onSuccess,
    Object? Function(Object? data)? decodeData,
  }) {
    try {
      return admitCommand(
        type,
        fields: fields,
        timeout: timeout,
        onIssued: onIssued,
        onSuccess: onSuccess,
        decodeData: decodeData,
      );
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Admits a complete command and any preceding replies as one write.
  /// Capacity refusals are synchronous and consume neither bytes nor an id.
  Future<Object?> admitCommand(
    String type, {
    Json fields = const {},
    Iterable<Json> before = const [],
    Duration timeout = const Duration(seconds: 60),
    void Function(String id)? onIssued,
    Object? Function(Object? data)? onSuccess,
    Object? Function(Object? data)? decodeData,
  }) {
    _checkCapacity(1);
    final next = _issued + 1;
    final id = 'k$next';
    final command = {...fields, 'type': type, 'id': id};
    final bytes = before.isEmpty
        ? _encode(command)
        : utf8.encode(
            [
              for (final frame in before) jsonEncode(frame),
              jsonEncode(command),
              '',
            ].join('\n'),
          );
    final result = Completer<Object?>();
    _writer
        .admit(
          bytes,
          beforeWrite: () {
            onIssued?.call(id);
            _issued = next;
            _track(
              id,
              type,
              timeout,
              result,
              onSuccess: onSuccess,
              decodeData: decodeData,
            );
          },
        )
        .ignore();
    return result.future;
  }

  /// Installs all correlations only once the complete write is admitted.
  (Future<void>, List<Future<Object?>>) admitBatch(
    List<(String, Json)> commands, {
    required Iterable<Json> before,
    required Duration timeout,
  }) {
    _checkCapacity(commands.length);
    final bytes = BytesBuilder(copy: false);
    for (final reply in before) {
      bytes.add(_encode(reply));
    }
    final first = _issued + 1;
    final results = <Completer<Object?>>[];
    for (var i = 0; i < commands.length; i++) {
      final (type, fields) = commands[i];
      bytes.add(_encode({...fields, 'type': type, 'id': 'k${first + i}'}));
      results.add(Completer<Object?>());
    }
    final admission = _writer.admit(
      bytes.takeBytes(),
      beforeWrite: () {
        _issued += commands.length;
        for (var i = 0; i < commands.length; i++) {
          _track('k${first + i}', commands[i].$1, timeout, results[i]);
        }
      },
    );
    return (admission, [for (final result in results) result.future]);
  }

  void _checkCapacity(int count) {
    if (isClosed) throw _closedError();
    if (_pending.length + count > 32) {
      throw RpcException(ErrorCode.busy, 'OMP command capacity is 32');
    }
  }

  void _track(
    String id,
    String type,
    Duration timeout,
    Completer<Object?> result, {
    Object? Function(Object? data)? onSuccess,
    Object? Function(Object? data)? decodeData,
  }) {
    final timer = Timer(timeout, () {
      _pending
          .remove(id)
          ?.result
          .completeError(TimeoutException('OMP $type timed out', timeout));
    });
    _pending[id] = _Pending(result, timer, onSuccess, decodeData);
  }

  /// Writes an uncorrelated frame. A busy writer refuses synchronously.
  Future<void> send(Json frame) => _writer.admit(_encode(frame));

  static List<int> _encode(Json frame) => utf8.encode('${jsonEncode(frame)}\n');

  Object? _decode(Uint8List bytes) {
    final frame = jsonDecode(utf8.decode(bytes));
    if (frame is! Json || frame['type'] is! String || frame['type'] == '') {
      throw OmpProtocolException('expected a typed JSON object');
    }
    if (frame['type'] != 'response') {
      final normalize = normalizeNotification;
      return normalize == null ? frame : normalize(frame);
    }
    final id = frame['id'];
    if (id is! String) throw OmpProtocolException('invalid response id');
    final pending = _pending[id];
    if (pending == null) {
      final n = id.length > 1 && id.length <= 20 && id.startsWith('k')
          ? int.tryParse(id.substring(1), radix: 10)
          : null;
      if (n != null && n > 0 && n <= _issued && id == 'k$n') return null;
      throw OmpProtocolException('response id was never issued');
    }
    final success = frame['success'];
    final error = frame['error'];
    final code = frame['code'];
    if (success is! bool ||
        (!success &&
            (error is! String ||
                (code != null && code is! String && code is! int)))) {
      throw OmpProtocolException('invalid response envelope');
    }
    _pending.remove(id);
    pending.timer.cancel();
    if (success) {
      try {
        final decodeData = pending.decodeData;
        final data = decodeData == null
            ? frame['data']
            : bytes.length >= 1024 * 1024
            ? null
            : decodeData(frame['data']);
        final delivery = pending.onSuccess?.call(data);
        pending.result.complete(data);
        return delivery;
      } on Object catch (error, stack) {
        pending.result.completeError(error, stack);
        rethrow;
      }
    } else {
      pending.result.completeError(OmpRemoteException(error! as String, code));
    }
    return null;
  }

  Future<void> _consume(Object value) async => consumeNotification?.call(value);

  void _fail(Object error) {
    if (isClosed) return;
    final failure = _failure = error is OmpProtocolException
        ? error
        : OmpProtocolException(
            error is FormatException
                ? 'malformed native JSON or UTF-8'
                : '$error',
          );
    _close();
    onFailure?.call(failure);
  }

  void _close() {
    if (isClosed) return;
    _done.complete();
    _reader.close();
    _writer.close();
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.result.completeError(_closedError());
    }
    _pending.clear();
  }

  bool get largeLineOwned => _reader.largeLineOwned;
  bool get largeLineWaiting => _reader.largeLineWaiting;

  void fail(Object error) => _fail(error);

  @override
  Future<void> close() {
    _close();
    return done;
  }
}

class _Pending {
  _Pending(this.result, this.timer, this.onSuccess, this.decodeData);

  final Completer<Object?> result;
  final Timer timer;
  final Object? Function(Object? data)? onSuccess;
  final Object? Function(Object? data)? decodeData;
}
