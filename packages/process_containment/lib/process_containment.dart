/// OS process containment: Windows job objects and process creation, POSIX
/// sessions, process start times, the unit marker scan and file identity
/// (design D1-D3, D9).
library;

export 'src/libc.dart' show sessionIdOf;
export 'src/unit_exec.dart' show runUnitExec, unitMarkerVariable;
