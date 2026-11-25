I can read the checkout but can’t write files with the available tools. The full replacement for `review.md` follows.# Review

## Metadata

- **Round:** 1
- **Prior round:** none
- **Reviewer:** OpenAI Codex via OMP
- **Reviewed:** `fix-scan-exiting-pid` proposal, design and spec delta; the base `host-process-cleanup` spec; the archived `fix-unreadable-scan-process` design; `openspec/architecture.md`; ADR 0001; `AGENTS.md`; the `dart-add-unit-test` skill; `marker_scan.dart`, `marker_scan_test.dart`, `fake_process_table.dart`, `process_table.dart`, `posix_process_table.dart`, `settler.dart`, `unit_manager.dart`, `host.dart` and `host_options.dart`. Read-only review; no tests run.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The delta forbids a process-table listing that macOS needs for exit evidence.** The new second-pass scenario says the scan “lists the processes no third time.” On macOS, `confirmedExits` itself calls `listPids()` (`posix_process_table.dart:512–523`). A final settle can therefore list the table again without running a third marker-scan pass. The fake records the two pass listings but does not model the macOS evidence listing. The invariant is **no third marker-scan pass**, not two kernel listings.

2. **The unreadable scenario contradicts D2 when both passes leave pending PIDs.** If pass 1 leaves PID A unconfirmed and pass 2 cannot read PID B, D2 skips the final settle and reports A. The delta's “A live process cannot be inspected” scenario assumes the final settle runs and says the reason names B unless listing or timeout takes precedence. The existing selection order already gives A priority (`marker_scan.dart:132–143`). State that order in the delta rather than leaving the implementer to choose between the spec and D2.

3. **D4 overstates the wall-clock and ledger guarantees.** `_pass` starts its clock after `listPids()`. `_settle` checks its clock before a synchronous sweep and can take another delay before checking again (`marker_scan.dart:154–160,230–251`). `UnitManager.shutdown` uses `Future.timeout`, which neither interrupts that sweep nor cancels `endUnits`. A sweep that starts just before the deadline can finish after it, and `endUnits` can apply the outcome before the timer callback runs (`unit_manager.dart:469–470,502–529`). Document the existing cooperative deadline and the added synchronous work. Do not imply a hard cutoff or add cancellation to this change.

4. **The test map does not distinguish polling from a one-shot recheck.** The new success case confirms on the second `confirmedExits` call, which is the first settle sweep. The changed F2 case also confirms on that sweep. A single post-pass recheck would pass both. Changing F2 to assert only a clean result also loses its check that the original exit check happens at the failed read (`marker_scan_test.dart:396–426`). The existing fake can prove both properties without wall-clock assertions.

### Suggestions

- D2's survivor paragraph describes a single-unit outcome. In a shared scan, `scan-unreadable` applies to every row without a prior termination failure, but `marked-survivor` applies only to the matching row. Once the final settle clears the unreadable PID, other units in that batch can be cleaned (`settler.dart:99–105,136–147`).
- The checked-in `AGENTS.md` does not contain a “Tests that run in Windows CI” section or the numbered rules cited by the proposal and test map. The existing fake cases run without a platform guard, and the real-table smoke test skips Windows (`marker_scan_test.dart:613–632`). Keep that split and cite the applicable rule text rather than numbers absent from this checkout.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. In the delta's second-pass scenario, D1, C1 and the test map, replace “no third listing” with “no third marker-scan pass” or “two marker-scan pass listings,” as appropriate. Note that macOS exit evidence can take additional listings. Keep D3's accepted descendant exception and the existing macOS foreign-PID waiver unchanged.

   **Verified.** The delta, D1 and C1 rule out a third pass. The test map counts pass listings only, while D1 identifies the separate macOS evidence listing in `confirmedExits`. The delta retains the accepted descendant exception and the existing foreign-PID waiver.

2. In the delta, state that a final-pass PID can be confirmed at its failed read or during the final settle **if that settle runs**. In “A live process cannot be inspected,” specify that unlistable and timeout take precedence, then the first unconfirmed PID from settle 1 in listing order, then the first unconfirmed PID from settle 2 in listing order. Update the `MarkerScanResult.unreadablePid` comment alongside `runMarkerScan`; it currently describes only the first-pass cutoff.

   **Verified in the design.** The delta makes the final settle conditional and states the required precedence and listing order. D2 requires both doc comments to change together during implementation. The source comment still describes only the first-pass cutoff.

3. In D4, Resource Bounds and the proposed architecture-row edit, describe the 10 s pass clocks as starting after listing and the 1 s settle clocks as stopping admission of new sweeps. Account for the synchronous step and poll delay that may overrun those clocks. Describe the shutdown timeout as cooperative and non-cancelling. Keep the existing numeric settings.

   **Verified.** D4, Resource Bounds and the architecture-row wording in D4 place each 10 s pass clock after its opening listing. The 1 s settle clock stops new sweeps. A pass can overrun by one PID iteration; a settle can overrun by an admitted synchronous sweep and its 10 ms delay if PIDs remain. Resource Bounds places macOS evidence listings inside the iteration or sweep that calls `confirmedExits`, not outside the clock (`marker_scan.dart:154–169,241–248`; `posix_process_table.dart:512–523`).

   D4 and Context now say `Future.timeout` stops waiting without cancelling `endUnits`. `endUnits` can still apply its outcome after the deadline (`unit_manager.dart:469–470,502–529`). D4 includes the poll delay in the work that can continue past shutdown. The numeric settings are unchanged.

4. Change the new pass-2 success case to confirm on the third `confirmedExits` call for that PID: the failed-read check and first settle sweep both return false. In the revised F2 case, assert that the first check happens before the later PID is read and the successful check happens after it. Use `FakeProcessTable` callbacks and counts, not sleeps or elapsed-time assertions.

   **Verified in the test map.** The new case requires a second settle sweep. The F2 case requires the failed-read check and the successful check to fall on opposite sides of the later PID's read. `FakeProcessTable.confirmCalls` and the read callbacks support both assertions without elapsed-time checks. These are planned test changes, not changes to the current test source.

5. Correct the host claims in T4 and D2: `_scanFailure` reads `listed`, `timedOut`, `unreadablePid` and marker-filtered `remaining`; it does not read `MarkerScanResult.failure`. State the per-row effect of clearing a scan-wide unreadable reason.

   **Verified.** T4 matches `_scanFailure`. D2 and the Context's Reasons item distinguish a scan-wide unreadable reason from a marker-specific survivor. Clearing the unreadable reason lets rows with neither a prior termination failure nor a matching survivor be cleaned (`settler.dart:108–112,136–147`).

CHANGES_APPLIED: yes

## Rebuttals

- Moderate 1 / RC1: fixed. The delta's second-pass scenario says "runs no third pass"; D1, C1 and the D1 summary row say "no third marker-scan pass"; D1 and the Context's Clocks item note the macOS evidence listing in `confirmedExits`; the test map counts two pass listings.

  **Accepted.**

- Moderate 2 / RC2: fixed. The requirement says a final-pass pid is cleared at its failed read or, when the settle after that pass runs, before it ends, and names when that settle does not run. "A live process cannot be inspected" gives the order: unlistable or timeout; the first unconfirmed pid of the first pass; the first of the second pass, each in listing order. D2 states the same order and updates the `MarkerScanResult.unreadablePid` doc comment.

  **Accepted for the design.** D2 specifies the doc comment update; the source comment has not changed.

- Moderate 3 / RC3: fixed. The Context gains a Clocks item; D4 and Resource Bounds describe the pass clocks as starting after listing, the settle clocks as stopping new sweeps, the overruns, and the shutdown deadline as cooperative and non-cancelling. The numbers are unchanged.

  **Not accepted at the previous re-check.** The proposed architecture wording still stated a hard settle cap, Resource Bounds excluded macOS evidence listings from the clocks that cover them, and the Context still promised a shutdown cutoff for ledger changes. D4's shutdown overrun description also omitted the poll delay.

  Author, after the re-check: fixed. D4's architecture-row text and the proposal's Impact line now say each pass's 10 s clock starts after its opening listing and that a settle's 1 s clock stops new sweeps, with an admitted sweep and its 10 ms delay able to finish after it; no "at most 1 s" remains in the proposal, design or delta. Resource Bounds says only the opening listings precede their pass clocks, and that the macOS evidence listing in `confirmedExits` runs inside a pass iteration or settle sweep and counts toward its overrun. The Context's Shutdown item now describes `Future.timeout` as stopping the wait without cancelling `endUnits`, which can still apply its outcome (`unit_manager.dart:469-470, 502-529`). D4 counts the 10 ms delay in the work that can run past shutdown.

  **Accepted for RC3.** D4's proposed architecture-row wording specifies both clocks. The proposal's Impact line does not restate the 10 s clock's start point, but it removes the hard settle cap and describes the permitted overrun. Resource Bounds and Context correct the listing and ledger claims.

- Moderate 4 / RC4: fixed. The new test confirms on the pid's third `confirmedExits` call; the changed F2 test asserts the order of the first and the confirming check around the later pid's read. A test for two unconfirmed pass-2 pids is added.

  **Accepted for the test map.** The map specifies both required assertions and includes the two-PID listing-order case.

- RC5: fixed. T4 lists what `_scanFailure` reads; the Context's Reasons item and D2 state the per-row effect of a scan-wide unreadable reason versus a marker-filtered survivor.

  **Accepted.**

- Suggestion 1: taken in D2 (per-row effect) and in the survivor test (two markers).

  **Accepted.** D2 states the per-row effect, and the test map uses two markers with a survivor for only one.

- Suggestion 2: taken. The proposal and test map quote the rule wording, noting that #29 adds those rules to AGENTS.md, and the real-table test stays skipped on Windows.

  **Accepted.** The proposal and test map state the applicable rules without citing absent rule numbers. The fake cases remain unguarded, and the real-table smoke test retains its Windows skip.