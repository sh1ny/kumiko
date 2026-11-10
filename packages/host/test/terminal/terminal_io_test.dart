import 'dart:typed_data';

import 'package:host/src/terminal/terminal_io.dart';
import 'package:test/test.dart';

void main() {
  test(
    'writer retains the actual chunk until a failed native write replies',
    () async {
      final retained = <int>[];
      final writer = await PtyWriterIsolate.start(
        -1,
        onRetainedBytesChanged: retained.add,
      );
      try {
        final write = writer.write(Uint8List(317));
        write.ignore();
        expect(retained, [
          317,
        ], reason: 'includes isolate transfer and native write');
        await expectLater(write, throwsA(isA<PtyWriteFailed>()));
        expect(retained, [317, 0]);
      } finally {
        writer.stop();
        await writer.exited;
      }
    },
  );
}
