# Review

## Metadata

- **Round:** 6
- **Prior round:** Round 5 — REVISE. The owner requested all six fixes and another review of revision `0f008fd`.
- **Reviewer:** user (USER_OVERRIDE), after round 6 by the cross-model CLI (OMP, GPT-6.2-sol); the round-6 findings below are the reviewer's
- **Reviewed:** Round-5 review, proposal, design, cleanup spec delta and current spec, architecture, ADR 0001, Dart unit-test skill, cited process-containment and host source, protocol fixture definitions, spawn and PTY tests, and relevant host ledger and terminal tests.
- **Limits:** No shell or file-write tool was available. I could not run `git ls-files`, independently verify the checkout against `0f008fd` or inspect PR #29’s test rules, or replace `review.md`. This is the replacement text. No `tasks.md` was present in the change directory.

## Findings

### Critical (blocking)

1. **D5 gates the scan, but not the interval after PTY identity becomes unconfirmed.** D3 classifies identity before waiting up to five seconds for PTY status (`posix_unit.dart:240–283`). D5 acts only after `_spawn` throws. In that interval the ledger row is `pending`, and a second same-workspace launch can pass `UnitManager.launch`’s unresolved-only gate (`unit_manager.dart:179–230`; `ledger.dart:254–261`). There is a second fail-open path: if the first `markUnresolved` fails, `_guard` propagates a store error and leaves only the pending row (`ledger.dart:72–78,199–206`). The design needs a fail-closed admission rule from classification through the durable write, not just before the scan.

2. **A scan exception still breaks both PTY error precedence and the restart diagnostic.** In the launch path, an exception from `_settleFailedSpawn` bypasses the rethrow of the original `SpawnFailed` (`unit_manager.dart:216–230`). Marking the row earlier preserves the gate, but the caller can lose the `status-read` or `exec` error that D3 says wins. At restart, preserving `row.reason` in `Settler._terminate` only works when `settle` returns normally: `CleanupService._reconcile` catches scan exceptions and overwrites every affected row with `reconcile-failed: $e` (`cleanup_service.dart:60–75`). The user then loses the PID needed for confirmation. D5 and C9 promise preservation on these paths but do not change the handlers that defeat it.

3. **A thrown live sentinel scan can leave a `running` row and an open workspace.** `Settler.settle` awaits the scan before returning outcomes (`settler.dart:64–88`); a thrown scan skips `settler.apply` in `UnitManager.endUnits` (`unit_manager.dart:404–425`). The natural exit watcher discards the error (`unit_manager.dart:259–267`), and the terminal end path’s generic catch returns `end-failed` without marking the ledger unresolved (`terminal_service.dart:619–635`). Thus a fast-exit terminal can report cleanup failure while a subsequent launch is accepted against the same workspace. The delta says an unfinished scan leaves the live unit unresolved; ADR 0001 requires that to gate execution, not just appear in a terminal error.

### Moderate

4. **The delta does not reconcile its new recovery rules with the requirements it inherits.** The current cleanup spec’s unqualified “Retry succeeds” scenario requires rows to clear after surviving processes exit; the delta says an unconfirmed row stays unresolved with the same reason and only Confirm clears it. Put the exception in the Retry requirement and scenarios. Also define unconfirmed as *absence not proved* after a null snapshot, not just the OS affirmatively reporting a process, to match D1’s non-`ESRCH` branch. Make the in-flight gate explicitly subject to user confirmation. For refused reads, specify the existing kill *attempt* and settlement: the current code ignores the kill result and the plain path does not wait for exit (`posix_unit.dart:223–229,269–275`).

5. **The gate and mixed-error tests are not yet deterministic tests of their stated contracts.** `killFails` cannot make the scan throw: `_NoKillTable` delegates reads and returns `false` from `kill` (`settler.dart:91–102,273–291`). A launch attempted only after the scan throws also passes if the row was marked in a post-scan catch. Hold the scan at an observable barrier, attempt a launch while held, and exercise Retry and Confirm against the in-flight scan; separately release it with an exception. For the mixed PTY case, `test/unit.launch` is not a PTY launch (`test_hooks.dart:230–238`), and the terminal maps `exec`/`ENOENT` to `executable-not-found` without the PTY stage (`terminal_service.dart:345–356`). Reuse the non-executable profile case that exposes `spawn-failed{stage: exec}` (`terminal_test.dart:143–162`), force the probe result independently of when the shim exits, and assert the stage, clean scan, PID-bearing row, and refusal.

6. **D4 does not supply a way to exercise the promised live timeout.** The `reaped` hook awaits the same `Process.exitCode` that `PosixUnit.terminate` observes (`posix_unit.dart:111–127`). None of the proposed seams holds that observation back. Host `terminateHangs` stops before `terminate` and does not exercise its `termination-timeout` result (`settler.dart:130–140`). Specify a deterministic direct test of the POSIX timeout branch and a host test that observes the unresolved ledger outcome. The durable-write fixture is otherwise sound; use a valid enum value such as `reportedExit` consistently, since the RPC passes `p.fixture.name` straight to the fixture dispatcher (`messages.dart:1453,1610`; `test_hooks.dart:230–237`).

7. **The failure path leaves ownership of abandoned I/O unspecified.** Today the PTY status listener is not retained or canceled after timeout (`posix_unit.dart:242–258`); failed-spawn cleanup relied on ending the child to close its streams. D3 allows an unconfirmed child to survive, and closing the PTY master does not cancel the separate shim stdout subscription. A plain failed `_spawn` also bypasses the host’s post-success drains (`unit_manager.dart:216–226,298–312`). Specify who abandons the status subscription and other unclaimed endpoints on each failure path, without waiting for the unsignalled process to exit. Otherwise an unresolved process can retain host-side I/O after its launch has returned.

8. **Remaining evidence and carried-constraint gaps hide implementation work.** `cleanup_service.dart:183–200` shows Retry, not restart; cite the restart catch at `60–75`. `windows_unit.dart:434–442` shows the read before resume, but the suspended creation premise is at `396–408`. The `test_hooks.dart:33–57` citation reaches the environment reads but not their forwarding into `HostOptions` at `86–139`. A1 assigns the reaping check to absent Task 1.1; map it to an automated task when adding the task list. C9 should explicitly carry D5’s rejected representation: the unconfirmed PID is diagnostic only and must not become a recorded leader identity that Retry can signal. Record ownership of that row and reason across launch, Retry, restart, and Confirm in the FULL state table.

### Suggestions

None.

## Verdict

The owner, after rounds 5 and 6 (two consecutive REVISE) were escalated: "Fix the #18 critical and the moderates, file the other two as issues, go to the build".

VERDICT: USER_OVERRIDE

## Required Changes

None: the round-6 changes the owner asked for are applied in the revision this verdict covers.

CHANGES_APPLIED: n/a

## Rebuttals

Open findings at the override and their handling:

1. Critical 1 (gate during the PTY status wait; a failed unresolved write): not fixed here. Filed as #34 on the owner's decision; D5 records it as out of scope. Open.
2. Critical 2 (scan exception replaces the spawn error; restart catch overwrites the reason): fixed in D5 and C9. The scan error is caught and the spawn's error rethrown; the restart catch keeps a `spawn-identity-unconfirmed` reason. Test "Scan throws" in D4.
3. Critical 3 (a thrown scan while ending a live unit leaves the row running): exists today for every unit. Filed as #35 on the owner's decision. Open.
4. Moderate 4: the delta now modifies "Unresolved cleanup is shown and can be retried or confirmed" (Retry leaves a unit with no recorded identity unresolved; Confirm clears it). Unconfirmed is defined as absence not proved. The refused read says "attempts to kill" and names the host's scan.
5. Moderate 5: new test faults `spawnScanHangs` and `scanThrows`; the gate is asserted while the scan is held, and Confirm is checked against late scan completion. The mixed PTY case uses the non-executable profile route (`exec` stage) with the probe injected.
6. Moderate 6: `forced-gone` identity hook and `KUMIKO_TEST_KILL_WAIT_MS` give a deterministic live timeout, directly and at host level. The fixture is named `reportedExit`.
7. Moderate 7: D3 makes the spawn cancel the status subscription and close the master and unclaimed endpoints on every failure path, without waiting for the process to exit.
8. Moderate 8: citations corrected (restart catch 60-75, Windows 396-408, option forwarding 86-139). The A1 check is a tasks.md task. C9 carries the diagnostic-only pid. The state table has a row for the unconfirmed row's owner.

The pre-ship review is the next gate.
