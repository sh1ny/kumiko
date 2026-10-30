// Writes a file to stdout in 1 MiB blocks, the way `cat` does: the Windows
// throughput bar item's program, run by the Dart VM. `cmd`'s `type` writes in
// small pieces and would measure `cmd` rather than the terminal. Uses SDK
// libraries only, so it needs no package resolution.
//
//   dart block_cat.dart <file> [loop]
//
// With `loop` it starts the file again at its end, until it is killed.
import 'dart:io';

Future<void> main(List<String> args) async {
  final file = File(args.first).openSync();
  final block = List<int>.filled(1 << 20, 0);
  try {
    while (true) {
      final n = file.readIntoSync(block);
      if (n == 0) {
        if (args.length < 2) break;
        file.setPositionSync(0);
        continue;
      }
      stdout.add(n == block.length ? block : block.sublist(0, n));
      await stdout.flush();
    }
  } finally {
    file.closeSync();
  }
}
