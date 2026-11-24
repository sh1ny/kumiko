# Review

## Metadata

- **Round:** 3
- **Prior round:** REVISE. The owner deferred status-descriptor setup failure to issue #33 and requested fixes for the remaining findings.
- **Reviewer:** Cross-model CLI (OMP, GPT-6.2-sol)
- **Reviewed:** Proposal, design, current and delta `host-process-cleanup` specs, architecture, ADR 0001, round-2 review, repository test rules, and the Dart unit-test skill. Read the cited ranges in `posix_unit.dart`, `posix_process_table.dart`, `contained_unit.dart`, `unit_exec.dart`, `windows_unit.dart`, `pty.dart`, `ledger.dart`, `settler.dart`, and `unit_manager.dart`; also checked `libc.dart`, `process_identity.dart`, `marker_scan.dart`, `spawn_test.dart`, `pty_test.dart`, and the reused-PID reconciliation test.
- **Verification limits:** This harness could not run `git ls-files` to verify index membership and file modes, or overwrite `openspec/changes/fix-spawn-exit-race/review.md`. This is the replacement text; the file was not changed.

## Findings

### Critical (blocking)

1. **D1 adds a PID-reuse window on the failure path.** The old null-read path went straight to `process.kill` (`posix_unit.dart:222–229,265–270`). D1 inserts a probe: the snapshot can see the child gone, then `kill(pid, 0)` can find a replacement, and the specified failure path responds by killing that PID. The probe establishes presence, not identity. C5 covers reuse *before* the snapshot, not this new interval. The delta must not require killing a process whose identity the spawn cannot establish.

2. **D1 uses a probe whose `errno` handling does not meet the repository’s own contract.** `posixKill` reads `errno` after a non-leaf FFI call (`posix_process_table.dart:10–25`); `libc.dart:10–20` documents using leaf calls and binding the accessor before the failing call. A first plain Linux spawn can reach the probe without priming that accessor. D1 makes this result the sole positive evidence of absence: a wrong errno can reject the fast exit this change is meant to fix, or allow a live leader to be recorded as gone. The cited wrapper shows how it reads errno, not that the read is reliable.

3. **D3 retains the separate status-stream error from round 2.** `onError` completes the same completer as EOF, and `onDone` can then complete it a second time (`posix_unit.dart:243–250`). An empty read error can therefore become a successful `-1` launch instead of a failed handshake; a later close can raise a second error. Issue #33 covers the shim failing to duplicate its status descriptor, not the host failing to read the pipe.

### Moderate

4. **The delta still conflates leader checks with marker cleanup and a durable write with row retention.** The recorded-leader scenario says the PID is not inspected or signalled at all. The independent scan snapshots listed PIDs and can signal a process that carries the marker, even if it happens to reuse that number (`marker_scan.dart:79–85,129–156`). An unreadable replacement can still make the scan unresolved, and live termination can independently return `termination-timeout` while waiting for exit notification (`posix_unit.dart:122–153`; `settler.dart:83–88,109–119`). Separately, `markRunning` precedes launch reporting, but natural settlement can delete the row (`unit_manager.dart:241–264,412–419`; `settler.dart:237–250`). The fast-exit scenario also needs to exclude PTY timeout and reported failure, which D3 correctly keeps as failures.

5. **D4 does not yet specify tests that distinguish the changed behavior from the old behavior.** `SpawnFailed('exec', …)` already occurs with or without a readable snapshot; an error-only assertion does not prove the reaped branch. A readable bystander with a seeded `-1` row also survives under the old mismatch guard (`reconcile_test.dart:103–137`), so that alone does not prove the short-circuit or the launch’s durable write. D4’s claim that awaiting `exitCode` takes the gone branch on every run contradicts A1’s reuse exception. The suite hang guard is not a hook timeout: it can fail the test without running spawn cleanup for the still-pending hook. The checked-out `AGENTS.md` has no “Tests that run in Windows CI” section; the existing tests show the POSIX skip convention.

6. **Two remaining claims exceed their evidence.** The `posixKill` wrapper does not establish the categorical claim about zombies on both kernels; D1 needs reliable `ESRCH` evidence, not that broader claim. “Descendants … are in the unit’s session” contradicts ADR 0001 and the escaped-descendant fixture (`spawn_test.dart:120–145`). The guarantee is marker-based for descendants that retain the marker, not session membership or detection of descendants that escape and clear it.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Define null snapshot plus non-`ESRCH` as an unconfirmed failed spawn, not authority to signal that PID. Specify identity-safe settlement and when uncertainty leaves the row unresolved. Update the refusal scenario, failure diagram, and carried PID-reuse constraint.
2. Make the absence probe preserve the failing call’s errno using the repository’s leaf-call and prebinding convention, or an equivalent verified mechanism. Narrow or substantiate the cross-platform zombie claim.
3. Treat a status-stream read error as a failed handshake, not EOF. Specify single completion, cleanup, and precedence alongside timeout and a reported shim failure. Keep the `status-fd` fix in #33.
4. Specify the durable PID/`-1` write before launch reporting, not retention afterward. Restrict the no-inspection/no-signal assertion to the recorded-leader check; retain independent marker scanning and unresolved outcomes. Qualify PTY success and the descendant guarantee accordingly.
5. In the design, commit to automated coverage for both proved-gone launches, a reaped shim with a reported failure, refused and null-but-present reads, status-stream failure, the durable `-1` write, and live/restart cleanup. Require assertions that fail if the relevant branch or short-circuit is missing. Give the awaited test hook a cleanup-triggering deadline and skip POSIX-only rows on Windows. The detailed task map can follow in `tasks.md`.
6. Carry each revised identity and PTY constraint to one named destination, including the distinction between a reported shim failure, a read error, and an unreported pre-exec exit.

CHANGES_APPLIED: n/a

## Rebuttals

- Round-2 finding 1 is addressed in the leader guards by D2/C2. The marker scan remains independent.
- Round-2 finding 2’s null-only inference is removed. Findings 1 and 2 above concern the new probe and its failure path.
- The owner’s #33 disposition stands. This change does not introduce the shim’s status-descriptor setup failure, but it does change the outcome when that failure leaves empty EOF and the shim has already been reaped. Record that scope explicitly; do not reopen #33 here.
- The prior timing claim is gone, the cited status-parser and failed-spawn ranges are corrected, and C3–C6 cover the previously omitted constraints.