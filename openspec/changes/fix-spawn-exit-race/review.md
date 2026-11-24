# Review

## Metadata

- **Round:** 5
- **Prior round:** Round 4 — REVISE. The owner requested all five required changes and another review.
- **Reviewer:** Cross-model CLI (OMP, GPT-6.2-sol)
- **Reviewed:** Round-4 review; revised proposal, design, and spec delta; current cleanup spec; architecture and ADR 0001; cited containment and host source; spawn, PTY, ledger, and reconciliation tests; test-host harness and Dart unit-test skill.
- **Limits:** No shell or file-write tool was available. I could not run `git ls-files`, verify the checkout against `783b59e`, inspect PR #29’s test rules, or replace `review.md`. This is the replacement text.

## Findings

### Critical (blocking)

1. **PTY error precedence still erases the evidence needed to keep the workspace gated.** D3 surfaces `SpawnIdentityUnconfirmed` only for empty EOF. A timeout, read error, or shim report instead surfaces `SpawnFailed`. `UnitManager.launch` passes only the thrown object to `_settleFailedSpawn`; the design does not carry the unconfirmed identity separately (`unit_manager.dart:216–230,330–341`). A live leader with a null snapshot can therefore be skipped by a clean marker scan and lose its row, reopening the workspace in violation of ADR 0001. C9 states the right invariant but does not specify how it survives D3. D4 tests status errors and unconfirmed identity separately, so neither test catches the combined failure.

2. **D1 leaves the workspace open while the failed-spawn scan runs, and indefinitely if it throws.** D1 marks the row unresolved *after* the scan. During that await, the row is still `pending`; another same-workspace launch can pass the gate, which selects only `unresolved` rows (`unit_manager.dart:179–193,330–341`; `ledger.dart:254–261`). The scan yields while traversing the process table and can propagate exceptions (`marker_scan.dart:125–149`); if it throws, the unresolved write is never reached. Fence new launches once identity is classified as unconfirmed, and retain the gate if the scan fails. Specify who owns the row until the scan finishes so Retry or Confirm cannot race a second settlement writer.

### Moderate

3. **The spec gives incompatible instructions for refused reads, PTY failures, and recovery.** “Can neither read the start time nor prove the process gone” includes `ProcessReadDenied`, but the refusal scenario and D1 retain the existing `SIGKILL` attempt. The fast-exit SHALL lacks the PTY failure exclusions its own scenario supplies. “No signal is sent to that pid” also prohibits the intended later marker-based signal if an independent read identifies the same process (`marker_scan.dart:79–83,129–155`). Finally, the delta says Retry or Confirm can clear the gate; D1 correctly notes that retrying a row with no recorded identity returns `pending-without-pid`. Retry and restart also overwrite the original PID-bearing diagnostic (`cleanup_service.dart:62–67,183–200`; `settler.dart:155–159,237–250`). That loses the information the user needs for manual confirmation.

4. **The durable-write test has a hold but no specified fast-exit fixture or independent PID evidence.** `terminateHangs` can hold natural settlement and the existing fault setter can release it (`settler.dart:130–140`; `host_faults.dart:153–164`). But the existing `test/unit.launch` accepts only fixtures that stay alive and returns only a containment ID (`test_hooks.dart:230–239`; `fixtures.dart:31–60`; `messages.dart:1453,1619–1622`). Using that route as-is makes `reaped` wait rather than exercise the write; taking the expected PID from the row tests nothing about its value. Name the existing host launch surface and fixture that exits and reports its own PID independently. Keep the seeded reconcile test separate.

5. **The `-1` settlement scenario conflates live cleanup and restart, and the test map does not prove the scan still runs.** Live termination can time out waiting for `exitCode`; a later host has no exit future and skips recorded-leader termination on the sentinel (`posix_unit.dart:122–153`; `settler.dart:145–158,195–203`). D4’s direct `terminate()` test and seeded unmarked-bystander test would both pass if host settlement accidentally skipped the marker scan for `-1`. Add a sentinel-row case with a marked descendant and assert its cleanup outcome. Distinguish a live exit-notification timeout from scan failure on either path.

6. **Several evidence references and carried statements still misstate the contract.** Context cites `marker_scan.dart:79–83` for listing and matching; those lines only signal matches, while listing and matching are at `114–157`. The test-option citation ends at the factory declaration (`test_hooks.dart:33–45`), before it reads the options. T1 says callers are unchanged despite D4 changing `_spawn`. The proposal says #33 gains no new way to report success, but D3 extends that ambiguity to reaped shims. C3 says an exited unit is returned *only* after the absence probe, excluding the existing readable-snapshot path when the process exits before return. Narrow C3 to **missing identity**, carry the distinction between outward PTY failure and cleanup evidence in C7/C9, and align the decision summary with those constraints.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Carry unconfirmed identity into host settlement independently of the outward PTY error. Add a deterministic mixed-outcome regression that observes the PTY stage, a clean scan, the unresolved row, and a `cleanup-unresolved` refusal.
2. Keep the workspace gated from classification through settlement, including a scan exception. Specify and test how another launch, Retry, and Confirm interact with that in-flight settlement.
3. Make the spec distinguish refused reads, unconfirmed identity, and PTY handshake failures. Limit the no-signal rule to direct signalling based on the unverified PID. State which action can clear this row and retain its PID-bearing reason through Retry and restart.
4. Specify a fast-exit host fixture and an independent PID observation without adding a protocol field. Assert the committed PID and `'-1'` while settlement is held, then release the hold and verify cleanup.
5. Separate live and restart settlement criteria. Automate the sentinel path with a marked descendant so the test fails if host settlement bypasses the scan.
6. Correct the citations, #33 scope wording, decision summary, and carried constraints identified above.

CHANGES_APPLIED: n/a

## Rebuttals

- Round-4 change 1 is incomplete: the plain failure has the required unresolved outcome, but PTY precedence and scan interruption can still bypass it.
- Round-4 change 2 fixed ordinary launch reporting and added a status-read scenario. The remaining contradictions are in findings 3 and 5.
- Round-4 change 3 addressed the standalone read-error seam, proved-gone observation, and teardown registration. The mixed status/identity case is still uncovered.
- Round-4 change 4 added host forwarding and a releasable hold. The fixture and independent PID observation are still unspecified.
- Round-4 change 5 corrected failed-spawn routing and empty-EOF ambiguity in D3, distinguished local cleanup from host settlement, and added C8. The proposal and carried wording still need alignment.
- No `tasks.md` was present to review. The new verification cases are automatable; none requires a user observation.
- **Owner escalation:** Resolve the two blocking settlement decisions before implementation: how identity uncertainty crosses the PTY error boundary, and when the workspace gate takes effect.