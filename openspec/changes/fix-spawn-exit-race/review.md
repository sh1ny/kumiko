# Review

## Metadata

- **Round:** 2
- **Prior round:** The only blocker was untracked change artifacts. The requester reports those artifacts committed in `c3d6ab1`.
- **Reviewer:** Cross-model CLI (OMP, GPT‑6.2-sol)
- **Reviewed:** Proposal, design, current and delta `host-process-cleanup` specs, architecture, ADR 0001, prior review, repository test rules, Dart unit-test skill, all cited ranges in `posix_unit.dart`, `posix_process_table.dart`, `contained_unit.dart`, `unit_exec.dart`, `windows_unit.dart`, `pty.dart`, `ledger.dart`, `settler.dart`, and `unit_manager.dart`, plus `spawn_test.dart` and `pty_test.dart`.
- **Verification limits:** This harness cannot run `git ls-files` to independently verify index membership and file modes, or replace `review.md` in place. The replacement review is below.

## Findings

### Critical (blocking)

1. **D2’s sentinel can still make a workspace cleanup-unresolved.** `posixIsProcessAlive` returns `true` on `ProcessReadDenied` without comparing the start time; `killProcessGroup` similarly returns `failed` before comparison (`posix_unit.dart:30–36,58–66`). If the PID of a `-1` unit is reused and the replacement cannot be inspected, live termination returns `kill-failed` and restart reconciliation reaches the same failure path (`posix_unit.dart:122–130`, `settler.dart:195–203`). `Settler` retains that failure even when the marker scan is clean (`settler.dart:64–88`). A nonmatching integer is not enough: this case can block new work against the workspace even though the recorded leader is known gone.

2. **D1 relies on a macOS error distinction the implementation does not make.** The main snapshot returns `null` for every nonpositive result except `EPERM`/`EACCES`, not just `ESRCH` or a positively identified empty answer. The fallback repeats that collapse (`posix_process_table.dart:251–263,288–300`). D1 would turn any unclassified query failure returned this way into successful launch of an allegedly exited unit. If the child is still alive, no exit arrives and the sentinel discards its leader identity. Require positive evidence of absence; do not infer it from a catch-all `null`.

3. **D3 can turn a PTY setup failure into a successful launch.** If all `F_DUPFD_CLOEXEC` attempts fail, the shim writes only to stderr and exits before `execve` (`unit_exec.dart:43–53,115–118`). The host drains stderr, so the status pipe is empty. If the shim is already reaped, today’s null-start-time path fails; D3 would return a successful unit with PTY handles for a program that never ran (`posix_unit.dart:244–279`). The stdout error handler can also complete the same future used for EOF. Separately, D1’s claim that refusal always throws `StateError` contradicts the current PTY precedence: timeout and a nonempty status take priority (`posix_unit.dart:273–280`).

### Moderate

4. **The delta’s cleanup assertion conflicts with ADR 0001 when a marked descendant survives.** “Ending the unit signals no process” includes the host’s marker scan, which is required to terminate that descendant. The scenario also says the ledger “holds” the PID without distinguishing the durable write from subsequent settlement, which can delete the row after natural exit (`unit_manager.dart:241–264,412–419`, `settler.dart:237–250`). Specify a durable write before reporting launch, no signal through the recorded leader identity, and a separate observable outcome for marked descendants.

5. **The proposed regressions can pass without exercising the new branch or its failure cases.** The existing plain exit test and PTY success/failure tests do not establish that the snapshot was absent (`spawn_test.dart:111–115`, `pty_test.dart:153–225`). D4 waits for `exitCode` but asserts that this guarantees absence even though A1 explicitly allows PID reuse. The plan also does not exercise a reaped shim that reports failure, the refused-read distinction, or the ledger/reconciliation behavior added to the spec. Bound the hook’s wait and specify cleanup on hook failure: it runs after `Process.start`, outside the catch that closes the PTY master (`posix_unit.dart:197–222`). The cited numbered `AGENTS.md` rules are absent from the checked-out file; use the actual POSIX skip and deadline conventions visible in the tests.

6. **Several remaining citations do not support the claims as written.** `posix_unit.dart:240–241` is after the PTY path’s shared snapshot at line 222; `257–279` omits the parser call at line 280. `unit_manager.dart:216–230` shows the call to failed-spawn settlement, not what it confirms; the implementation at `330–340` can retain an unresolved row. The descendant-cleanup claim also needs `settler.dart:64–88,109–119`: a scan attempts termination but can report an unreadable or surviving process. Remove the uncited “few microseconds” PID-reuse bound; Dart scheduling and the proposed test hook do not impose it.

7. **The carried constraints omit behavior future changes can break.** C1 and C2 do not preserve PTY status precedence, the prohibition on retrying a launch that may already have executed, the pre-snapshot PID-reuse gap, or the obligation to read persisted `-1` rows if the encoding changes. Losing these constraints can hide an exec failure, execute a command twice, overstate PID safety, or strand an old ledger row.

### Suggestions

None.

## Verdict

VERDICT: REVISE

Second consecutive blocking round. Escalated to the requester; the round-1 tracking issue is not the basis for this verdict.

## Required Changes

1. Define `-1` as known leader absence in live termination and restart reconciliation, without inspecting or signalling the recorded PID. Keep the marker scan and its unresolved outcomes independent.
2. Specify and verify which macOS query outcomes prove absence. Keep denied or unclassified reads out of the successful exited-unit path.
3. Preserve PTY failure reporting: report `status-fd` failure on the status pipe, distinguish read errors from EOF, and specify precedence among timeout, reported shim failure, identity refusal, and success. Document any remaining ambiguity of empty EOF.
4. Rewrite the delta scenario to assert the durable write, no recorded-leader signal, and separate descendant termination or unresolved cleanup.
5. Map the then-assertions to automated checks: forced absent-snapshot success on both paths, reaped PTY failure, refused read, and `-1` ledger round-trip and reconciliation. Assert the race precondition, bound the hook, clean up on failure, and skip POSIX-only cases on Windows.
6. Correct the cited ranges and unsupported timing and cleanup claims.
7. Add one destination per missing carried constraint: use the `spawnPosixUnit` contract for PTY status precedence, no retry, and pre-snapshot PID reuse; use the ledger start-time contract for persisted `-1` compatibility.

CHANGES_APPLIED: n/a

## Rebuttals

None.