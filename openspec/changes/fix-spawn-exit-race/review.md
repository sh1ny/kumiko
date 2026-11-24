# Review

## Metadata

- **Round:** 4
- **Prior round:** REVISE. The owner requested all six fixes and left the shim’s status-descriptor failure in #33.
- **Reviewer:** Cross-model CLI (OMP, GPT-6.2-sol)
- **Reviewed:** Round-3 review; revised proposal, design, and spec delta; current cleanup spec; architecture and ADR 0001; cited containment and host source ranges; `spawn_test.dart`, `pty_test.dart`, host ledger and reconciliation tests, and the Dart unit-test skill.
- **Verification limits:** The available tools could not run `git ls-files`, verify the checkout against `cf73389`, or overwrite `review.md`. This is the replacement text; the file was not changed. The PR #29 test rules were not available for direct verification.

## Findings

### Critical (blocking)

1. **D1 can discard the only record of a live, unconfirmed leader.** On macOS, `snapshot` can return `null` on an unclassified read failure (`posix_process_table.dart:251–263,288–299`). D1 correctly refuses to signal when the probe does not prove absence, but then relies on a marker scan that uses the same snapshot and silently skips `null` *before reading the environment* (`marker_scan.dart:129–149`). If that read failure persists, the marked leader can survive, the scan can report clean, and `_settleFailedSpawn` deletes the pending row (`marker_scan.dart:92–94`; `unit_manager.dart:330–341`). The workspace then accepts new execution even though the old leader was never confirmed gone, contrary to ADR 0001. PTY error precedence must not erase this cleanup uncertainty: it can change the outward error, not the evidence needed to delete the row.

### Moderate

2. **The delta still overstates what settlement and reporting guarantee.** The recorded-leader scenario says the marker scan decides the outcome, but live termination can separately return `termination-timeout` while awaiting exit notification, and its reason takes precedence (`posix_unit.dart:122–153`; `settler.dart:64–88`). The generic ledger scenario still asserts row retention at reporting, though natural settlement can delete it (`unit_manager.dart:241–264,412–419`; `settler.dart:237–250`). The refusal scenario promises the kill or scan ends the process; the implementation only attempts termination and can leave cleanup unresolved. The new `status-read` failure is excluded from the success scenario but has no scenario asserting its own failure and cleanup behavior.

3. **D4 still cannot prove the new PTY behavior.** The existing suite never emits a status-stream error, so it cannot catch the original error-as-EOF or double-completion behavior (`posix_unit.dart:243–250`). The reaped `exec` test records only a null snapshot; under D3, the same `SpawnFailed('exec')` follows whether the probe proves absence or not. Require the test to observe the actual absence decision. Also register cleanup for failed test spawns before invoking them: `spawn_test.dart` registers a unit only after spawn returns, so a hook timeout can fail the test and close the master without ending a live fixture whose identity was never read.

4. **The durable `-1` test has no deterministic observation point.** D4’s forcing hooks are on `spawnPosixUnit`, but the test host reaches it through `UnitManager._spawn` without forwarding them (`unit_manager.dart:298–307`). The existing crash fault fires before `markRunning`; the running-write fault prevents the write; normal exit can remove the row before an external reader sees it (`unit_manager.dart:231–264`). A seeded row proves consumption, not that a real launch committed the sentinel. Specify how the host test forces the gone result and observes the committed PID and `'-1'` before settlement can delete the row.

5. **Two source claims misstate the PTY failure boundary.** Design Context excludes `SpawnFailed` from the host’s marker scan, but only `ProcessException` bypasses it when a row exists (`unit_manager.dart:216–230,330–341`). D3 also says descriptor duplication is the *only* way the shim exits before exec without reporting; `_statusFail` exits after a zero or non-`EINTR` write failure, including one before any bytes were written (`unit_exec.dart:101–113`). These distinctions matter when deciding whether the caller gets a launch failure and whether cleanup was confirmed. Keep #33 deferred, but describe empty EOF as ambiguous regardless of why the report was absent. Update the spawn and `SpawnFailed` comments to distinguish local cleanup from host settlement.

6. **The no-join rule for successful spawns has no carried destination.** The mechanism ledger rejects awaiting `exitCode` inside spawn, but C1–C7 do not carry that rule. Moving the test-only wait into production could prevent a running terminal from opening or keep a piped caller from acquiring the endpoints it needs to drain output. Carry the rule to the `spawnPosixUnit` doc comment.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Preserve unresolved leader identity through failed-spawn settlement. A clean scan that skipped an ambiguous snapshot must not authorize row deletion. Keep the no-signal rule and add a regression scenario and automated test for a still-live leader the scan cannot inspect.
2. State the durable-write ordering without promising row retention. Separate leader termination from scan results, specify the unresolved outcomes, and add an assertable PTY status-read failure scenario.
3. Exercise status read error followed by stream close, verify the proved-gone branch in the reported-`exec` test, and make failed test-spawn cleanup independent of a returned unit.
4. Specify deterministic host-level forcing and observation for the actual committed PID/`'-1'` write. Keep seeded reconciliation coverage separate.
5. Correct the failed-spawn routing and empty-EOF claims, align the API comments, and carry the no-join invariant to one destination.

CHANGES_APPLIED: n/a

## Rebuttals

- Round-3 findings 1 and 2: the revision removes the raw signal after an ambiguous null snapshot and adopts the leaf/prebound-errno convention. Finding 1 above concerns the subsequent ledger decision, not the probe.
- Round-3 finding 3: D3 now separates read error from EOF and specifies single completion and precedence. The missing automated check remains open. The owner’s #33 disposition stands.
- Round-3 finding 4: the fast-exit scenario now describes a write before reporting and excludes PTY handshake failures; descendant attribution is marker-based. The generic ledger scenario and live-settlement wording still need correction.
- Round-3 finding 5: the revised hooks, POSIX skips, and cleanup-triggering deadline are useful. The PTY error and durable-write assertions still need deterministic paths. No `tasks.md` exists yet; the final task map was not reviewed.
- Round-3 finding 6: C1–C7 each name one destination. The additional missing invariant is finding 6 above.
- **Owner escalation:** Resolve the failed-spawn settlement contract before implementation. Skipping the raw PID signal is necessary, but it does not authorize clearing the workspace gate when the leader remains unconfirmed.