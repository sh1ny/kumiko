# Proposal

## Why

`build (windows-latest)` failed on PR #43 in `packages/process_containment/test/unit_processes_test.dart`, on a commit that changed no code (issue #44). The test "an idle PowerShell unit lists only its shell; the console host is not in the unit job" starts `powershell.exe` in a pseudo-console, types `echo READY` and waits for `READY`. The wait gave up after 20 s with an empty terminal: PowerShell had not drawn even its prompt yet. The same test passed on the previous head with the same code.

The 20 s is the default budget of `PtyReader.waitFor` in `test/support/pty_session.dart`, which every PTY test in the package uses. That budget has to cover a cold start of PowerShell, cmd or bash on a loaded runner as well as the output being waited for. The same shape is in the other `PtySession` waits (closing the console and draining the reader, 15 s each) and in the 15 s `settle` poll of `unit_processes_test.dart`. These break the Windows CI test rules in `AGENTS.md` ("Tests that run in Windows CI", added by #29 from #28): rule 3, a real budget that also has to cover startup or I/O, and rule 4, real time only as a generous hang guard whose expiry is never the outcome. `PtySession.dispose` also maps an expired drain to "skip closing the handle", which rule 4 forbids.

Milestone: **M2 – Daily-driver workbench (Windows)**, exit criterion "Main CI builds the Windows desktop with bundled host…". A Windows CI job that fails on unrelated commits works against that criterion. This is a small fix outside the milestone's numbered change list. It advances no user-verified criterion.

## What Changes

- `test/support/pty_session.dart`: `PtyReader.waitFor` and `waitForText`, `PtySession.closeConsole` and `PtySession.dispose` wait for their event (the text, the console closer, the end of output) under a shared generous hang guard instead of 15–20 s budgets. A wait that runs out fails and names what it waited for and the output so far; `dispose` no longer skips silently when the reader has not ended.
- `test/unit_processes_test.dart`: the `settle` poll keeps polling until its condition holds, under the same hang guard, and still fails naming the state it saw.
- `test/pty_test.dart` and `test/pty_windows_test.dart`: the explicit `reader.done.timeout(15 s)` waits use the hang guard.
- No library code changes. No test loses an assertion.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. Test-only: no requirement changes, so the change sets `skip_specs: true`.

## Impact

- Tests: `packages/process_containment/test/support/pty_session.dart`, `unit_processes_test.dart`, `pty_test.dart`, `pty_windows_test.dart`, and one new support file for the shared hang guard.
- No `lib/` code, protocol, host or desktop change.
- A hung PTY wait now fails after minutes instead of 15–20 s. Each affected test file's `@Timeout` (3 min in `unit_processes_test.dart`, 5 min in `pty_test.dart` and `pty_windows_test.dart`) stays the outer limit.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Scope is the PTY session waits and the `settle` poll

- **Choice:** Fix the waits that `PtySession` and `PtyReader` own, their explicit `reader.done` callers, and `unit_processes_test.dart`'s `settle`, which shares the failing test's file and startup exposure. This is what issue #44 asks for.
- **Rejected:** Fixing every short budget in `process_containment`'s tests (`waitForLines`, the pipe and pipe-server tests, the spawn tests, the `pty_windows_test.dart` polls and its "Ctrl+C within 5 s" and "closer completes within 5 s" bounds). They are #28's audit items; several are elapsed-time assertions that need their own design, and one change for all of them would be large (a past large change needed 15+ pre-ship rounds).
- **Reversal cost:** low. Test only.
- **Important:** no. Test only; no contract or behaviour change.
- **Chosen by:** agent

### S2: No spec change

- **Choice:** `skip_specs: true`. The tests check the same behaviour; only how long they wait before declaring a hang changes.
- **Rejected:** A spec delta. No requirement mentions these test budgets.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent
