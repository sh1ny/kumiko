import 'package:host_protocol/host_protocol.dart';

import 'host_faults.dart';
import 'host_options.dart';
import 'unit_manager.dart';

/// What a test build adds to the host (design D10). Only the test entry point
/// constructs one; the release entry point passes none, so the release host
/// advertises no test capability, serves no `test/*` method and runs no
/// fixture.
abstract interface class HostExtension {
  /// The test capabilities the host advertises in `hello`.
  Set<String> get capabilities;

  /// Settings that make timing deterministic in tests.
  HostOptions get options;

  /// Runs a `--test-fixture` mode: [args] are the mode and its arguments.
  /// Returns the process exit code.
  Future<int> runFixture(List<String> args);

  /// Serves a `test/*` method.
  Future<Object?> handle(HostServices host, String method, Json params);
}

/// The parts of the host a test method may use.
class HostServices {
  HostServices({
    required this.units,
    required this.faults,
    required this.connection,
  });

  final UnitManager units;
  final HostFaults faults;
  final Connection connection;
}
