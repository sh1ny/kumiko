# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| host-process-cleanup → Stopping a unit confirms its processes are gone | Unit with an escaped descendant is ended | packages/process_containment/test/spawn_test.dart | termination ends the session; the marker scan ends an escaped descendant | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits during the marker scan | packages/process_containment/test/marker_scan_test.dart | a recheck-confirmed exit still gets a second listing after the confirmation | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits during the second pass | packages/process_containment/test/marker_scan_test.dart | a process that exits during the second pass is cleared by the second settle | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A process exits while the process table is listed | packages/process_containment/test/proc_listing_test.dart | a vanished /proc entry is listed again and the listing succeeds | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The process table cannot be listed | packages/process_containment/test/proc_listing_test.dart | eight vanished-entry failures or another error are unlistable | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader exits while it is being stopped | packages/process_containment/test/kill_guard_test.dart | refused killpg: probe ESRCH is leaderGone, with no snapshot read | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader's pid is not confirmed before a direct signal | packages/process_containment/test/kill_guard_test.dart | killpg ESRCH: an unconfirmed leader gets no direct signal | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | The leader has no process group yet | packages/process_containment/test/kill_group_test.dart | a leader that has not made its group yet is still signalled | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A recorded unit's leader has no process group | packages/process_containment/test/kill_guard_test.dart | fallback disallowed: killpg ESRCH with the recorded start time is failed, with no direct signal | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A live process cannot be inspected | packages/process_containment/test/marker_scan_test.dart | a first-pass unconfirmed pid is named and the second settle does not run | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A marked process survives | packages/process_containment/test/marker_scan_test.dart | marked process that survives SIGKILL leaves the unit unresolved | green |
| host-process-cleanup → Stopping a unit confirms its processes are gone | A refused signal whose leader is not confirmed gone | packages/process_containment/test/kill_guard_test.dart | refused killpg: an inconclusive recheck is failed | green |

The other tests from the design's test map have no scenario row of their own; the tasks below name them. Every fake table answers by call count, never after a delay. The tests wait for events and assert order and outcome, not elapsed time (the Windows CI test rules that #29 adds to AGENTS.md).

## 1. The settle after the second pass

- [x] 1.1 In `packages/process_containment/test/marker_scan_test.dart`, write the failing fake-table tests: "a process that exits during the second pass is cleared by the second settle" (a match triggers pass 2, which refuses another pid; `confirmedExits` answers false for it on its first and second calls and true on its third; clean; exactly two pass listings); "a survivor stays when the second settle clears an unread pid" (two markers; `remaining` names the survivor, `unreadablePid` is null). Change #40's F2 test "a process that exits after its failed read on the final pass is unreadable" to "... is cleared by the final settle": it expects a clean scan, and its call log shows the pid's first check before the later pid's read and the confirming check after it. Verify with `mise exec -- dart test test/marker_scan_test.dart` in `packages/process_containment` that the new and changed tests fail because pass 2's pid gets one check and no settle, and that nothing else fails.
- [x] 1.2 In the same file, write the D2 guard tests, which must pass before and after the change: "a first-pass unconfirmed pid is named and the second settle does not run" (a pass-1 pid never confirmed and a pass-2 refused pid; `scan-unreadable` names the pass-1 pid; the pass-2 pid is asked exactly once); "a second pass that times out runs no second settle" (`scan-timeout`; the refused pid is asked exactly once); "a second pass that reads every pid runs no second settle" (no `confirmedExits` call after the second listing); "two unconfirmed second-pass pids name the first in listing order". Verify they pass on the current code with the same command.
- [x] 1.3 In `runMarkerScan` (`packages/process_containment/lib/src/marker_scan.dart`), run `_settle` after the second pass over that pass's pending pids, with no killed matches, only when pass 2 listed, did not time out, left pending pids, and settle 1 left none unconfirmed (D1, D2). Take `unreadablePid` from settle 1's first unconfirmed pid, else settle 2's, in listing order. Verify the whole file passes with `mise exec -- dart test test/marker_scan_test.dart`, including the existing "refusal first seen on the second pass yields scan-unreadable" and the real-table tests (skipped on Windows as today), and flip the red row green.
- [x] 1.4 Write C1 in the `runMarkerScan` doc comment: a pid the second pass cannot read is cleared only by `confirmedExits`, at its read or in the bounded settle after that pass; the second pass kills nothing; a marked process in it is a survivor; there is no third marker-scan pass. Replace #40's C2 text there. Update the `MarkerScanResult.unreadablePid` doc comment to state the order from D2. Verify with `mise run analyze` and by reading both comments against D1 and D2.
- [x] 1.5 Check that C2 is at its destination: the delta's "Stopping a unit confirms its processes are gone" requirement names a child started after the final listing by a pid confirmed only in the final settle as outside the scan, by the owner's decision. Verify with `openspec validate fix-scan-exiting-pid --strict`.
- [x] 1.6 Update the shutdown row in `openspec/architecture.md` (D4): each pass's 10 s clock starts after its opening listing; when a settle runs after a pass, its 1 s clock stops new sweeps, and a sweep already started and its 10 ms delay can finish after it; the clocks are checked between synchronous steps; the shutdown timeout stops the wait without cancelling the ending. Verify by reading the row against D4 and `marker_scan.dart`.

## 2. Integration and evidence

- [ ] 2.1 Run `mise run check` and `mise run test:host` (this change touches process containment); both pass.
- [ ] 2.2 [evidence] Rerun the WSL scan diagnostic on the fixed code for 60 s under the same load as the issue #42 run, and record the scan count and the count of each reason → evidence/wsl-scan-diag.txt

## Workflow follow-up

- A1 is checked by the macOS CI run of this change's PR and then of #29: `reconcile_test` "killed host's units cleaned or unresolved" passes.
- After this change merges, #29 merges main and gets its CI green.
