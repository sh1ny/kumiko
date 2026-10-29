// A stand-in host for the launcher tests: `dart stub_host.dart --mode <mode>
// --profile <dir>`. It speaks the real protocol through [Connection].
//
//   serve       answers hello (instanceId stub-1, hostVersion = its argv),
//               exits when stdin ends
//   silent      reads stdin, never answers hello
//   locked      answers hello with profile-locked
//   no-exit     like serve, but ignores stdin EOF
//   flood       writes 10000 numbered stderr lines, then serves
//   echo-prior  like serve, hostVersion = the priorHost it was sent as JSON
//   echo-desktop like serve, hostVersion = the desktop identity it was sent
//   locked-data answers hello with an error carrying structured data
//   notify      like serve, then sends a cleanup/state notification
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';

Future<void> main(List<String> args) async {
  final mode = args[args.indexOf('--mode') + 1];

  if (mode == 'silent') {
    stderr.writeln('stub: silent');
    await stderr.flush();
    stdin.listen((_) {});
    await Completer<void>().future;
  }

  if (mode == 'flood') {
    for (var i = 0; i < 10000; i++) {
      final end = i == 9999 ? ' END' : '';
      stderr.write('line-${i.toString().padLeft(5, '0')}$end\n');
    }
    await stderr.flush();
  }

  late final Connection connection;
  connection = Connection(
    input: stdin,
    output: IOSinkAdapter(stdout),
    onHello: (params, negotiated) {
      if (mode == 'locked') {
        throw RpcException(ErrorCode.profileLocked, 'locked');
      }
      if (mode == 'locked-data') {
        throw RpcException(ErrorCode.storeNewer, 'newer', {
          'path': '/p/kumiko.db',
          'storeVersion': 3,
          'supportedVersion': 1,
        });
      }
      if (mode == 'notify') {
        Timer(const Duration(milliseconds: 50), () {
          connection.notify(
            Method.cleanupState,
            const CleanupState(
              reconciling: false,
              revision: 7,
              unresolvedWorkspaces: 2,
              unresolvedUnits: 5,
            ).toJson(),
          );
        });
      }
      return HelloInfo(
        instanceId: 'stub-1',
        hostVersion: mode == 'echo-prior'
            ? jsonEncode(params.priorHost?.toJson())
            : mode == 'echo-desktop'
            ? jsonEncode([
                params.desktopPid,
                params.desktopStartTime,
                params.outerJobHeld,
              ])
            : jsonEncode(args),
      );
    },
  );

  if (mode == 'no-exit') {
    // A live timer keeps the VM running after stdin ends.
    Timer.periodic(const Duration(seconds: 1), (_) {});
    await Completer<void>().future;
  }
  await connection.closed;
  exit(0);
}
