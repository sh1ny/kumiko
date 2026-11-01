import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

void main() {
  test('process output splits large SDK reads without reading ahead', () async {
    final bytes = Uint8List.fromList(
      List.generate(2 * unitPipeChunkSize + 17, (i) => i % 251),
    );
    var reads = 0;
    Stream<List<int>> output() async* {
      reads++;
      yield bytes;
      reads++;
      yield [253, 254, 255];
    }

    final input = _BlockedClose()..release.complete();
    final process = _ControlledProcess(IOSink(input), stdout: output());
    final pipes = UnitPipes.process(process);
    final chunks = StreamIterator(pipes.stdout);
    addTearDown(() async {
      await chunks.cancel();
      process.exited.complete(0);
      await pipes.close();
    });
    final received = BytesBuilder(copy: false);
    for (final size in [unitPipeChunkSize, unitPipeChunkSize, 17]) {
      expect(await chunks.moveNext(), isTrue);
      expect(chunks.current.length, size);
      expect(reads, 1);
      received.add(chunks.current);
    }
    expect(await chunks.moveNext(), isTrue);
    expect(chunks.current, [253, 254, 255]);
    received.add(chunks.current);
    expect(await chunks.moveNext(), isFalse);
    expect(reads, 2);
    expect(received.takeBytes(), [...bytes, 253, 254, 255]);
  });

  test('process exit settles queued stdin writes when native flush never completes', () async {
    final input = _BlockedInput();
    final process = _ControlledProcess(IOSink(input));
    final pipes = UnitPipes.process(process);
    addTearDown(() async {
      // The real Process implementation destroys its stdin socket at exit.
      // Release our controlled consumer only during cleanup: completion of
      // its flush must not be needed to settle caller writes or disposal.
      input.release.complete();
      await input.finished.future;
      await pipes.close();
    });
    final queued = <Future<Object?>>[];
    for (var i = 0; i < 16; i++) {
      queued.add(
        pipes.stdin
            .write(Uint8List(unitPipeChunkSize))
            .then<Object?>((_) => null, onError: (Object error) => error),
      );
    }
    await input.started.future;
    await expectLater(pipes.stdin.write([1]), throwsA(isA<StateError>()));

    process.exited.complete(0);

    final outcomes = await Future.wait(queued)
        .timeout(const Duration(seconds: 1));
    expect(outcomes, everyElement(isA<StateError>()));
    await expectLater(pipes.stdin.write([1]), throwsA(isA<StateError>()));
    await pipes.close().timeout(const Duration(seconds: 1));
    expect(input.chunks, 1);
  });

  test('process exit releases an already pending stdin close', () async {
    final input = _BlockedClose();
    final process = _ControlledProcess(IOSink(input));
    final pipes = UnitPipes.process(process);
    addTearDown(() async {
      input.release.complete();
      await pipes.close();
    });
    final closing = pipes.stdin.close();
    await input.started.future;

    process.exited.complete(0);

    await closing.timeout(const Duration(seconds: 1));
    await pipes.close().timeout(const Duration(seconds: 1));
  });
}

/// Models the SDK's destroyed process socket: its outstanding operation can
/// stay pending even though exitCode has already completed.
class _ControlledProcess implements Process {
  _ControlledProcess(this.stdin, {this.stdout = const Stream.empty()});

  final exited = Completer<int>();

  @override
  final IOSink stdin;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr = const Stream.empty();
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => throw UnsupportedError('no native process in this test');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw UnsupportedError('complete exited to end this test process');
}

class _BlockedClose implements StreamConsumer<List<int>> {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() {
    started.complete();
    return release.future;
  }
}

class _BlockedInput implements StreamConsumer<List<int>> {
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  var chunks = 0;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    try {
      await for (final _ in stream) {
        chunks++;
        if (!started.isCompleted) started.complete();
        await release.future;
      }
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }

  @override
  Future<void> close() async {}
}
