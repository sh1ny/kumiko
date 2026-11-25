import 'dart:async';
import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';

import '../tools/tool_catalog.dart';
import 'omp_client.dart';

/// Authority carried by one private OMP stdio connection. Registration alone
/// authorizes nothing. The host binds its saved run only after registration.
final class OmpHostTools {
  OmpHostTools(this._client);

  static const _maxWrites = 8;
  static const _maxIdBytes = 4096;
  static const _maxResultBytes = 4096;
  final OmpClient _client;
  final _writes = <String, _ToolWrite>{};
  bool _attempted = false;
  bool _revoked = false;
  ToolRole? _registeredRole;
  _Binding? _binding;

  bool get registered => !_revoked && _registeredRole != null;

  Future<String?> register(ToolRole role) async {
    if (_attempted) {
      throw StateError('OMP tools registration already attempted');
    }
    _attempted = true;
    final definitions = ToolCatalog.toolsFor(role);
    final Object? data;
    try {
      data = await _client.request('set_host_tools', {
        'tools': [
          for (final tool in definitions)
            {
              'name': tool.name,
              'label': tool.name,
              'description': tool.description,
              'parameters': tool.inputSchema,
              'loadMode': 'essential',
            },
        ],
      });
    } on OmpRemoteException catch (error) {
      return clampUtf8('OMP tool registration refused: ${error.message}', 4096);
    } on TimeoutException {
      _requireTransport();
      return 'OMP tool registration timed out';
    }
    _requireTransport();
    final names = data is Json ? data['toolNames'] : null;
    if (names is! List<Object?> || names.length != definitions.length) {
      return 'OMP tool registration acknowledgement did not match the catalog';
    }
    for (var i = 0; i < definitions.length; i++) {
      if (names[i] != definitions[i].name) {
        return 'OMP tool registration acknowledgement did not match the catalog';
      }
    }
    _registeredRole = role;
    return null;
  }

  void _requireTransport() {
    if (_client.isClosed) {
      throw _client.failure ?? OmpProtocolException('tool transport closed');
    }
  }

  void bind(ToolRunFacts facts, void Function() onSucceeded) {
    if (_revoked || _registeredRole != facts.role || _binding != null) {
      throw StateError('cannot bind OMP tools to this run');
    }
    _binding = _Binding(facts, onSucceeded);
  }

  void revoke() {
    _revoked = true;
    _binding = null;
  }

  void receive(Json frame, {required bool inputClosed}) {
    if (inputClosed || _client.isClosed) return;
    if (frame['type'] == 'host_tool_cancel') {
      final write = _writes[_callbackId(frame['targetId'])];
      if (write != null) write.cancelled = true;
      return;
    }
    final id = _callbackId(frame['id']);
    if (_writes.containsKey(id)) {
      throw OmpProtocolException('duplicate live OMP tool callback id');
    }
    final binding = _binding;
    if (binding == null) {
      _reply(
        id,
        'Kumiko tools are unavailable for this run',
        isError: true,
      ).ignore();
      return;
    }
    if (_writes.length >= _maxWrites) {
      _reply(
        id,
        'Too many concurrent Kumiko tool calls',
        isError: true,
      ).ignore();
      return;
    }
    if (!_validId(frame['toolCallId'])) {
      _reply(id, 'Invalid OMP tool activity id', isError: true).ignore();
      return;
    }
    final reason = ToolCatalog.refusal(
      binding.facts.role,
      frame['toolName'],
      frame['arguments'],
      describeInput: false,
    );
    if (reason != null) {
      _reply(id, reason, isError: true).ignore();
      return;
    }
    final text = jsonEncode(binding.facts.sessionInfo());
    if (jsonStringContentBytes(text) > _maxResultBytes) {
      _reply(
        id,
        'Kumiko tool result exceeds the display bound',
        isError: true,
      ).ignore();
      return;
    }
    final Future<void> write;
    try {
      write = _reply(id, text);
    } on RpcException catch (error) {
      if (error.reason != ErrorCode.busy) rethrow;
      // Do not queue a retry. If even the mandatory refusal cannot fit,
      // let the frame reader fail the run rather than leave OMP waiting.
      _reply(id, 'Kumiko tools are busy', isError: true).ignore();
      return;
    }
    final receipt = _writes[id] = _ToolWrite();
    unawaited(
      write.then<void>(
        (_) {
          _writes.remove(id);
          if (!receipt.cancelled &&
              !_client.isClosed &&
              identical(_binding, binding)) {
            binding.onSucceeded();
          }
        },
        onError: (Object _) {
          _writes.remove(id);
        },
      ),
    );
  }

  Future<void> _reply(String id, String text, {bool isError = false}) =>
      _client.send({
        'type': 'host_tool_result',
        'id': id,
        if (isError) 'isError': true,
        'result': {
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      });

  static bool _validId(Object? id) =>
      id is String &&
      id.isNotEmpty &&
      id.length <= _maxIdBytes &&
      jsonStringContentBytes(id) <= _maxIdBytes;

  static String _callbackId(Object? id) {
    if (!_validId(id)) {
      throw OmpProtocolException('invalid OMP tool callback id');
    }
    return id! as String;
  }
}

final class _Binding {
  const _Binding(this.facts, this.onSucceeded);
  final ToolRunFacts facts;
  final void Function() onSucceeded;
}

final class _ToolWrite {
  bool cancelled = false;
}
