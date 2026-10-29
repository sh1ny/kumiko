# ADR 0008: SQLite binding for the local store

- **Status:** accepted (2026-10-29)
- **Date:** 2026-10-29
- **Source:** ADR 0003 item 5 (M1 binding probe); change `scaffold-desktop-and-host` design D10, D11; probe results `tool/probes/sqlite/RESULTS.md`; user decision 2026-10-29 (test entry point)

## Context

ADR 0003 left the Dart SQLite binding to an M1 probe. ADR 0003 item 5 assumed a `dart compile exe` host. The probe (task 1.1) built a WAL writer with `package:sqlite3` 3.8.0 on Windows locally and on Linux and macOS in CI. It used two modes: the default build hook, which bundles a prebuilt SQLite, and `source: system`. It tried both build commands, killed the writer mid-transaction, and checked durability. Findings:

- `dart compile exe` refuses every package that has build hooks, so no `package:sqlite3` 3.x host can be built with it.
- `dart build cli` builds on all three OSes. It produces `bundle/bin/<exe>`, plus `bundle/lib/<sqlite library>` in bundled mode.
- WAL and `synchronous=FULL` took effect in every mode that ran. Every commit reported before the kill was present afterwards, and `integrity_check` was ok.
- System mode loads a different SQLite on each OS: Windows 3.53.4 (only with `name: winsqlite3`), Linux 3.46.1, macOS 3.51.0. Bundled mode loads 3.54.1 everywhere.
- `dart build cli` does not pass `-D` defines through. A separate entry point (`-t`) builds and runs.

## Decision

1. The store uses **`package:sqlite3`** in its default **bundled** mode, with no `hooks.user_defines` override. Its SQLite is in the public domain and the package is MIT-licensed.
2. The host is built with **`dart build cli`** from `packages/host`:
   - release: `dart build cli -o build/host` (entry `bin/kumiko_host.dart`);
   - test: `dart build cli -t tool/kumiko_host_test.dart -o build/host-test`.

   The output `bundle/` is copied into the app bundle as `host/`, so the desktop starts `host/bin/kumiko_host[.exe]` and SQLite loads from `host/lib/`.
3. Connections open with `PRAGMA journal_mode=WAL` and `PRAGMA synchronous=FULL`, and the store records its version in `PRAGMA user_version` (ADR 0003 item 3).
4. Test-only host code is selected by the test entry point, never by a `-D` define (change design D10). This replaces ADR 0003 item 5's `dart compile exe` assumption without editing that ADR.

## Rejected alternatives

- **System SQLite (`source: system`).** The version differs per OS and per distribution, so migrations and pragmas would run on three engines. Windows needs a special library name, and a Linux install without `libsqlite3` would fail at start. The only saving is one library of about 1-2 MB per bundle.
- **`dart compile exe` with an older hook-free binding (`package:sqlite3` 2.x or a hand-written FFI loader).** It would keep a single-file host and `-D` defines, but would pin an unmaintained release line or put library loading and shipping on us.

## Consequences

- Every host build, local and CI, goes through `dart build cli`, and packaging copies a directory, not a single file.
- Test and release hosts are separate executables built from two entry points. The release contract test checks the boundary (design D10).
- SQLite upgrades arrive with `package:sqlite3` upgrades. They are reviewed like any dependency bump and pass the dependency audit.

## Reversal cost

Low for the mode: switching to system SQLite is a pubspec user define plus packaging. Medium for the package before more tables exist (ADR 0003), because the store code is written against its API.
