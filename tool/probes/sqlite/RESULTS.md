# SQLite binding probe results (task 1.1)

Probe: `bin/probe.dart` opens a WAL database with `synchronous=FULL`, commits
batches of 50 rows and prints `committed <max id>` after each commit.
`run_probe.dart` builds it per mode and build command, kills it with SIGKILL
(TerminateProcess on Windows) once 500 rows are reported, then reopens the
database and checks journal mode, `PRAGMA integrity_check` and that every
reported row is present.

- Toolchain: Dart 3.13.7, `package:sqlite3` 3.8.0 (see `pubspec.lock`).
- Windows: run locally (Windows 11, x64), 2026-10-29.
- Linux and macOS: temporary CI job `.github/workflows/sqlite-probe.yml`
  (`ubuntu-latest`, `macos-latest`), run
  https://github.com/sh1ny/kumiko/actions/runs/40789696962.
- Modes: `bundled` = default hook (prebuilt SQLite shipped in `bundle/lib/`);
  `system` = `hooks.user_defines.sqlite3.source: system`; on Windows also
  `system` with `name: winsqlite3` (the OS copy).

## Results

| OS | Mode | Build | Builds? | `-D` passes | Bundle layout | WAL + FULL ok | Row durable after kill | Licence |
|---|---|---|---|---|---|---|---|---|
| windows | bundled | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| windows | bundled | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` + `bundle/lib/` (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 500) | SQLite 3.54.1 public domain, prebuilt by the hook; package:sqlite3 MIT |
| windows | system | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| windows | system | build-cli | yes | rejected by `build cli` | `bundle/bin/` only (below) | no (runs: (error code: 126).) | - | - |
| windows | system-winsqlite3 | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| windows | system-winsqlite3 | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` only (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 500) | OS SQLite 3.53.4 (public domain); package:sqlite3 MIT |
| linux | bundled | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| linux | bundled | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` + `bundle/lib/` (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 500) | SQLite 3.54.1 public domain, prebuilt by the hook; package:sqlite3 MIT |
| linux | system | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| linux | system | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` only (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 500) | OS SQLite 3.46.1 (public domain); package:sqlite3 MIT |
| macos | bundled | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| macos | bundled | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` + `bundle/lib/` (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 550) | SQLite 3.54.1 public domain, prebuilt by the hook; package:sqlite3 MIT |
| macos | system | compile-exe | no ('dart compile' does not support build hooks, use 'dart build' instead.) | - | - | - | - | - |
| macos | system | build-cli | yes | rejected by `build cli`; `dart -D build cli` builds but ignores it; separate test entry point (`-t`): builds and runs | `bundle/bin/` only (below) | yes (journal=wal synchronous=2) | yes (reported 500, found 500) | OS SQLite 3.51.0 (public domain); package:sqlite3 MIT |

Bundle layouts (`dart build cli -o <out>`):

```
windows / bundled / build-cli:
  bundle/bin/probe.exe
  bundle/lib/sqlite3.dll
windows / system / build-cli:
  bundle/bin/probe.exe
windows / system-winsqlite3 / build-cli:
  bundle/bin/probe.exe
linux / bundled / build-cli:
  bundle/bin/probe
  bundle/lib/libsqlite3.so
linux / system / build-cli:
  bundle/bin/probe
macos / bundled / build-cli:
  bundle/bin/probe
  bundle/lib/libsqlite3.dylib
macos / system / build-cli:
  bundle/bin/probe
```

## Findings

1. `dart compile exe` refuses every package that uses build hooks, in both
   modes and on all three OSes ("'dart compile' does not support build hooks,
   use 'dart build' instead"). `package:sqlite3` 3.x always has a hook, so
   the host must be built with `dart build cli`.
2. `dart build cli` produces `bundle/bin/<exe>` plus `bundle/lib/<sqlite
   library>` in bundled mode, and `bundle/bin/<exe>` alone in system mode.
3. WAL and `synchronous=FULL` take effect in every mode that runs, and every
   commit reported before the kill was present afterwards, with
   `integrity_check` ok.
4. System mode without a name fails to load on Windows (error 126: there is
   no `sqlite3.dll` on the OS). It works with `name: winsqlite3`, and on Linux
   and macOS. The OS SQLite versions differ per OS (Windows 3.53.4, Linux
   3.46.1, macOS 3.51.0); bundled mode gives one version (3.54.1) everywhere.
5. `-D` defines do not reach a `dart build cli` build: `dart build cli -D...`
   is rejected as an unknown option, and `dart -D... build cli` builds but the
   define is unset in the binary. A separate entry point built with
   `dart build cli -t <file>` builds and runs on all three OSes, so test
   hooks can be compiled in through a test-only entry point instead of a
   define.
