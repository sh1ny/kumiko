import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:process_containment/process_containment.dart';

import 'tool_service.dart';
import 'transport_tool_connection.dart';

/// Longest `sun_path` in bytes including the terminating NUL (macOS 104,
/// Linux 108). A path must be strictly shorter.
int get unixSocketPathLimit => Platform.isMacOS ? 104 : 108;

/// The host's per-user tool endpoint (design D2): a unix socket
/// `<profile>/tools.sock` on POSIX, an owner-only named pipe on Windows.
///
/// [start] never throws: a failure leaves the host running with the service
/// marked unavailable (design D7).
class ToolEndpoint {
  ToolEndpoint._(this.service, this._closer);

  final ToolService service;
  final Future<void> Function() _closer;
  Future<void>? _closing;

  /// The socket file name inside the profile directory.
  static const socketName = 'tools.sock';

  /// Creates the endpoint and attaches it to [service]. [fault] makes the
  /// creation fail with that cause (tests only). [log] receives one short
  /// line for the outcome.
  static Future<ToolEndpoint> start({
    required ToolService service,
    required Directory profile,
    String? fault,
    void Function(String op, String detail)? log,
  }) async {
    try {
      if (fault != null) throw _EndpointFailure(fault);
      final closer = Platform.isWindows
          ? await _startPipe(service)
          : await _startSocket(service, profile, log);
      log?.call('tool-endpoint', service.endpoint ?? '');
      return ToolEndpoint._(service, closer);
    } on _EndpointFailure catch (e) {
      service.markEndpointUnavailable(e.cause);
    } on Object catch (e) {
      service.markEndpointUnavailable('$e');
    }
    log?.call('tool-endpoint-failed', service.unavailableReason ?? '');
    return ToolEndpoint._(service, () async {});
  }

  /// Stops listening, removes the socket file, revokes every grant and
  /// closes every connection. Idempotent.
  Future<void> close() => _closing ??= () async {
    try {
      await _closer();
    } on Object {
      // Best effort at shutdown.
    }
    await service.close();
  }();

  static Future<Future<void> Function()> _startSocket(
    ToolService service,
    Directory profile,
    void Function(String, String)? log,
  ) async {
    final path = '${profile.path}${Platform.pathSeparator}$socketName';
    final bytes = utf8.encode(path).length;
    final limit = unixSocketPathLimit;
    if (bytes >= limit) {
      throw _EndpointFailure(
        'socket path is $bytes bytes; the limit is ${limit - 1}',
      );
    }
    // The profile lock makes this host the only owner: a socket file left by
    // a killed host is stale and replaced.
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    if (!chmodPath(path, 0x180)) {
      await server.close();
      _tryDelete(path);
      throw _EndpointFailure('cannot set mode 0600 on $path');
    }
    server.listen(
      (socket) => service.accept(
        TransportToolConnection(
          source: socket,
          write: (bytes) {
            socket.add(bytes);
            return socket.flush();
          },
          closeTransport: () async => socket.destroy(),
        ),
      ),
      onError: (Object e) {
        service.markEndpointUnavailable('accept failed: $e');
        log?.call('tool-endpoint-failed', '$e');
      },
    );
    service.markEndpointAvailable(path);
    return () async {
      await server.close();
      _tryDelete(path);
    };
  }

  static Future<Future<void> Function()> _startPipe(ToolService service) async {
    final WindowsPipeServer server;
    try {
      server = await WindowsPipeServer.start();
    } on WindowsPipeException catch (e) {
      throw _EndpointFailure(e.message);
    }
    server.connections.listen(
      (pipe) => service.accept(
        TransportToolConnection(
          source: pipe.incoming,
          write: pipe.add,
          closeTransport: pipe.close,
        ),
      ),
      onError: (Object e) =>
          service.markEndpointUnavailable('accept worker failed: $e'),
    );
    service.markEndpointAvailable(server.name);
    return server.close;
  }

  static void _tryDelete(String path) {
    try {
      final file = File(path);
      if (file.existsSync() ||
          FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        file.deleteSync();
      }
    } on FileSystemException {
      // Left behind; the next host replaces it under the profile lock.
    }
  }
}

class _EndpointFailure implements Exception {
  _EndpointFailure(this.cause);
  final String cause;
}
