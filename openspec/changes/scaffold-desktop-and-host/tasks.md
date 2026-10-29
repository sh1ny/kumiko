# Tasks

## Test map

Paths are relative to the repository root.
- `host/it/` = `packages/host/test/integration/`. These tests run the real host executable, built from the test entry point (`dart build cli -t tool/kumiko_host_test.dart`, design D10) unless the row says *release*.
- `proto/` = `packages/host_protocol/test/`.
- `pc/` = `packages/process_containment/test/`.
- `desk/` = `packages/desktop/test/`, widget tests over a scripted connection.
- `desk-it/` = `packages/desktop/integration_test/`, the real Flutter app with the real bundled host.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| execution-host → Desktop launches its bundled host | Normal launch | `desk-it/launch_test.dart` | `normal launch connects one child host` | red |
| execution-host → Desktop launches its bundled host | Bundled host missing or not executable | `desk/host_status_test.dart` | `missing host shows start error with path` | red |
| execution-host → Desktop launches its bundled host | Host does not answer the handshake | `proto/client/launcher_test.dart` | `hello timeout kills host and reports timeout` | red |
| execution-host → One host owns a user profile | Two simultaneous launches | `host/it/lock_test.dart` | `two simultaneous launches yield one host` | red |
| execution-host → One host owns a user profile | Lock released by a crashed owner | `host/it/lock_test.dart` | `killed owner releases lock to next launch` | red |
| execution-host → A second launch reports the running instance and exits | Launch while Kumiko runs | `desk/host_status_test.dart` + `host/it/lock_test.dart` | `profile-locked shows already running and exits on dismiss` / `locked host replies profile-locked and exits` | red |
| execution-host → A second launch reports the running instance and exits | Second launch leaves the profile untouched | `host/it/lock_test.dart` | `refused launch leaves profile byte-identical (lock-holder fixture)` | red |
| execution-host → Host lifetime is tied to the desktop | Desktop quits normally | `host/it/lifecycle_test.dart` | `stdin close ends units, cleans ledger, exits` | red |
| execution-host → Host lifetime is tied to the desktop | Desktop is killed | `host/it/lifecycle_test.dart` | `killed desktop stand-in leaves no host or marked process` | red |
| execution-host → Host lifetime is tied to the desktop | A unit survives past the shutdown deadline | `host/it/lifecycle_test.dart` | `kill failure past deadline keeps row; next host reconciles conditionally` | red |
| execution-host → Losing the host is visible | Host killed while the desktop runs | `proto/client/launcher_test.dart` + `desk/host_status_test.dart` | `host kill detected within 2 s` / `host lost shows restart and no running unit` | red |
| execution-host → Losing the host is visible | Restart after host loss | `host/it/reconcile_test.dart` | `restarted host refuses launches until reconciled` | red |
| host-process-cleanup → Every launch is recorded before it starts | Unit launch records the ledger | `host/it/ledger_test.dart` | `pending row committed before spawn, pid and start time after` | red |
| host-process-cleanup → Every launch is recorded before it starts | Pending write fails | `host/it/ledger_test.dart` | `pending write fault refuses launch with store-error` | red |
| host-process-cleanup → Units are contained and marked | Descendants stay attributable | `pc/spawn_test.dart` | `tree fixture descendants carry marker and job` | red |
| host-process-cleanup → Units are contained and marked | Breakaway refused on Windows | `pc/spawn_windows_test.dart` | `breakaway child stays in unit job` | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | Unit with an escaped descendant is ended | `host/it/ledger_test.dart` | `escaper descendant killed via marker scan, unit cleaned` | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits during the marker scan | `pc/marker_scan_test.dart` | `process gone or pid reused between list and read counts as gone` | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A live process cannot be inspected | `pc/marker_scan_test.dart` | `live unreadable process yields scan-unreadable` | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A marked process survives | `host/it/ledger_test.dart` | `kill failure marks unit and workspace unresolved` | red |
| host-process-cleanup → The next lock holder reconciles before launching | Host killed with units running | `host/it/reconcile_test.dart` | `killed host's units cleaned or unresolved; no launch before reconcile` | red |
| host-process-cleanup → The next lock holder reconciles before launching | Reused pid is not killed | `host/it/reconcile_test.dart` | `pid with different start time is never signalled` | red |
| host-process-cleanup → The next lock holder reconciles before launching | Host killed between the pending write and the pid write | `host/it/reconcile_test.dart` | `crash windows leave unresolved unless Windows job confirmed` | red |
| host-process-cleanup → Cleanup unresolved refuses execution against the workspace | Launch against an unresolved workspace | `host/it/gate_test.dart` | `launch against unresolved workspace refused` | red |
| host-process-cleanup → Cleanup unresolved refuses execution against the workspace | Launch against another workspace | `host/it/gate_test.dart` | `other workspace launches normally` | red |
| host-process-cleanup → Cleanup unresolved refuses execution against the workspace | Another path to the same checkout | `host/it/gate_test.dart` + `pc/fs_identity_test.dart` | `symlink, junction and case alias are gated` / `alias paths share identity` | red |
| host-process-cleanup → Cleanup unresolved refuses execution against the workspace | Distinct directories differing only in case | `host/it/gate_test.dart` | `case-distinct directory on case-sensitive volume not gated` (skipped with reason where no case-sensitive volume is available; CI Linux always runs it) | red |
| host-process-cleanup → Cleanup unresolved refuses execution against the workspace | Target cannot be resolved | `host/it/gate_test.dart` | `missing target refused with target-unavailable, no ledger row` | red |
| host-process-cleanup → Unresolved cleanup is shown and can be retried or confirmed | Many unresolved units | `host/it/cleanup_api_test.dart` + `desk/cleanup_list_test.dart` | `pages over 1 MiB of unresolved results; actions cover all units` / `list pages and shows counts` | red |
| host-process-cleanup → Unresolved cleanup is shown and can be retried or confirmed | Retry succeeds | `host/it/cleanup_api_test.dart` | `retry after exit cleans and unblocks workspace` | red |
| host-process-cleanup → Unresolved cleanup is shown and can be retried or confirmed | Retry still fails | `host/it/cleanup_api_test.dart` | `retry with survivor keeps workspace with updated reason` | red |
| host-process-cleanup → Unresolved cleanup is shown and can be retried or confirmed | User confirms the processes are gone | `host/it/cleanup_api_test.dart` | `confirm deletes rows, logs unit ids, unblocks` | red |
| host-process-cleanup → Unresolved cleanup is shown and can be retried or confirmed | Confirmation races a new failure | `host/it/cleanup_api_test.dart` | `confirm during retry refused with retry-in-progress` | red |
| desktop-host-protocol → Sessions start with a versioned hello | Compatible versions | `proto/hello_test.dart` | `highest common version and capability intersection` | green |
| desktop-host-protocol → Sessions start with a versioned hello | No common version | `proto/hello_test.dart` + `desk/host_status_test.dart` | `disjoint ranges fail with both ranges` / `incompatible shows both ranges` | red |
| desktop-host-protocol → Sessions start with a versioned hello | Request before hello | `proto/hello_test.dart` | `request before hello gets protocol error` | green |
| desktop-host-protocol → Capabilities gate methods | Release host and a test method | `host/it/release_contract_test.dart` (*release*) | `release host advertises no test caps; every test method and fixture refused` | red |
| desktop-host-protocol → Capabilities gate methods | Test host advertises test capabilities | `host/it/handshake_test.dart` | `test host negotiates test caps` | red |
| desktop-host-protocol → Frames are bounded and channel-tagged | Large output is split | `proto/frame_codec_test.dart` | `payload over 64 KiB split and reassembled in order` | green |
| desktop-host-protocol → Frames are bounded and channel-tagged | Oversized frame received | `proto/frame_codec_test.dart` + `host/it/handshake_test.dart` | `oversize length is a violation` / `oversize frame closes connection with protocol-violation` | red |
| desktop-host-protocol → Control frames are never queued behind bulk data | Control round-trip under a saturating channel | `host/it/protocol_qualification_test.dart` | `control round-trip ≤ 250 ms under saturating channel` | red |
| desktop-host-protocol → Control frames are never queued behind bulk data | Control enqueued while bulk output is being written | `proto/writer_test.dart` | `at most one data frame precedes control enqueued mid-write` | green |
| desktop-host-protocol → Control frames are never queued behind bulk data | Two busy data channels | `proto/writer_test.dart` | `round-robin between busy channels` | green |
| desktop-host-protocol → Data channels use per-channel credit | One consumer stalls | `host/it/protocol_qualification_test.dart` | `stalled channel stops at credit; other channel and control flow` | red |
| desktop-host-protocol → Data channels use per-channel credit | Stalled consumer resumes | `host/it/protocol_qualification_test.dart` | `resumed channel delivers every byte once in order` | red |
| desktop-host-protocol → Data channels use per-channel credit | Sender exceeds credit | `proto/credit_test.dart` | `credit overrun is a protocol violation` | green |
| desktop-host-protocol → The host bounds memory for a slow desktop | Desktop stops reading a channel | `host/it/protocol_qualification_test.dart` | `host buffered bytes per channel stay ≤ 256 KiB` | red |
| desktop-host-protocol → The host bounds memory for a slow desktop | Repeated channel opens | `host/it/protocol_qualification_test.dart` | `33rd open refused with channel-cap; total buffering ≤ 8 MiB` | red |
| desktop-host-protocol → The host bounds memory for a slow desktop | Desktop stops reading the pipe entirely | `host/it/lifecycle_test.dart` | `pending control over 4 MiB ends units and exits host` | red |
| local-store → Only the lock holder opens the store | Store opened after the lock | `host/it/store_test.dart` | `lock holder opens store and completes hello` | red |
| local-store → Only the lock holder opens the store | Host without the lock | `host/it/lock_test.dart` | `locked host creates no store or journal files` | red |
| local-store → Migrations are versioned and transactional | Fresh profile | `packages/host/test/store/migrations_test.dart` | `fresh store created at current version` | green |
| local-store → Migrations are versioned and transactional | Migration fails | `packages/host/test/store/migrations_test.dart` + `host/it/store_test.dart` | `failing step rolls back version and contents` / `hello reports store-migration-failed` | red |
| local-store → A store is never reset or downgraded | Store from a newer Kumiko | `host/it/store_test.dart` | `newer store refused unchanged with both versions` | red |
| local-store → A store is never reset or downgraded | Store file cannot be opened | `host/it/store_test.dart` | `garbage store file left in place, store-unreadable with path` | red |
| product-telemetry → Shipped dependencies exclude telemetry and reporting packages | Clean dependency set | `tool/test/audit_dependencies_test.dart` | `clean graph passes and lists packages` | green |
| product-telemetry → Shipped dependencies exclude telemetry and reporting packages | A reporting package is added | `tool/test/audit_dependencies_test.dart` | `denylisted transitive package fails with path` | green |
| product-telemetry → Shipped dependencies exclude telemetry and reporting packages | Audit cannot read the resolved dependencies | `tool/test/audit_dependencies_test.dart` | `missing lock or failing pub deps fails audit` | green |

## 1. SQLite probe and ADR 0008

- [x] 1.1 Build a throwaway probe under `tool/probes/sqlite/` (not a workspace member) that opens a WAL database with `synchronous=FULL`, commits a row, and is killed mid-write by a driver script. Run it with `package:sqlite3` bundled (default hooks) and with `source: system`. Try both `dart compile exe` and `dart build cli`, including whether `-D` defines pass through. Run it locally on Windows and in a temporary CI matrix job on Linux and macOS. Verify: a results table (per OS × mode × build: builds?, bundle layout, WAL ok, row durable after kill, licence) is saved to `tool/probes/sqlite/RESULTS.md`.
- [x] 1.2 Write `docs/adr/0008-sqlite-binding-for-the-local-store.md` (MADR-short, `Status: accepted (<date>)`, Source ADR 0003 item 5, with a rejected alternative and reversal cost) from the probe results. In `openspec/architecture.md`, add its in-force index row, add `process_containment` to the Components table, and copy the numeric bounds from design D6 and Resource Bounds into the Resource bounds table. Verify: the ADR file exists, the index lists 0001-0008, and the architecture holds the numbers 64 KiB, 1 MiB, 256 KiB, 32 channels, 4 MiB, 30 s and 64 units.
- [x] 1.3 If the probe contradicts design D11's expected layout (`host/bin` + `host/lib`), or shows test hooks cannot be compiled in, stop and report it before group 2. Otherwise record "layout confirmed" in `RESULTS.md`. Verify: a `RESULTS.md` line states the decision.

## 2. Workspace scaffold and CI skeleton

- [x] 2.1 Pin the toolchain in `mise.toml` (Dart 3.13.7, Flutter 3.47.x as used locally). Create the root `pubspec.yaml` with `workspace:` and the packages `domain`, `host_protocol`, `process_containment`, `host` (with an executable `kumiko_host`) and `desktop` (Flutter app, Windows/Linux/macOS targets only), each with `resolution: workspace`. Add a shared `analysis_options.yaml` (strict casts, inference and raw types) and a `.gitignore` for build outputs. Verify: `dart pub get` at the root succeeds, and `dart analyze --fatal-infos` and `flutter analyze` report no issues.
- [x] 2.2 Add `.github/workflows/ci.yml`: on push to `main` and on pull requests, a matrix over `windows-latest`, `ubuntu-latest` and `macos-latest` with the pinned Flutter, Linux desktop build dependencies, `dart pub get`, analyze and test steps. Verify: `actionlint` (or a YAML parse when it is unavailable) passes locally. The first CI run is checked in group 9.

## 3. Dependency audit (product-telemetry)

- [x] 3.1 Write `tool/test/audit_dependencies_test.dart` covering the three product-telemetry scenarios: a clean graph, a denylisted transitive package with its path, a missing lock, and a failing `pub deps`. Use fixture `pub deps --json` outputs and an injectable runner. Also test the D1 dependency rules: `desktop` must not depend on `host`, `domain` must not import `dart:io` or `dart:ffi`, and nothing reachable from `packages/host/bin/kumiko_host.dart` may import `lib/src/test_hooks/` (D10). Verify: the tests fail because the tool is missing.
- [x] 3.2 Implement `tool/audit_dependencies.dart` (denylist, patterns and allowlist file from design D13; exit non-zero with the package and its path) and `tool/audit_allowlist.yaml` (empty, with a header explaining the reason format). Add the audit to CI on every OS. Verify: the 3.1 tests pass and their rows are green; `dart run tool/audit_dependencies.dart` passes on the real workspace.

## 4. Protocol library (`host_protocol`)

- [x] 4.1 Write failing tests in `proto/frame_codec_test.dart`, `proto/hello_test.dart`, `proto/credit_test.dart` and `proto/writer_test.dart` for their test-map rows. The writer test uses a recording sink that blocks flushes on demand. Verify: the tests fail for missing code.
- [x] 4.2 Implement the frame codec (10-byte header, kinds DATA and CREDIT, end-of-message flag, 64 KiB payload, 1 MiB control message, violations) and the JSON-RPC message types for `hello`, errors, `cleanup/*`, `channel/close` and `test/*`. All message types are hand-written Dart classes with `toJson`/`fromJson` in one place, used by both sides. Verify: `frame_codec_test` and `hello_test` pass; flip their rows green.
- [x] 4.3 Implement the connection: the fair writer (control first, round-robin data, one frame per flush), the never-pausing reader with per-channel queues bounded by credit, credit grant at half consumption, the 32-channel cap, the 4 MiB pending-control bound, 256 in-flight inbound requests, and capability gating. Verify: `credit_test` and `writer_test` pass; flip their rows green.
- [ ] 4.4 Implement the client launcher in `host_protocol` as a pure Dart library (no Flutter), so tests and the desktop share it. It starts the host with `--profile <dir>`, holds the Windows outer job through `process_containment` (group 5), assigns the host before `hello`, runs `hello` with a 30 s timeout, detects host loss within 2 s, drains stderr into a 64 KiB ring, attests a terminated prior job, and waits 35 s on quit. Write `proto/client/launcher_test.dart` against a stub host script first. Verify: the launcher test rows (timeout, host-kill detection) pass; flip them green.

## 5. Process containment (`process_containment`)

- [ ] 5.1 Spike the POSIX `--unit-exec` shim: a Dart executable that resets the signal mask, closes fds above 2, calls `setsid()` and then `execve()` through FFI. Run it on Linux (locally in WSL or CI) and on macOS (CI), and check that the pid survives, the session id equals the pid, and the exit code reaches `Process.exitCode`. Verify: a small test `pc/unit_exec_test.dart` passes on Linux and macOS CI. If it fails, stop and re-plan with the user (design Risks).
- [ ] 5.2 Write failing tests `pc/spawn_test.dart`, `pc/spawn_windows_test.dart`, `pc/marker_scan_test.dart` and `pc/fs_identity_test.dart` for their rows. The marker scan takes an injectable process-table reader, so the gone, reused and unreadable cases are deterministic, plus one real-OS smoke case. Verify: they fail for missing code.
- [ ] 5.3 Implement the POSIX primitives: spawn via the shim with the `KUMIKO_UNIT` marker, start time (Linux `/proc/<pid>/stat`, macOS `proc_pidinfo`), `killpg` guarded by leader pid and start time, the TERM → 2 s → KILL sequence, and the marker scan with the D9 population and re-check rules (Linux `/proc`, macOS `KERN_PROCARGS2`) and a 10 s pass timeout. Verify: the POSIX rows of `spawn_test` and `marker_scan_test` pass on Linux and macOS CI; flip them green.
- [ ] 5.4 Implement the Windows primitives: create, assign and terminate jobs (`KILL_ON_JOB_CLOSE`, no breakaway), `CreateProcessW` suspended with assignment to a nested unit job before resume, `NUL` stdio, exit wait in a helper isolate, `GetProcessTimes` start time, active-process query, and `IsProcessInJob`. Verify: `spawn_test` (Windows) and `spawn_windows_test` pass locally on Windows; flip them green.
- [ ] 5.5 Implement file identity: `realpath` plus `stat` `st_dev:st_ino` on POSIX, and `GetFinalPathNameByHandleW` plus `FileIdInfo` on Windows, returning `target-unavailable` for missing or unopenable directories. Verify: `fs_identity_test` (symlink on all OSes, junction on Windows, case alias on case-insensitive volumes) passes; flip its row green.

## 6. Store core (`host`)

- [x] 6.1 Write failing `packages/host/test/store/migrations_test.dart`: a fresh store at v1; a failing injected step that leaves `user_version` and contents unchanged; a newer `user_version` refused unchanged; a garbage file left in place. Verify: they fail for missing code.
- [x] 6.2 Implement the store with the ADR 0008 binding: WAL, `synchronous=FULL`, a migration list with one transaction per step, schema v1 (`host_instance`, `unit` per design D4), and typed errors `store-migration-failed`, `store-newer`, `store-unreadable`. It is opened only through a function that requires a held profile lock object. Verify: `migrations_test` passes; flip its rows green.

## 7. Host executable (`host`)

- [ ] 7.1 Write failing integration tests `host/it/lock_test.dart`, `handshake_test.dart`, `store_test.dart`, `ledger_test.dart`, `reconcile_test.dart`, `gate_test.dart`, `cleanup_api_test.dart` and `lifecycle_test.dart` for their test-map rows. Add a test helper that builds the test host once per run and a Dart desktop stand-in that uses the 4.4 launcher. Use the test fixtures (`tree`, `escaper`, `sleeper`, `stubborn`, `lock-holder`) and `test/fault.set`. Verify: they fail for missing code.
- [ ] 7.2 Implement startup: the non-blocking lock on `<profile>/kumiko.lock` (opened once), `profile-locked` and `profile-unavailable` replies, opening the store only after the lock, the `host_instance` row, the `hello` server with version and capability negotiation, and the host log (2 × 4 MiB rotation, minimal fields, written only after the lock). Verify: `lock_test`, `handshake_test` (non-load rows) and `store_test` pass; flip their rows green.
- [ ] 7.3 Implement the unit lifecycle: the 64-unit cap, identity resolution before the ledger, the gate (identity or exact resolved path), the pending row before spawn and pid and start time after, ending a unit (containment kill, shared marker scan, delete row on cleaned, unresolved with reason otherwise), and the test-only `test/unit.*` methods and fixtures in `lib/src/test_hooks/`, registered only by the test entry point (D10). Verify: `ledger_test` and `gate_test` pass; flip their rows green.
- [ ] 7.4 Implement reconciliation after `hello` (D5): refuse with `reconciling` meanwhile; terminate units of earlier instances guarded by pid and start time; the marker scan; the Windows D8 rules (attestation, or recorded desktop gone); the constant-size `cleanup/state`; paged `cleanup/list` and `cleanup/units` with revision and stale flags; `cleanup/retry` and `cleanup/confirm` serialized per workspace, with confirm logging unit ids; cleanup of unreferenced `host_instance` rows. Verify: `reconcile_test` and `cleanup_api_test` pass; flip their rows green.
- [ ] 7.5 Implement lifetime: stdin EOF or pending control over 4 MiB starts shutdown with the 30 s deadline (parallel termination, shared scans, `shutdown-deadline` reasons, rows kept), then exit; refuse launches unless the Windows outer job is held. Verify: `lifecycle_test` passes on the local OS and in CI on all three; flip its rows green.

## 8. Desktop app (`desktop`)

- [ ] 8.1 Write failing widget tests `desk/host_status_test.dart` and `desk/cleanup_list_test.dart` over a scripted connection: the states starting, connected (version shown), startError (path or timeout, Restart host), incompatible (both ranges), alreadyRunning (message, exit on dismiss), storeError (path and versions), and hostLost (Restart host, nothing shown running); the paged cleanup list with counts and Retry and Confirm actions, including the *cleaned* wording from the spec. Verify: they fail for missing code.
- [ ] 8.2 Implement the status window and cleanup list on the 4.4 launcher. Resolve the bundled host at `<app>/host/bin/kumiko_host[.exe]`, with a compile-time `--dart-define=KUMIKO_HOST=<path>` for development only, and the per-OS default profile directory (`%LOCALAPPDATA%\Kumiko`, `${XDG_DATA_HOME:-~/.local/share}/kumiko`, `~/Library/Application Support/Kumiko`). The second desktop writes nothing to the profile. Verify: the 8.1 tests pass; flip their rows green.
- [ ] 8.3 Write `desk-it/launch_test.dart` (normal launch connects one child host, shows the version) against the bundled host. Verify: it passes locally on Windows with `flutter test integration_test -d windows`; flip its row green.

## 9. Packaging, release contract and CI

- [ ] 9.1 Add `tool/bundle_host.dart`, which builds the release host per ADR 0008's command and copies it into `host/` inside the Flutter release bundle (Windows `build/windows/x64/runner/Release/`, Linux `build/linux/x64/release/bundle/`, macOS `Kumiko.app/Contents/MacOS/`). Verify: after `flutter build windows --release` and the tool, `host/bin/kumiko_host.exe` exists in the bundle and the app launches connected.
- [ ] 9.2 Write and pass `host/it/release_contract_test.dart` against the release host, per design D10: with test capabilities requested, `hello` advertises no `test.*` capability and `test/unit.launch`, `test/unit.end`, `test/channel.open` and `test/fault.set` are method-not-available; every `--test-fixture` variant exits promptly with a usage error, no descendant and a byte-identical profile; on Linux and macOS `--unit-exec` runs a benign helper with pid preserved, session id = pid, exit code propagated and `KUMIKO_UNIT` set. Verify: it passes locally (POSIX cases in CI); flip its row green.
- [ ] 9.3 Write and pass `host/it/protocol_qualification_test.dart`: a saturating channel with a control round-trip under 250 ms (worst of 100, logged), a stalled and a flowing channel, resume with an exact byte check, per-channel host buffering ≤ 256 KiB, and the channel cap with ≤ 8 MiB total. Verify: it passes locally; flip its rows green.
- [ ] 9.4 Complete CI on all three OSes: test host build, all package tests and integration tests, the audit, the release host build, the release contract test, the desktop release build with the host bundled, and artifact upload; remove the temporary probe job. Verify: the workflow passes on a pushed branch or PR (ask the user to push; local `finish: local` merges do not run CI). Record the run URL in the PR or merge notes.

## 10. Integration check

- [ ] 10.1 Run the ADR 0001 M1 qualification list on Windows locally and on Linux and macOS in CI (lock, killed desktop, killed host with all fixtures, crash windows, gate refusal, reconciliation after a killed owner). Record measured values in `openspec/architecture.md` Resource bounds: control latency worst case, unit termination and shutdown durations. Verify: every test-map row is green, and `openspec validate scaffold-desktop-and-host --strict` passes.

## Workflow follow-up

- After apply, the pre-ship review runs before the local merge (`review.preship: true`).
- M1 exit criteria advanced here are checked at milestone close: CI from main needs a push to GitHub.
