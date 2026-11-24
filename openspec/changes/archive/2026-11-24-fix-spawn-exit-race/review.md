# Review

## Metadata

- **Round:** 7
- **Prior round:** Round 6 — USER_OVERRIDE after the owner accepted fixes and deferred two findings. The amendment at `154d0ee` supersedes that override.
- **Reviewer:** cross-model CLI (OMP, GPT-6.2-sol)
- **Reviewed:** Proposal, design, tasks and test map, cleanup delta and current spec, architecture, ADR 0001, round-6 review, Dart unit-test skill, cited source ranges, and the process-containment, spawn-identity, reconcile, ledger, cleanup API, and terminal tests.
- **Limits:** Static review. No shell or file-write tool was available to run `git ls-files`, verify the checkout revision, or replace `review.md`. This is the replacement text. Tests were inspected, not run.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The amended `-1` scenario omits a reported scan failure.** The live scenario enumerates survivors, unreadable processes, and timeouts, but `Settler._scanFailure` also returns `scan-unlistable` for a scan that returns normally without listing processes (`settler.dart:129–140`; `marker_scan.dart:77–79,124–130`). This is not the deferred thrown-scan case. The restart scenario also says “unfinished scan,” without distinguishing a reported failure from an exception. If process enumeration is unavailable, the contract must say the workspace stays gated, as ADR 0001 requires.

2. **The test map does not pin both sides of the amended reason rule.** `spawn_identity_test.dart:220–295` covers reason retention across a thrown restart and a Retry that can end the marked process. It does not cover the new exception to **Retry still fails** when a marked process survives. The mapped `cleanup_api_test.dart:169–204` covers an ordinary recorded leader, not an ordinary row without a recorded PID. A regression could preserve every PID-less row's old reason or overwrite an unconfirmed row's PID-bearing reason only on a reported scan failure, without either mapped test catching it. The branches are explicit in `settler.dart:96–106,179–185`.

3. **The exact terminal behavior that prompted amendment (b) is not exercised end to end.** The mixed PTY test asserts `spawn-failed` and `stage: exec` for a non-executable file (`spawn_identity_test.dart:114–145`). The thrown-scan test uses a plain spawn (`:206–218`). Neither would catch a regression that replaces an unconfirmed `exec`/`ENOENT` error, or maps it to `spawn-failed` instead of `executable-not-found`. The current code does preserve the error and perform that mapping (`unit_manager.dart:218–230,362–384`; `terminal/terminal_service.dart:345–356`). D5 should distinguish preserving the spawn failure from rethrowing the same object: plain `SpawnIdentityUnconfirmed` is wrapped as `internal-error`.

4. **The tests named “while the scan is held” do not prove the launch is still in flight.** They observe the unresolved row, perform the second launch and Retry or Confirm, then await the original launch only after releasing the fault (`spawn_identity_test.dart:147–202`). If the scan stopped honoring `spawnScanHangs` but completed after the fixture reported, those assertions could all pass. Confirm's final absent-row check also cannot distinguish no late write from a late `UPDATE` against a deleted row (`ledger.dart:204–213`). The ordering test needs an observable hold and a consumer-visible check that the released scan does not publish a late ledger change.

5. **The test hook adds a production scheduling gap before identity capture.** `spawnPosixUnit` executes `await beforeStartTimeReadForTesting?.call(process)` even when the hook is absent (`posix_unit.dart:354–363`). Awaiting `null` yields before the snapshot. That gives the child another opportunity to be reaped and its PID reused before the snapshot, precisely the interval C5 accepts but D1 and D4 say the test hook alone stretches. A reused PID observed in that interval can supply the wrong start time.

6. **The bounded I/O cleanup claim exceeds the implementation.** D3 and task 1.3 say the spawn disposes of unclaimed endpoints on every failure path. The unchanged plain `_Refused` branch does not call `_abandonStdio` (`posix_unit.dart:390–399`). On PTY failures, `listen` is outside the setup catch and status cancellation is awaited before `master.close()`, without a `finally` (`:404–457`). A throwing injected stream can skip handle cleanup and, on an unconfirmed spawn, replace the error that carries `unconfirmedPid`. The cleanup ownership rule needs one carried-constraint destination; distinguish the intentionally unchanged plain refusal from the new cleanup guarantees.

7. **The evidence and scope markers still mix the pre-change baseline with the implementation.** For example, `posix_unit.dart:222` is now an identity variant, not the start-time read; `:283` is not `_statusTimeout` (`:489` is); and `test_hooks.dart:230–237` is not `test/unit.launch` (`:248–255` is). D1's binding premise needs a baseline revision because the checkout already binds `kill` as a leaf. D5's deferred gate and thrown-scan gaps are absent from **Carried constraints**, and the issue labels in the request conflict with those in D5 and the round-6 record. Without explicit boundaries, a future maintainer could read C9 as a guarantee before the unresolved write, or treat a thrown live scan as covered by the `-1` contract.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Include `scan-unlistable` in the live and restart `-1` outcomes. Distinguish reported failures from thrown scans, and align the failure table and test map with that distinction.
2. Add and map a Retry case with a surviving marked process and a PID-bearing reason. Assert that an ordinary PID-less row takes the normal `pending-without-pid` path rather than retaining its prior reason.
3. Add and map a terminal test that reaches shim `exec`/`ENOENT` with unconfirmed identity and a throwing cleanup scan. Assert `executable-not-found` and the retained unresolved row; do not require a stage. Keep the EACCES case and correct D5's error-propagation wording.
4. Make the held-scan tests observe that the launch remains in flight during the gate and cleanup actions. Verify no late ledger mutation through the cleanup revision or another observable state change.
5. Await `beforeStartTimeReadForTesting` only when supplied.
6. Make PTY failure cleanup run even if status stream setup or cancellation throws, without losing an already-classified unconfirmed PID. Align D3, task 1.3, and the `spawnPosixUnit` comment on the exact I/O guarantee, and carry it at that comment.
7. Pin historical claims to their baseline revision and repair the citations used for current behavior. Reconcile the deferred issue labels and give each deferred gap one carried-constraint destination.

CHANGES_APPLIED: yes

## Rebuttals

- The amended behavior is supported by the implementation: PID-bearing reasons are scoped to unconfirmed spawns, `exec`/`ENOENT` retains its existing terminal mapping, and a reported live `-1` settlement failure stays unresolved.
- This review does not reopen pre-write gating, thrown live settlement, or the unreported shim-exit ambiguity. It separates those deferred behaviors from the contracts this change ships.