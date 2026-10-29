import 'dart:async';
import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

Future<RpcException?> _failure(Future<Object?> request) =>
    request.then((_) => null, onError: (Object e) => e as RpcException);

void main() {
  test('highest common version and capability intersection', () async {
    final (desktop, host) = connectedPair(
      versionsA: const VersionRange(1, 3),
      versionsB: const VersionRange(2, 5),
      capabilitiesA: {Capability.testUnits, Capability.testChannels},
      capabilitiesB: {Capability.testChannels, Capability.testFaults},
    );

    final result = await desktop.hello();

    expect(result.version, 3);
    expect(result.capabilities, {Capability.testChannels});
    expect(result.instanceId, 'host-1');
    expect(result.state, HostState.ready);
    expect(desktop.negotiated?.version, 3);
    expect(host.negotiated?.capabilities, {Capability.testChannels});
  });

  test('negotiate is pure', () {
    final n = negotiate(
      const VersionRange(1, 2),
      {'a', 'b'},
      HelloParams(versions: const VersionRange(2, 9), capabilities: {'b', 'c'}),
    );
    expect(n?.version, 2);
    expect(n?.capabilities, {'b'});
  });

  test('disjoint ranges fail with both ranges', () async {
    final (desktop, host) = connectedPair(
      versionsA: const VersionRange(1, 2),
      versionsB: const VersionRange(3, 4),
    );

    final error = await _failure(desktop.hello());

    expect(error, isNotNull);
    expect(error!.reason, ErrorCode.incompatibleVersion);
    expect(error.message, allOf(contains('1..2'), contains('3..4')));
    expect(error.data['requester'], {'min': 1, 'max': 2});
    expect(error.data['responder'], {'min': 3, 'max': 4});
    expect(host.negotiated, isNull);
  });

  test('request before hello gets protocol error', () async {
    var handled = 0;
    final (desktop, host) = connectedPair(
      capabilitiesA: {Capability.testUnits},
      capabilitiesB: {Capability.testUnits},
      onRequestB: (method, params) {
        handled++;
        return <String, Object?>{};
      },
    );

    final error = await _failure(
      desktop.request(Method.testUnitEnd, {'containmentId': 'x'}),
    );

    expect(error?.reason, ErrorCode.protocolError);
    expect(handled, 0);

    // The session is still usable: hello then works.
    await desktop.hello();
    await desktop.request(Method.testUnitEnd, {'containmentId': 'x'});
    expect(handled, 1);
    expect(host.negotiated, isNotNull);
  });

  test('a second hello is a violation', () async {
    final (desktop, host) = connectedPair();
    await desktop.hello();
    desktop.request(Method.hello, const <String, Object?>{}).ignore();
    final reason = await host.closed;
    expect(reason.kind, CloseReason.protocolViolation);
  });

  test(
    'a method whose capability was not negotiated is not available',
    () async {
      var handled = 0;
      final (desktop, _) = connectedPair(
        capabilitiesA: {Capability.testUnits},
        onRequestB: (method, params) {
          handled++;
          return null;
        },
      );
      await desktop.hello();

      final error = await _failure(
        desktop.request(Method.testUnitLaunch, {
          'target': 't',
          'fixture': 'tree',
        }),
      );

      expect(error?.reason, ErrorCode.methodNotAvailable);
      expect(handled, 0);
    },
  );

  test('a hello result outside the requested range is refused', () async {
    final (error, connection) = await _scriptedHello(
      version: 3,
      capabilities: {Capability.testUnits},
    );
    expect(error, isA<RpcException>());
    expect((error! as RpcException).reason, ErrorCode.protocolError);
    expect((await connection.closed).kind, CloseReason.protocolViolation);
    expect(connection.negotiated, isNull);
  });

  test('a hello result with an unrequested capability is refused', () async {
    final (error, connection) = await _scriptedHello(
      version: 2,
      capabilities: {Capability.testUnits, Capability.testFaults},
    );
    expect(error, isA<RpcException>());
    expect((error! as RpcException).reason, ErrorCode.protocolError);
    expect((await connection.closed).kind, CloseReason.protocolViolation);
    expect(connection.negotiated, isNull);
  });

  test('a hello result within what was requested is accepted', () async {
    final (error, connection) = await _scriptedHello(
      version: 1,
      capabilities: {Capability.testUnits},
    );
    expect(error, isNull);
    expect(connection.negotiated?.version, 1);
    expect(connection.isClosed, isFalse);
    await connection.close();
  });

  test('a hello result outside the requested range is refused', () async {
    final (error, connection) = await _scriptedHello(
      version: 3,
      capabilities: {Capability.testUnits},
    );
    expect(error, isA<RpcException>());
    expect((error! as RpcException).reason, ErrorCode.protocolError);
    expect((await connection.closed).kind, CloseReason.protocolViolation);
    expect(connection.negotiated, isNull);
  });

  test('a hello result with an unrequested capability is refused', () async {
    final (error, connection) = await _scriptedHello(
      version: 2,
      capabilities: {Capability.testUnits, Capability.testFaults},
    );
    expect(error, isA<RpcException>());
    expect((error! as RpcException).reason, ErrorCode.protocolError);
    expect((await connection.closed).kind, CloseReason.protocolViolation);
    expect(connection.negotiated, isNull);
  });

  test('a hello result within what was requested is accepted', () async {
    final (error, connection) = await _scriptedHello(
      version: 1,
      capabilities: {Capability.testUnits},
    );
    expect(error, isNull);
    expect(connection.negotiated?.version, 1);
    expect(connection.isClosed, isFalse);
    await connection.close();
  });

  test('messages round-trip through json', () {
    final params = HelloParams(
      versions: const VersionRange(1, 2),
      capabilities: {'x'},
      priorHost: const PriorHost('old', jobTerminated: true),
    );
    final back = HelloParams.fromJson(params.toJson());
    expect(back.versions.max, 2);
    expect(back.priorHost?.instanceId, 'old');
    expect(back.priorHost?.jobTerminated, isTrue);
    expect(back.desktopPid, isNull, reason: 'optional on the wire');
    expect(back.outerJobHeld, isNull);
    final identified = HelloParams.fromJson(
      HelloParams(
        versions: const VersionRange(1, 1),
        capabilities: const {},
        desktopPid: 42,
        desktopStartTime: 123456789,
        outerJobHeld: true,
      ).toJson(),
    );
    expect(identified.desktopPid, 42);
    expect(identified.desktopStartTime, 123456789);
    expect(identified.outerJobHeld, isTrue);

    final cursor = CleanupCursor('dev:1', 'unit-7');
    final decoded = CleanupCursor.decode(cursor.encode());
    expect(decoded.targetIdentity, 'dev:1');
    expect(decoded.containmentId, 'unit-7');

    expect(
      TestFaultSetParams.fromJson(
        const TestFaultSetParams(TestFault.killFails).toJson(),
      ).fault,
      TestFault.killFails,
    );

    final unit = CleanupUnit(
      containmentId: 'u',
      kind: 'k',
      reason: 'é' * 300,
    ).toJson();
    expect(utf8.encode(unit['reason']! as String).length, maxReasonBytes);
  });
}

/// A desktop connection (versions 1..2, capability test.units) whose host
/// is scripted: it answers `hello` with [version] and [capabilities]. Returns
/// the error `hello` failed with, if any.
Future<(Object?, Connection)> _scriptedHello({
  required int version,
  required Set<String> capabilities,
}) async {
  final input = StreamController<List<int>>();
  final output = RecordingSink();
  final connection = Connection(
    input: input.stream,
    output: output,
    versions: const VersionRange(1, 2),
    capabilities: {Capability.testUnits},
  );
  final hello = connection.hello().then<Object?>(
    (_) => null,
    onError: (Object e) => e,
  );
  await settle();
  final request = jsonDecode(utf8.decode(output.frames.first.payload)) as Map;
  final result = HelloResult(
    version: version,
    capabilities: capabilities,
    instanceId: 'host-1',
    hostVersion: '0.1.0',
    state: HostState.ready,
  );
  final reply = utf8.encode(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': result.toJson(),
    }),
  );
  input.add([for (final f in encodeMessageFrames(controlChannel, reply)) ...f]);
  final error = await hello;
  addTearDown(input.close);
  return (error, connection);
}
