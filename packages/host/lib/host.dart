/// The Kumiko execution host (design D10): the entry shared by the release
/// and the test executable, and the extension point only a test build uses.
library;

export 'src/host.dart' show HostExit, hostVersion;
export 'src/host_extension.dart';
export 'src/host_faults.dart';
export 'src/host_main.dart';
export 'src/host_options.dart';
export 'src/unit_manager.dart' show UnitManager;
