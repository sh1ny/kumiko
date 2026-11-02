@TestOn('windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:process_containment/process_containment.dart';
import 'package:process_containment/src/windows_api.dart' as w;
import 'package:test/test.dart';

final _advapi32 = DynamicLibrary.open('advapi32.dll');
final _getSecurityInfo = _advapi32
    .lookupFunction<
      Uint32 Function(
        IntPtr,
        Int32,
        Uint32,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
      ),
      int Function(
        int,
        int,
        int,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
      )
    >('GetSecurityInfo');
final _sdToString = _advapi32
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        Uint32,
        Pointer<Pointer<Utf16>>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Void>,
        int,
        int,
        Pointer<Pointer<Utf16>>,
        Pointer<Uint32>,
      )
    >('ConvertSecurityDescriptorToStringSecurityDescriptorW');
final _localFree = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('LocalFree');

final _stringToSid = _advapi32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Pointer<Void>>),
      int Function(Pointer<Utf16>, Pointer<Pointer<Void>>)
    >('ConvertStringSidToSidW');

/// The `S-1-...` form of an SDDL trustee. String security descriptors write
/// well-known accounts as aliases (`SY`, and `LA` for the built-in
/// Administrator, the CI runner's account), so compare canonical SIDs.
String _canonicalSid(String trustee) {
  final text = trustee.toNativeUtf16();
  final sid = calloc<Pointer<Void>>();
  final out = calloc<Pointer<Utf16>>();
  try {
    if (_stringToSid(text, sid) == 0) {
      throw StateError('ConvertStringSidToSidW failed for $trustee');
    }
    try {
      if (w.convertSidToStringSidW(sid.value, out) == 0) {
        throw StateError('ConvertSidToStringSidW failed for $trustee');
      }
      final result = out.value.toDartString();
      w.localFree(out.value.cast());
      return result;
    } finally {
      w.localFree(sid.value);
    }
  } finally {
    calloc.free(text);
    calloc.free(sid);
    calloc.free(out);
  }
}

const _readControl = 0x00020000;
const _fileShareReadWrite = 3;
const _openExisting = 3;

/// Reads the DACL of the pipe instance [name] back from the kernel as SDDL.
String _readDacl(String name) {
  final path = name.toNativeUtf16();
  final handle = w.createFileW(
    path,
    _readControl,
    _fileShareReadWrite,
    nullptr,
    _openExisting,
    0,
    0,
  );
  calloc.free(path);
  expect(handle, isNot(-1), reason: 'open for READ_CONTROL');
  final sd = calloc<Pointer<Void>>();
  final out = calloc<Pointer<Utf16>>();
  try {
    // OBJECT_SECURITY: SE_KERNEL_OBJECT (6), DACL_SECURITY_INFORMATION (4).
    expect(
      _getSecurityInfo(
        handle,
        6,
        4,
        nullptr,
        nullptr,
        nullptr.cast(),
        nullptr,
        sd,
      ),
      0,
    );
    expect(_sdToString(sd.value, 1, 4, out, nullptr), isNot(0));
    return out.value.toDartString();
  } finally {
    if (out.value != nullptr) _localFree(out.value.cast());
    if (sd.value != nullptr) _localFree(sd.value);
    calloc.free(sd);
    calloc.free(out);
    w.closeHandleNative(handle);
  }
}

String _currentUserSid() {
  final result = Process.runSync('whoami', ['/user', '/fo', 'csv', '/nh']);
  final match = RegExp(r'(S-1-[0-9-]+)').firstMatch('${result.stdout}');
  return match!.group(1)!;
}

Future<Uint8List> _collect(Stream<Uint8List> stream, int length) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    out.add(chunk);
    if (out.length >= length) break;
  }
  return out.takeBytes();
}

void main() {
  final servers = <WindowsPipeServer>[];
  final clients = <WindowsPipeConnection>[];

  Future<WindowsPipeServer> start({int maxInstances = 255}) async {
    final server = await WindowsPipeServer.start(maxInstances: maxInstances);
    servers.add(server);
    return server;
  }

  Future<WindowsPipeConnection> connect(String name) async {
    final client = await openWindowsPipe(name);
    clients.add(client);
    return client;
  }

  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    for (final server in servers) {
      await server.close();
    }
    servers.clear();
  });

  test('pipe name is random and in the kumiko-tools namespace', () async {
    final a = await start();
    final b = await start();
    expect(
      a.name,
      matches(RegExp(r'^\\\\\.\\pipe\\kumiko-tools-[0-9a-f]{32}$')),
    );
    expect(a.name, isNot(b.name));
  });

  test('DACL grants only the current user and SYSTEM', () async {
    final server = await start();
    final connections = server.connections.listen((c) => unawaited(c.close()));
    addTearDown(connections.cancel);
    final sddl = _readDacl(server.name);
    expect(sddl, startsWith('D:P'), reason: 'protected, no inherited ACEs');
    final aces = RegExp(r'\(([^)]*)\)').allMatches(sddl).map((m) {
      final parts = m.group(1)!.split(';');
      return (type: parts[0], rights: parts[2], trustee: parts[5]);
    }).toList();
    expect(aces, hasLength(2), reason: sddl);
    expect(aces.every((a) => a.type == 'A'), isTrue, reason: sddl);
    expect(
      aces.every((a) => a.rights == 'FA' || a.rights == '0x1f01ff'),
      isTrue,
      reason: sddl,
    );
    expect(
      aces.map((a) => _canonicalSid(a.trustee)).toSet(),
      {_currentUserSid(), 'S-1-5-18'},
    );
  });

  test('instances reject remote clients', () async {
    final server = await start();
    const rejectRemoteClients = 0x8;
    expect(server.pipeMode & rejectRemoteClients, rejectRemoteClients);
  });

  test('first-instance squatting is refused', () async {
    final server = await start();
    await expectLater(
      WindowsPipeServer.start(name: server.name),
      throwsA(isA<WindowsPipeException>().having((e) => e.code, 'code', 5)),
    );
  });

  test('silent clients are disconnected by the host within 1 s', () async {
    final server = await start();
    final accepted = StreamController<WindowsPipeConnection>();
    server.connections.listen(accepted.add);
    final queue = StreamIterator(accepted.stream);

    final reading = await connect(server.name);
    expect(await queue.moveNext(), isTrue);
    final readingConn = queue.current;
    readingConn.incoming.listen((_) {}); // a read is pending in the worker
    final idle = await connect(server.name);
    expect(await queue.moveNext(), isTrue);
    final idleConn = queue.current; // never listened: worker idles
    expect(server.activeConnections, 2);

    final watch = Stopwatch()..start();
    await readingConn.close().timeout(const Duration(seconds: 1));
    await idleConn.close().timeout(const Duration(seconds: 1));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(readingConn.isJoined, isTrue);
    expect(idleConn.isJoined, isTrue);
    expect(server.activeConnections, 0, reason: 'slots free after the join');

    // The peers observe the disconnect.
    expect(
      await reading.incoming.isEmpty.timeout(const Duration(seconds: 2)),
      isTrue,
    );
    expect(
      await idle.incoming.isEmpty.timeout(const Duration(seconds: 2)),
      isTrue,
    );
    await queue.cancel();
    await accepted.close();
  });

  test('bytes round trip both ways, concurrently', () async {
    final server = await start();
    final accepted = Completer<WindowsPipeConnection>();
    server.connections.listen((c) {
      if (!accepted.isCompleted) accepted.complete(c);
    });
    final client = await connect(server.name);
    final conn = await accepted.future;

    final up = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    final down = Uint8List.fromList(List.generate(200000, (i) => i % 241));
    final atServer = _collect(conn.incoming, up.length);
    final atClient = _collect(client.incoming, down.length);
    await Future.wait([client.add(up), conn.add(down)]);
    expect(await atServer, up);
    expect(await atClient, down);
  });

  test('client sees EOF when the server side closes after writing', () async {
    final server = await start();
    final accepted = Completer<WindowsPipeConnection>();
    server.connections.listen(accepted.complete);
    final client = await connect(server.name);
    final conn = await accepted.future;
    final incoming = StreamIterator(client.incoming);
    await conn.add(Uint8List.fromList([1, 2, 3, 4]));
    expect(await incoming.moveNext(), isTrue);
    expect(incoming.current, [1, 2, 3, 4]);
    await conn.close();
    expect(
      await incoming.moveNext().timeout(const Duration(seconds: 2)),
      isFalse,
    );
  });

  test('server close joins live connections and refuses new clients', () async {
    final server = await start();
    final accepted = Completer<WindowsPipeConnection>();
    server.connections.listen(accepted.complete);
    final client = await connect(server.name);
    final conn = await accepted.future;
    conn.incoming.listen((_) {});
    await server.close().timeout(const Duration(seconds: 2));
    expect(conn.isJoined, isTrue);
    expect(
      await client.incoming.isEmpty.timeout(const Duration(seconds: 2)),
      isTrue,
    );
    await expectLater(
      openWindowsPipe(server.name),
      throwsA(isA<WindowsPipeException>()),
    );
  });

  group('openWindowsPipe', () {
    test('a missing pipe is a clear error', () async {
      final error = await openWindowsPipe(
        r'\\.\pipe\kumiko-tools-does-not-exist',
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<WindowsPipeException>());
      final e = error! as WindowsPipeException;
      expect(e.code, 2);
      expect(e.toString(), contains('does-not-exist'));
    });

    test(
      'a busy pipe is retried and connects once an instance frees',
      () async {
        final server = await start(maxInstances: 1);
        final accepted = Completer<WindowsPipeConnection>();
        server.connections.listen((c) {
          if (!accepted.isCompleted) {
            accepted.complete(c);
          } else {
            unawaited(c.close());
          }
        });
        final first = await connect(server.name);
        final firstConn = await accepted.future;

        final second = openWindowsPipe(server.name);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await first.close();
        await firstConn.close();
        final client = await second.timeout(const Duration(seconds: 2));
        clients.add(client);
      },
    );

    test('a pipe that stays busy fails after about 2 s', () async {
      final server = await start(maxInstances: 1);
      server.connections.listen((_) {});
      await connect(server.name);
      final watch = Stopwatch()..start();
      final error = await openWindowsPipe(server.name)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<WindowsPipeException>());
      expect((error! as WindowsPipeException).code, 231);
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 1800)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    });
  });
}
