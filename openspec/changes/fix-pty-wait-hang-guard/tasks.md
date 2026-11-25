# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| none (`skip_specs: true`) | none | packages/process_containment/test/pty_test.dart, pty_windows_test.dart, unit_processes_test.dart | every test using `PtySession`, `PtyReader` or `settle` | green |

The change has no spec scenarios. It changes how long the existing tests wait before they declare a hang, not what they assert, so every row starts and stays green. Task 3.1 checks that no wait in scope keeps a short budget.

## 1. Shared hang guard and the PTY session waits (S1, D1, D2)

- [x] 1.1 Add `packages/process_containment/test/support/hang_guard.dart` with `const hangGuard = Duration(minutes: 2)` and the C1 doc comment: it only stops a hung test; a wait under it waits for its event, never a short budget that also covers a process start; its expiry is never an outcome and fails naming what was awaited. Verify: `mise exec -- dart analyze --fatal-infos test/support` in `packages/process_containment` is clean, and the C1 text is in the doc comment.
- [x] 1.2 In `test/support/pty_session.dart`, remove the `timeout` parameter of `PtyReader.waitFor` and `waitForText` and wait under `hangGuard`, keeping the "timed out waiting for …" and "output ended without …" messages with the output so far. `closeConsole` waits for the closer under `hangGuard` and fails naming the console close. Verify: the package analyzes clean (no caller passed `timeout`).
- [x] 1.3 `PtySession.dispose` per D2: wait for the end of output under `hangGuard`; if it ends, close the read handle as now; if not, close the write handle and the Windows unit, leave the read handle open, then fail naming the unit's pid and that output did not end. Verify: the package analyzes clean, and `git diff` shows no `onTimeout: () {}` left in `pty_session.dart`.

## 2. `settle` and the explicit end-of-output waits (S1, D1, D3)

- [x] 2.1 In `test/unit_processes_test.dart`, `settle` polls every 100 ms until its condition holds, under `hangGuard`, and keeps its failure message naming the leader and the other processes. Update its doc comment ("or 15 s pass"). Verify: analyze clean.
- [x] 2.2 Replace the 15 s `reader.done` waits at `pty_test.dart:121`, `pty_test.dart:151` and `pty_windows_test.dart:146` with `hangGuard`. Remove `pty_test.dart`'s local `hangGuard` constant (`:232`) in favour of the shared one; leave `spawn_test.dart`'s alone (out of scope, S1). Verify: analyze clean.

## 3. Integration

- [ ] 3.1 Check the scope is complete: `grep -n "seconds: 1[05]\|seconds: 20" packages/process_containment/test/support/pty_session.dart packages/process_containment/test/unit_processes_test.dart` finds nothing, and the three `reader.done.timeout` lines named in 2.2 use `hangGuard`. Remaining short budgets in `pty_windows_test.dart` (the 20 s and 10 s polls, the 5 s closer and Ctrl+C bounds) are #28's, not this change's.
- [ ] 3.2 Run the three files on Windows: `mise exec -- dart test test/pty_test.dart test/pty_windows_test.dart test/unit_processes_test.dart` in `packages/process_containment`. They pass, and no test fails in `dispose` (A1).
- [ ] 3.3 `mise run check` passes, and `mise run test:host` passes apart from failures already filed against other tests (AGENTS.md: the change touches process containment's tests). The macOS and Linux runs of the PR check A1 on POSIX.

## Workflow follow-up

- Ship through `specwright-pr`; the PR body says "Fixes #44" and names the rules the old waits broke (3, 4 and 6).
