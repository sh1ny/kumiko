# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| host-process-cleanup → Stopping a unit confirms its processes are gone | Unit with an escaped descendant is ended | packages/process_containment/test/spawn_test.dart | termination ends the session; the marker scan ends an escaped descendant | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits during the marker scan | packages/process_containment/test/marker_scan_test.dart | a recheck-confirmed exit still gets a second listing after the confirmation | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits while the process table is listed | packages/process_containment/test/proc_listing_test.dart | a vanished /proc entry is listed again and the listing succeeds | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The process table cannot be listed | packages/process_containment/test/proc_listing_test.dart | eight vanished-entry failures or another error are unlistable | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader exits while it is being stopped | packages/process_containment/test/kill_guard_test.dart | refused killpg: probe ESRCH is leaderGone, with no snapshot read | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader's pid is not confirmed before a direct signal | packages/process_containment/test/kill_guard_test.dart | killpg ESRCH: an unconfirmed leader gets no direct signal | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader has no process group yet | packages/process_containment/test/kill_group_test.dart | a leader that has not made its group yet is still signalled | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A recorded unit's leader has no process group | packages/process_containment/test/kill_guard_test.dart | fallback disallowed: killpg ESRCH with the recorded start time is failed, with no direct signal | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A live process cannot be inspected | packages/process_containment/test/marker_scan_test.dart | a pending process gone only in the second pass stays scan-unreadable | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A marked process survives | packages/process_containment/test/marker_scan_test.dart | marked process that survives SIGKILL leaves the unit unresolved | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A refused signal whose leader is not confirmed gone | packages/process_containment/test/kill_guard_test.dart | refused killpg: an inconclusive recheck is failed | green |

Further tests from the design's test map, with no scenario row of their own, are named in the tasks below. Every fake table answers by call count, never after a delay (AGENTS.md rules 2 and 3).

## 1. Linux exit evidence and the /proc listing retry

- [x] 1.1 Verify A2: read proc(5) (`hidepid`, `/proc/<pid>/status` `State:` and `Threads:`) and the kernel's `Documentation/filesystems/proc.rst` for the visibility rule and the thread count of a zombie leader; record what was read and the result in the commit body. A contradiction is design drift: stop and amend D2.
- [x] 1.2 Write failing pure tests in `packages/process_containment/test/exit_evidence_test.dart` (runs on every OS): a status text with `State: Z` and `Threads: 1` confirms; `Z` with 2 threads, `Z` with 0 threads, `R` with 1 thread and a status missing either field do not; a mountinfo with `hidepid=2` or `hidepid=invisible` on the `proc` mount at `/proc` hides pids, `hidepid=0`, `hidepid=off` or no option does not, and an unparseable mountinfo counts as hiding. Verify they fail because the decoders do not exist.
- [x] 1.3 Implement the pure decoders `linuxStatusConfirmsExit` and `procHidesPids` in `posix_process_table.dart` (no stat state consulted); verify the 1.2 tests pass with `mise exec -- dart test test/exit_evidence_test.dart`.
- [x] 1.4 Write failing tests in `packages/process_containment/test/proc_listing_test.dart` for a pure `listProcPids` with the listing injected: `a vanished /proc entry is listed again and the listing succeeds`; `eight vanished-entry failures or another error are unlistable` (8 ENOENT/ESRCH failures on `/proc/<digits>`, one EACCES, and one ENOENT on a non-pid path each throw `ProcessTableUnlistable`, with the attempt count asserted). Verify they fail because the helper does not exist.
- [x] 1.5 Implement `listProcPids` (at most 8 attempts, retry only ENOENT/ESRCH on a `/proc/<digits>` path) and use it in the Linux `listPids`; write C4 as its doc comment. Verify the 1.4 tests pass and flip the two listing rows of the test map green.

## 2. macOS exit evidence

- [x] 2.1 Verify A3: re-read `bsd/kern/proc_info.c` (`proc_pidinfo` with `arg` 0 uses `proc_find` and does not wait) and `bsd/kern/kern_proc.c`/`kern_exit.c` (`proc_listpids(PROC_ALL_PIDS)` walks `allproc` then `zombproc`; a pid leaves both only when reaped) in apple-oss-distributions/xnu, for facts only; record the files and the result in the commit body. A contradiction is design drift: stop and amend D2.
- [x] 2.2 Write failing pure tests in `exit_evidence_test.dart` for `macConfirmedExits`: given the start times read by the leaf call (or none) and a complete listing, a different start time confirms, the same one does not; a pid absent from the listing confirms, a present one does not; a listing that threw confirms only the start-time differences. Verify they fail because the function does not exist.
- [x] 2.3 Implement `macConfirmedExits` in `posix_process_table.dart`; verify the 2.2 tests pass.

## 3. `ProcessTable.confirmedExits`

- [x] 3.1 Add `Set<int> confirmedExits(Map<int, int?> pids)` to `ProcessTable` with C3 and C5 as its doc comment; correct the `ProcessSnapshot.zombie` doc comment (on Linux, the leader's state); give `FakeProcessTable` an `onConfirmedExits` callback that logs each call and, as today, a `listPids` call log, so tests can assert the order of confirmations and listings; forward it from the host's `_NoKillTable` in `packages/host/lib/src/settler.dart`. Verify `mise run analyze` passes.
- [x] 3.2 Write failing real-table tests in `packages/process_containment/test/confirmed_exits_test.dart` (`testOn: linux || mac-os`, one generous outer hang guard, rule 4): `a live child is not confirmed`; `a waited-for child is confirmed`; `an unreaped zombie is confirmed on Linux and not on macOS`, with the synchronized fixture from the design (a shell starts a child that blocks on its stdin, prints its pid and `exec`s into `sleep`; the test polls until the parent is `sleep`, releases the child, and polls the child's snapshot until it is a zombie, each poll bounded and failing loudly with what it waited for, rule 6). Verify they fail because the table does not implement the method.
- [x] 3.3 Implement the Linux `confirmedExits` (mountinfo read per call, stat ENOENT/ESRCH only without `hidepid`, start-time difference, one status read through `linuxStatusConfirmsExit`) and the macOS one (leaf `arg` 0 read per pid with a start time, then one `listPids` after those reads, through `macConfirmedExits`, no errno); write C8 as the doc comment of `macConfirmedExits`. Verify the 3.2 tests pass on WSL and `mise run test:process_containment` passes on Windows; macOS is checked by CI in 5.3.

## 4. The marker scan

- [x] 4.1 Write failing tests for `foreignPids` (design D1, D2 amendment): pure `macForeignPids` tests in `exit_evidence_test.dart` (absent from our user's listing is named, listed is not, a thrown listing names none); real tests in `confirmed_exits_test.dart` (Linux names nothing; macOS names pid 1 and not a live child of ours); and make the real unreaped-zombie case Linux-only (rule 9). Verify they fail because `foreignPids` does not exist.
- [x] 4.2 Add `Set<int> foreignPids(Set<int> pids)` to `ProcessTable` with its doc comment; implement it (Linux: empty; macOS: one complete `proc_listpids(PROC_UID_ONLY, uid)` through `macForeignPids`), in the fake table (`onForeignPids`, with a call log) and in the host's `_NoKillTable`. Verify the 4.1 tests pass on Windows and WSL and `mise run analyze` passes.
- [x] 4.3 Write failing tests in `packages/process_containment/test/marker_scan_test.dart`, updating `process gone or pid reused between list and read counts as gone` and `live unreadable process yields scan-unreadable` to confirm through `confirmedExits`: `a recheck-confirmed exit still gets a second listing after the confirmation`; `a pending process confirmed during the settle contributes no failure`; `a pending process never confirmed yields scan-unreadable`; `a pending process gone only in the second pass stays scan-unreadable`; `null or zombie snapshot without confirmed exit is pending`; `out-of-population zombie is skipped without an exit check` (another uid, and separately a known start before the window); `a short-info placeholder start time does not exclude a zombie`; `a null snapshot of another user's pid is skipped`; `refusal first seen on the second pass yields scan-unreadable`; `child of a confirmed exit is found by the second pass`; `child of a recheck-confirmed exit is found by the second pass`; `one confirmed and one unconfirmed pending pid name the unconfirmed one`; `unconfirmed pid then an unlistable second pass yields scan-unlistable`; `a timed-out first pass kills its matches and drops pending pids`. Verify each fails for the missing behaviour, not a setup error.
- [x] 4.4 Implement the scan (D1, D3): the population filter before a pid becomes pending (start time 0 is unknown and excludes nothing; null-snapshot pids named by one `foreignPids` call per pass are skipped); pending and not-read pids; the settle over killed matches and pending pids with one `confirmedExits` call per sweep, inside its existing 1 s and 10 ms poll; a second pass whenever a match, pending or not-read pid exists, verification only. Write C1, C2 and C7 as the doc comment of `runMarkerScan`. Verify the 4.3 tests pass and flip the two scan rows of the test map green.
- [x] 4.5 C6: confirm the cleanup requirement in `specs/host-process-cleanup/spec.md` states that an unreadable, unconfirmed process prevents a clean result and that an exiting process is not by itself a reason; verify with `openspec validate fix-unreadable-scan-process --strict`.
- [x] 4.6 Re-run the unchanged rows (`spawn_test.dart`, `kill_guard_test.dart`, `kill_group_test.dart`, `marker_scan_test.dart`) with `mise run test:process_containment`, and `mise run test:host`; both pass.

## 5. Integration

- [x] 5.1 Run the WSL reproduction (the real scan in a loop for 60 s while shell loops start and end processes) against the changed code; record the scan count and every failure in the commit body. No `scan-unlistable` from a vanished entry and no `scan-unreadable` from an exiting process is expected; any other failure is investigated, not retried (rule 8).
- [x] 5.2 Run `mise run check`; it passes.
- [x] 5.3 Verify A1: the PR's CI is green on Windows, Ubuntu and macOS, including the host integration tests that failed with `scan-unreadable` and `cleanup unresolved`; record the run in the PR. A red macOS row naming `scan-unreadable` is investigated as design drift, not rerun.

## Workflow follow-up

- Pre-ship review, PR, Codex review request, CI watch, archive on the branch, merge per the repository's policy.
- Then merge main into PR #29, get its CI green and merge it.
