# Review

## Metadata

- **Round:** 5
- **Prior round:** Rounds 1-4 returned REVISE; the owner narrowed the scope to issue #31 after round 2 and added the error-code fix after round 3; the author revised proposal, spec and design
- **Reviewer:** OMP, fresh-context design reviewer (round 5 findings); user (USER_OVERRIDE) for the verdict
- **Reviewed:** FULL-tier proposal and design; `host-process-cleanup` delta and main spec; architecture and ADR 0001; `dart-add-unit-test`; cited containment, settlement, and test ranges; ledger and reconciliation paths; CI and mise test configuration.
- **Reference limits:** `git ls-files` was unavailable; cited repository paths were checked against the worktree index. The submitted planning artifacts were read as review inputs. The requested “Tests that run in Windows CI” heading is absent from `AGENTS.md`; CI and mise confirm Windows runs the process-containment suite. No external planning store was identified. Issues #28, #30, #31, PR #29, and the reported CI log were not independently verified. No tests ran; this was a design review.

## Findings

### Critical (blocking)

1. **D3 can confirm the wrong Linux leader after a reboot.** The Linux snapshot returns raw `/proc/<pid>/stat` start ticks as `startTime`; it computes a separate wall-clock `startedAt` for the scan (`posix_process_table.dart:59–70,104–120`). The ledger persists the raw value with the PID (`unit_manager.dart:241`; `ledger.dart:173–179`). Startup reconciliation selects earlier instances’ rows without a boot check and passes their PID and start time into `killProcessGroup` (`ledger.dart:230–239`; `cleanup_service.dart:56–67`; `settler.dart:145–159,195–211`). [INFERENCE] After a reboot, an unrelated process can have both the same PID and the same nonzero start tick relative to its own boot. If that process is not a group leader, the entry check passes, `killpg` returns `ESRCH`, and D3’s fresh snapshot also passes. The new fallback directly signals the unrelated process. It was already there before either read; this is not C3’s check-to-signal race or any of the deferred #31 gaps. Require boot-scoped identity evidence before authorizing the **new direct fallback** for a recorded Linux unit. If provenance is unknown, do not send the direct signal. Carry that constraint forward and script the equal-tick, different-boot case.

### Moderate

1. **D4 still treats an unverified leaf-call premise as a guarantee.** A4 says the calls were not measured, but Risk/Trade-offs says they “return at once.” `killpg` targets a process group, not one process (`posix_unit.dart:65–73`; ADR 0001, decision 5). [INFERENCE] Its work can grow with group membership; the proposed signal-0 test targets an absent group and exercises none of that work. Existing successful snapshots also do not demonstrate `proc_pidinfo` failure classification. Keep the list and environment calls out of scope, but substantiate leaf suitability for the selected calls, including populated groups, and map an observable macOS `proc_pidinfo` failure to verification. Do not cite the absent-PID smoke test as proof of either property.

2. **C3 does not identify where the remaining Linux race starts.** D2 still uses the full snapshot. Linux reads the identity-bearing `stat` first, then reads `status` (`posix_process_table.dart:93–120`). [INFERENCE] If the PID is reused between those reads and `status` succeeds, the guard can still return the old leader’s start time and state. This is no longer the round-4 mixed-owner bug, but the disclosed race starts at the `stat` read, not when `snapshot` returns. State that explicitly in C3 and Flow & State Gaps. No atomic POSIX signal operation is required by this finding.

3. **The macOS reader summary still overstates which failures return `null`.** Context cites `posix_process_table.dart:258–262,295–299` for “any other failure” returning `null`, but a positive short record throws `ProcessReadDenied` in both paths (lines 263 and 300). Flow & State Gaps also treats a foreign UID as sufficient for a zero placeholder; that value is produced only by a successful short read after the full read was refused (lines 258–262, 285–309). Correct the descriptions and citations so the test map preserves the distinction between an empty answer, a short record, and a placeholder. No reader behavior change is needed.

### Suggestions

None.

## Verdict

Round 5 returned REVISE. Rounds 1 to 5 all returned REVISE and each was escalated to the owner through Ormy. After round 5 the owner decided, on 2026-11-24:

> "Take round 5: approve, or fix its findings and go on without round 6"

Open findings, fixed in the artifacts after round 5 but not re-reviewed:

- Critical 1 (recorded Linux identity after a reboot): D3 now gives the direct fallback only to a unit this host started in its current run; the public `killProcessGroup` (the recorded path) never signals a pid directly (C10, new scenario "A recorded unit's leader has no process group"). The first check's remaining reboot gap is C11, issue #31.
- Moderate 1 (leaf-call premise): A4 now states the premise as unmeasured, names the CI tests that exercise `killpg` on populated groups and `proc_pidinfo`'s refused and short reads, and the risk line no longer says "return at once".
- Moderate 2 (where the Linux race starts): C3 and Flow & State Gaps say the window starts at the `stat` read.
- Moderate 3 (macOS reader summary): Context separates an empty answer, a short record and the placeholder, with lines 263 and 300 cited.

The pre-ship review still runs on the finished change.

VERDICT: USER_OVERRIDE

Escalate the Linux recorded-identity blocker to the owner before task generation or implementation. Round 5 resolves round 4’s mixed-owner blocker, qualifies the proposal and spec outcomes, short-circuits probe `ESRCH`, restores the marker scan’s eligibility and failure checks, and carries table reuse in C8. The narrower D4 removes the list and environment calls from the leaf-binding change. None of the deferred #31 gaps needs reopening.

## Required Changes

Not applicable for this verdict.

CHANGES_APPLIED: n/a

## Rebuttals

None.