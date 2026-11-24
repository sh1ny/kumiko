# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| host-process-cleanup → Stopping a unit confirms its processes are gone | Unit with an escaped descendant is ended | packages/process_containment/test/spawn_test.dart | termination ends the session; the marker scan ends an escaped descendant | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits during the marker scan | packages/process_containment/test/marker_scan_test.dart | process gone or pid reused between list and read counts as gone | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader exits while it is being stopped | packages/process_containment/test/kill_guard_test.dart | refused killpg: probe ESRCH is leaderGone, with no snapshot read | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader's pid is not confirmed before a direct signal | packages/process_containment/test/kill_guard_test.dart | killpg ESRCH: an unconfirmed leader gets no direct signal | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader has no process group yet | packages/process_containment/test/kill_group_test.dart | a leader that has not made its group yet is still signalled | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A recorded unit's leader has no process group | packages/process_containment/test/kill_guard_test.dart | fallback disallowed: killpg ESRCH with the recorded start time is failed, with no direct signal | red |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A live process cannot be inspected | packages/process_containment/test/marker_scan_test.dart | live unreadable process yields scan-unreadable | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A marked process survives | packages/process_containment/test/marker_scan_test.dart | marked process that survives SIGKILL leaves the unit unresolved | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A refused signal whose leader is not confirmed gone | packages/process_containment/test/kill_guard_test.dart | refused killpg: an inconclusive recheck is failed | red |

## 1. Error codes read from the call that set them

- [x] 1.1 Verify A4: read the `dart:ffi` documentation of `isLeaf` (via ctx7) and confirm that `kill`, `killpg` and `proc_pidinfo` meet its conditions (no callback into Dart, no long wait); record the result in the commit body. CI on Linux and macOS then runs `spawn_test.dart` (tree fixture, session termination) and `marker_scan_test.dart` (real process table) through the leaf calls.
- [x] 1.2 Add `packages/process_containment/test/errno_capture_test.dart` (POSIX only): `posixKill` and `posixKillpg` with signal 0 on pid `0x7fffffff` return `esrch`. Run it with `mise exec -- dart test test/errno_capture_test.dart` in `packages/process_containment`; on Windows it is skipped, so it is confirmed on Linux and macOS CI.
- [x] 1.3 Bind `kill`, `killpg` and `proc_pidinfo` with `isLeaf: true` in `posix_process_table.dart`; call `errno()` first in `posixKill` and `posixKillpg` and once in the `PosixProcessTable` constructor. Write C7 and C9 as the doc comment at the native bindings. Verify with `mise run analyze` and `mise run test:process_containment`.

## 2. The guarded kill decision

- [ ] 2.1 Write `packages/process_containment/test/kill_guard_test.dart` against the internal `kill_guard.dart` (not yet present), scripting snapshot, `killpg` and `kill` answers for every row of the design's Test map (D1, D3, fallback allowed and disallowed), asserting the outcome and the exact signals and reads. Confirm it fails because `kill_guard.dart` does not exist.
- [ ] 2.2 Implement `packages/process_containment/lib/src/kill_guard.dart` (D1, D3) with C4 as its library doc comment, not exported from the barrel. Verify `kill_guard_test.dart` passes and flip its Test map rows green.
- [ ] 2.3 Rewire `killProcessGroup` to call the guard with the fallback disallowed and one `PosixProcessTable` instance, and `PosixUnit.terminate` to call it with the fallback allowed. Write C1, C3, C5, C6, C8, C10 and C11 in the `killProcessGroup` doc comment. Verify with `mise run test:process_containment`.
- [ ] 2.4 Move `kill_group_test.dart`'s row to the live-unit entry (the guard with the fallback allowed and the real calls), since the public `killProcessGroup` no longer falls back. Verify it passes on POSIX (Linux and macOS CI; skipped on Windows) and flip its Test map row green.

## 3. Verification

- [ ] 3.1 Re-run the green rows of the Test map (`spawn_test.dart`, `marker_scan_test.dart`) and the host cleanup rows (`packages/host/test/it/cleanup_api_test.dart`); all pass.
- [ ] 3.2 C2 is the spec's requirement text (`specs/host-process-cleanup/spec.md`); confirm with `openspec validate fix-macos-zombie-kill --strict`.
- [ ] 3.3 Run `mise run check` and `mise run test:host`; both pass.
- [ ] 3.4 Comment on issue #31 adding the gaps this change records against it: the boot-scoped identity of recorded units (C11) and the non-leaf `proc_listpids` and environment `sysctl` (C9).

## Workflow follow-up

- Pre-ship review, then ship a PR that closes #30 and lists the round-5 findings fixed without a sixth design review.
- After it merges: PR #29 picks up main, its macOS row is checked, then #29 merges.
