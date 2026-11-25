# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | no | Test support only: one new constant file under `packages/process_containment/test/support/`; no `lib/` change |
| T2 State (persistent state, caches, 3+ state machine) | no | No state is added; the waits read the reader's existing text and end-of-output flag (`packages/process_containment/test/support/pty_session.dart:52-57`) |
| T3 Concurrency (background work, workers/isolates, async, retries) | no | No new concurrent work. The reader isolate (`pty_session.dart:34`) and the waiter list are unchanged; only the length of existing awaits and what happens at their expiry change |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | no | `PtyReader` and `PtySession` are test support used only by three test files in this package (`pty_test.dart`, `pty_windows_test.dart`, `unit_processes_test.dart`) |
| T5 Volume (grows without a fixed bound) | no | No collection or transfer changes |
| T6 Risk (security, money, data loss, unrecoverable user data) | no | Tests only |

TIER: LIGHT

## Context

Why the change is needed is in proposal.md. The waits it changes:

- `PtyReader.waitFor` completes when its test holds for the text read so far, fails at once when output ends first, and otherwise fails after `timeout`, 20 s by default (`packages/process_containment/test/support/pty_session.dart:60-87`). `waitForText` passes 20 s too (`pty_session.dart:89-93`). No caller passes its own budget: every call in `pty_test.dart`, `pty_windows_test.dart` and `unit_processes_test.dart` uses the default (for example `unit_processes_test.dart:62`, `pty_test.dart:91-94`).
- `PtySession.closeConsole` waits 15 s for the console closer (`pty_session.dart:140-145`).
- `PtySession.dispose` terminates the unit, closes the console, then waits 15 s for the end of output and maps an expiry to nothing: it then skips closing the read handle and goes on (`pty_session.dart:148-158`).
- `unit_processes_test.dart`'s `settle` polls `readUnitProcesses` every 100 ms for 15 s and then fails naming the state it saw (`packages/process_containment/test/unit_processes_test.dart:30-48`).
- Three tests wait for the end of output with an explicit 15 s: `pty_test.dart:121`, `pty_test.dart:151`, `pty_windows_test.dart:146`.
- Each of the three files sets its own test timeout: `unit_processes_test.dart:1` (3 min), `pty_test.dart:1` and `pty_windows_test.dart:2` (5 min). Two files already use a 2-minute hang guard as a local constant (`pty_test.dart:232`, `spawn_test.dart:199`).

## Decisions

### D1: One shared 2-minute hang guard for the PTY waits

- **Choice:** A new `test/support/hang_guard.dart` holds `const hangGuard = Duration(minutes: 2)`, with a doc comment saying it only stops a hung test and that its expiry is never an outcome. `PtyReader.waitFor` and `waitForText` lose their `timeout` parameter and wait for their text under `hangGuard`. `closeConsole`, the three explicit `reader.done` waits and `settle` use it too. Expiry fails with what was awaited and the output or state so far, as the existing messages do. 2 minutes is below each file's test timeout (3 or 5 minutes), the outer hang guard, so a hung wait usually reports its own message first; when a test's earlier steps already used most of that timeout, the runner's timeout, which names the test, ends it instead.
- **Rejected:** Dropping the per-wait limits and relying only on each file's `@Timeout`, because a hung wait would then fail with the runner's generic timeout, without saying what it waited for (rule 6). Raising each budget per platform (for example 60 s on Windows), because that is still a race against a slow runner (rule 3).
- **Reversal cost:** low. Test support only.
- **Important:** no. Test only.
- **Chosen by:** agent

### D2: `dispose` fails loudly when output does not end

- **Choice:** `dispose` waits for the end of output under `hangGuard`. If it does not end, `dispose` still closes the write handle and the Windows unit, leaves the read handle open (the reader isolate may still be blocked reading it), and then fails naming the unit and that output did not end.
- **Rejected:** Keeping the silent skip, because rule 4 forbids mapping a guard's expiry to a value, and the skip hides a reader that never ends. Closing the read handle anyway, because the reader isolate may be blocked in a read on it.
- **Reversal cost:** low
- **Important:** no. Test only.
- **Chosen by:** agent

### D3: `settle` stays a poll

- **Choice:** `settle` keeps polling every 100 ms until its condition holds, under `hangGuard`, and keeps its failure message naming the leader and the other processes it saw.
- **Rejected:** Waiting on an event, because `readUnitProcesses` reads the job or process table and has no change event to wait on. A poll that fails loudly naming what it waited for is allowed (rule 6).
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### Decision summary

| # | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|
| S1 | Scope | The PTY session waits, their explicit `reader.done` callers and `settle` | Every short budget in the package's tests (#28) | low | no | agent |
| S2 | Specs | `skip_specs: true` | A spec delta | low | no | agent |
| D1 | Wait limit | One shared 2-minute `hangGuard`; `waitFor` loses its `timeout` parameter | Only the file `@Timeout`; per-platform budgets | low | no | agent |
| D2 | `dispose` without end of output | Close what is safe, then fail | Silent skip; closing the read handle | low | no | agent |
| D3 | `settle` | Poll under `hangGuard`, fail loudly | An event wait (none exists) | low | no | agent |

## Assumptions

- **A1:** In every current PTY test, output ends within 2 minutes after `dispose` terminates the unit and closes the console. Not checked: the current `dispose` skips silently when output has not ended within 15 s (`pty_session.dart:151-154`), so a test where it never ends still passes today and its log says nothing. Depends on it: D2, checked in apply by running the three test files locally and on CI on all three OSes; a test that breaks it fails in teardown, naming its unit.

## Carried constraints

- **C1:** A wait in `process_containment`'s PTY test support waits for its event under `hangGuard`, never under a short budget that also has to cover a process start, and its expiry fails naming what it waited for. Kind: invariant. Destination: `doc comment: packages/process_containment/test/support/hang_guard.dart hangGuard`
