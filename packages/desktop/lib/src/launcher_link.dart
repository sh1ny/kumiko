import 'package:host_protocol/host_protocol.dart';

import 'host_link.dart';

/// The real [HostLink] over a started [HostSession].
///
/// The cleanup wire shapes are the ones in `host_protocol`'s `messages.dart`.
class SessionLink implements HostLink {
  SessionLink(this.session);

  final HostSession session;

  @override
  HelloResult get hello => session.hello;

  @override
  Future<HostLoss> get lost => session.lost;

  @override
  Stream<CleanupState> get cleanupStates => session.cleanupStates;

  Json _json(Object? result) =>
      (result! as Map<Object?, Object?>).cast<String, Object?>();

  Future<Json> _request(String method, Json params) async =>
      _json(await session.connection.request(method, params));

  @override
  Future<CleanupListResult> cleanupList({String? cursor, int? revision}) async {
    final params = CleanupListParams(cursor: cursor, revision: revision);
    return CleanupListResult.fromJson(
      await _request(Method.cleanupList, params.toJson()),
    );
  }

  @override
  Future<CleanupActionResult> cleanupRetry(String workspace) async =>
      CleanupActionResult.fromJson(
        await _request(
          Method.cleanupRetry,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  @override
  Future<CleanupActionResult> cleanupConfirm(String workspace) async =>
      CleanupActionResult.fromJson(
        await _request(
          Method.cleanupConfirm,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  @override
  Future<void> quit() async {
    await session.quit();
  }
}

/// A connector that starts [launcher]'s host.
HostConnector launcherConnector(HostLauncher launcher) =>
    () async => SessionLink(await launcher.start());
