# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | no | One function changes: `runMarkerScan` (`packages/process_containment/lib/src/marker_scan.dart:119-143`). The settle it reuses is already there (`packages/process_containment/lib/src/marker_scan.dart:230-251`) |
| T2 State (persistent state, caches, 3+ state machine) | no | No stored state. The second pass's pending pids already live for one pass (`packages/process_containment/lib/src/marker_scan.dart:165-169`) |
| T3 Concurrency (background work, workers/isolates, async, retries) | yes | The defect is a race with processes that exit while the second pass reads them, and the fix adds a bounded wait |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | no | `ProcessTable` and `MarkerScanResult` keep their shape. The host's `_scanFailure` reads `listed`, `timedOut`, `unreadablePid` and the survivors in `remaining` that carry the row's marker (`packages/host/lib/src/settler.dart:136-147`) |
| T5 Volume (grows without a fixed bound) | no | The second pass's pending pids are at most the pids of one listing, as in the first pass |
| T6 Risk (security, money, data loss, unrecoverable user data) | no | The change decides when a process the scan could not read fails it. It does not widen what is killed |

TIER: FULL

## Context

The marker scan is #40's design (archived at `openspec/changes/archive/2026-11-25-fix-unreadable-scan-process/design.md`); this change amends its D1 and D6.

- **First pass.** A pid that cannot be read is checked at once with `confirmedExits`. If that does not confirm its full exit, the pid is pending (`packages/process_containment/lib/src/marker_scan.dart:165-169`). Any unread pid or match makes the second pass run (`packages/process_containment/lib/src/marker_scan.dart:132-134`).
- **Settle.** Before the second pass, `_settle` polls `confirmedExits` every 10 ms, starting no new sweep after 1 s, over the killed matches and the pending pids, and returns those still unconfirmed (`packages/process_containment/lib/src/marker_scan.dart:230-251`).
- **Second pass.** It runs the same `_pass`, so an unread pid there gets the same single check at its read and, if unconfirmed, lands in `second.pending` (`packages/process_containment/lib/src/marker_scan.dart:137`, `packages/process_containment/lib/src/marker_scan.dart:165-169`). Nothing waits for it: the result names the first pid of the settle's unconfirmed list, else the first of `second.pending` (`packages/process_containment/lib/src/marker_scan.dart:138-143`).
- **Reasons.** Precedence is unlistable, then timeout, then unreadable, then survivor (`packages/process_containment/lib/src/marker_scan.dart:44-50`). One scan serves every unit being ended or reconciled together (`packages/host/lib/src/settler.dart:99-105`). Per row, the host takes a termination failure first, then unlistable, timeout and unreadable, which apply to every row of the scan, then a survivor carrying that row's marker (`packages/host/lib/src/settler.dart:108-112`, `packages/host/lib/src/settler.dart:136-147`).
- **Clocks.** A pass's 10 s clock starts after its listing (`packages/process_containment/lib/src/marker_scan.dart:154-160`). The settle checks its 1 s clock before each sweep, and a sweep is one synchronous `confirmedExits` call followed by a 10 ms delay (`packages/process_containment/lib/src/marker_scan.dart:241-248`). On macOS, `confirmedExits` makes its own complete process listing (`packages/process_containment/lib/src/posix_process_table.dart:512-523`).
- **Shutdown.** `shutdown` awaits `endUnits` with `Future.timeout` and the deadline it is given. The timeout stops the waiting; it neither interrupts a running sweep nor cancels `endUnits`, which can still apply its outcome after the deadline (`packages/host/lib/src/unit_manager.dart:469-470, 502-529`). A unit with no outcome recorded keeps its ledger row for the next host. The architecture's shutdown row budgets two scan passes of at most 10 s and does not mention the settle (`openspec/architecture.md:204`).
- **Tests.** #40's pre-ship F2 test expects a pid that pass 2 refuses, and that exits only after a later pid is read, to fail the scan (`packages/process_containment/test/marker_scan_test.dart:396-426`). The test "refusal first seen on the second pass" never confirms its pid (`packages/process_containment/test/marker_scan_test.dart:483-509`).

**Reproduction.** On WSL, the real scan ran in a loop for 60 s with `markers: {'no-such-marker'}` while two shell loops, a `dart --version` loop and a loop of python3 processes with 8 threads each started and exited. A wrapping table logged each failed read and each `confirmedExits` answer.
- 3570 scans: 3559 clean, 11 `scan-unreadable`, none unlistable or timed out.
- Each of the 11 pids had one failed read (environment `ProcessReadDenied`) and exactly one `confirmedExits` call, answered false. So each was refused in the second pass: a pass-1 pending pid would also have been asked in the settle.
- At that one check, `/proc/<pid>/status` showed python3 in state R with 1 thread (7 pids), or the pid was a zombie or gone a moment later (4). All 11 were gone when the scan returned.

## Decisions

### D1: The second pass's unread pids get the same settle as the first pass's

- **Choice:** After the second pass, `runMarkerScan` runs `_settle` again, with no killed matches and the second pass's pending pids. A pid confirmed in it contributes no failure; one still unconfirmed is `scan-unreadable:<pid>`. The bound (1 s), the poll (10 ms) and the evidence (`confirmedExits`) are those of the first settle. The second pass still kills nothing, and a marked process in it is still a survivor. There is no third marker-scan pass. (On macOS each `confirmedExits` sweep makes its own evidence listing, as in the first settle; that is not a pass.)
  - This amends #40's D1, under which the second pass only verifies and an unread pid there gets one check at its read.
- **Why it is enough here:** in the reproduction, every failure was a process mid-exit that one check reached microseconds early. The first settle already absorbs the same race for the first pass.
- **Rejected:**
  - **A bounded third pass** after this settle, to find children of the pids confirmed in it. It breaks the two-pass bound (#40's D9), and the third pass has the same race with nothing after it.
  - **Retrying the read of a refused pid** inside the pass. A process mid-exit cannot have its environment read at all, so a retry would only reach the same exit check later, inside the pass clock.
  - **Keeping #40's rule.** `reconcile_test` stays flaky and #29 blocked.
- **Reversal cost:** low. It is local to `runMarkerScan`.
- **Important:** yes. It changes when users see a unit cleaned.
- **Chosen by:** user (owner: "A: same 1 s wait as pass 1")

### D2: The second settle runs only when it can change the result

- **Choice:** The second settle runs when the second pass listed the processes, did not time out, left at least one pid pending, and the first settle left no pid unconfirmed. Otherwise the result is already decided:
  - an unlistable or timed-out second pass reports that, as today;
  - a pid left unconfirmed by the first settle is reported first, as today, so waiting on the second pass's pids changes nothing.
  
  When the second pass also found a marked survivor, the settle still runs. One scan serves several units, and `scan-unreadable` fails every row of it, while a survivor fails only the row whose marker it carries (`packages/host/lib/src/settler.dart:136-147`). Clearing the unreadable pid lets the other units of the batch be cleaned; the survivor's own unit stays unresolved, now with `marked-survivor`.
  
  `unreadablePid` is chosen as today, extended: the first pid left unconfirmed by the first settle, in listing order; else the first left unconfirmed by the second settle (or, when it did not run, the first pending pid of the second pass), in listing order. The `MarkerScanResult.unreadablePid` doc comment, which describes only the first pass (`packages/process_containment/lib/src/marker_scan.dart:33-35`), is updated with the `runMarkerScan` one.
- **Rejected:** **Always settling after the second pass.** It adds up to 1 s to scans whose answer cannot change.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### D3: The race after the final listing is widened to the end of the final settle

- **Choice:** A pid that the second pass could not read, and whose exit is confirmed only in the second settle, may have started a child after the final listing. The scan does not see that child. Like a pid that vanishes between the final listing and its read, this is left to OS-provided grouping (ADR 0001, #9). The window grows from "final listing to the pid's read" to "final listing to its confirmation": the rest of the second pass, then the settle, whose 1 s clock stops new sweeps without capping the window (D4).
  - This amends #40's D6, which the owner chose, and the spec's limit on descendants.
- **Rejected:** **A third pass** (D1).
- **Reversal cost:** low. #9 replaces the race, not this code.
- **Important:** yes. It widens a documented limit of the cleanup guarantee.
- **Chosen by:** user (owner: "A: same 1 s wait as pass 1", recorded as amending D1 and D6)

### D4: The bounds stay; the architecture row counts the settles

- **Choice:** The numbers stay: two passes whose 10 s clocks start after each pass's listing, each followed by a settle whose 1 s clock stops new sweeps from starting. None of these clocks interrupts synchronous work: a pass can overrun by one pid's reads and exit check, and a settle by one sweep plus its 10 ms delay, as the first settle already can. The second settle adds one more such overrun. The architecture's shutdown row says that each pass's 10 s clock starts after its opening listing; that when a settle runs after a pass, its 1 s clock stops new sweeps, and an admitted sweep and its 10 ms delay can finish after it; and that these clocks are checked between synchronous steps.
  - The shutdown deadline is cooperative: `shutdown` awaits `endUnits` with `Future.timeout`, which neither interrupts a running sweep nor cancels `endUnits`, so an ending that finishes after the deadline can still record its outcome (`packages/host/lib/src/unit_manager.dart:502-529`). That is true today; the second settle adds up to 1 s plus one sweep and its 10 ms delay to the work that can run past it. This change adds no cancellation.
- **Rejected:** **A shorter second settle.** The race it absorbs is the same as the first settle's, and a second bound would be a second number to justify.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### Decision summary

| # | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|
| S1 | Fix the second pass's race | Same settle as the first pass (amends #40 D1, D6) | Third pass; keep #40's rule; serial tests | low | yes | user |
| D1 | Unread pids of the second pass | Pending, then the same 1 s settle; no third marker-scan pass | Third pass; retry the read; keep the rule | low | yes | user |
| D2 | When the second settle runs | Only when it can change the result; `unreadablePid` order: settle 1, then pass 2 | Always | low | no | agent |
| D3 | Race after the final listing | Widened to the end of the final settle, left to OS grouping (#9) | Third pass | low | yes | user |
| D4 | Bounds | Numbers unchanged; clocks and the cooperative shutdown deadline described as they are; architecture row counts both settles | Shorter second settle | low | no | agent |

## Assumptions

- **A1:** The macOS failure (`scan-unreadable:5985` in `reconcile_test`, run 45621716963) is a process refused in the second pass while it exited. Not checked: no macOS machine, and the log names only the pid. Nothing in D1 to D4 depends on it. Depends on it: only the expectation that macOS CI turns green; the macOS CI run of this change and of #29 are the check.
- **A2:** The WSL `codex_tools_test` failure (`Codex version probe cleanup unresolved`) has the same cause. Not checked: its log does not name the pid. Depends on it: nothing.

## Carried constraints

- **C1:** A pid that the second pass cannot read is cleared only by `confirmedExits`, at its read or in the bounded settle after that pass. The second pass kills nothing, a marked process in it is a survivor, and there is no third marker-scan pass. This replaces #40's C2. Kind: invariant. Destination: `doc comment: packages/process_containment/lib/src/marker_scan.dart runMarkerScan`
- **C2:** A child started after the final listing by a pid that vanishes before its read, or whose exit is confirmed only in the final settle, is outside the scan, by the owner's decision (ADR 0001, #9). This replaces #40's C7. Kind: deliberate gap. Destination: `spec: specs/host-process-cleanup/spec.md → Requirement: Stopping a unit confirms its processes are gone`

## Diagrams (FULL)

T3, the scan after this change:

```mermaid
sequenceDiagram
  participant S as Marker scan
  participant T as Process table
  S->>T: pass 1: listPids(), read each pid
  T-->>S: unread pid: confirmedExits at its read, else pending
  S->>T: kill pass-1 matches
  loop settle 1, 1 s clock stops new sweeps, 10 ms poll
    S->>T: confirmedExits(killed + pending)
  end
  S->>T: pass 2: listPids(), read each pid (kills nothing)
  T-->>S: unread pid: confirmedExits at its read, else pending
  opt pass 2 listed, not timed out, pending left, settle 1 left nothing (D2)
    loop settle 2, 1 s clock stops new sweeps, 10 ms poll (new, D1)
      S->>T: confirmedExits(pass-2 pending)
    end
  end
  S->>S: unconfirmed: scan-unreadable:pid; marked in pass 2: survivor
```

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| Pass-2 pending pids (pid, start time when known) | The second `_pass` | One scan | Cleared by a confirmed exit in settle 2; the rest become the unreadable failure | The kernel's process table |
| Pass-1 pending pids | The first `_pass` (unchanged) | One scan | Settle 1 (unchanged) | The kernel's process table |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| Settle 2 | An exit is not confirmed within 1 s | `scan-unreadable:<pid>`, as before this change | Yes, read-only | User: the workspace is *cleanup unresolved* |
| `confirmedExits` in settle 2 | A read fails or is refused | Not confirmed, so the scan fails closed | Yes, read-only | User, through `scan-unreadable:<pid>` |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Pass-2 pending pids | The pids of one listing | — | Settle 2's 1 s clock stops new sweeps; the sweep already running and its 10 ms delay can overrun it | One `confirmedExits` call per sweep over the pending pids, as in settle 1 (#40's bounds table): on macOS that includes one complete process listing. Linear in their count plus one listing |
| Scan duration | Two passes whose 10 s clocks start after their listings, each followed by a settle whose 1 s clock stops new sweeps | `scan-timeout` for a pass; `scan-unreadable` for a settle | Checked between synchronous steps, never inside one: each pass's opening listing runs before its clock starts, and on macOS the evidence listing inside `confirmedExits` runs within a pass iteration or a settle sweep and counts toward its overrun; a pass can overrun by one pid's reads and exit check, a settle by one sweep plus 10 ms. The shutdown deadline does not interrupt any of it (D4) | Unchanged per pass; one more settle and its overrun |

## Flow & State Gaps (FULL)

- **A pid exits during the second pass and is confirmed in settle 2.** Clean for that pid (D1). A child it started after the final listing is not seen (D3).
- **A pid refused in pass 2 is never confirmed within 1 s** (for example, a macOS zombie its parent does not reap). `scan-unreadable`, as today.
- **Settle 1 left a pid unconfirmed.** It is reported; settle 2 does not run (D2).
- **Pass 2 times out or cannot list.** That reason is reported; settle 2 does not run (D2).
- **Pass 2 finds a survivor and an unread pid.** Settle 2 runs. If it confirms the pid, the reason is `marked-survivor`; otherwise `scan-unreadable`, by the existing precedence.
- **Restart mid-scan.** No state outlives the scan. The next host reconciles from the ledger, as today.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| Settle 2 (D1) | yes | Without it, any process exiting during the second pass leaves units unresolved at random. Reproduced: 11 of 3570 scans | — |
| Skipping settle 2 when it cannot change the result (D2) | yes | Without it, every failing scan with a pass-2 unread pid waits 1 s for nothing | — |
| A third pass | no | Breaks the two-pass bound and repeats the race (D1) | A missed child traced to the widened window in D3 |
| Retrying a refused read | no | A process mid-exit cannot be read at all (D1) | A refused read of a live, non-exiting process traced in CI |

## Risks / Trade-offs

- [The widened race window (D3)] → Left to OS grouping (#9), as ADR 0001 leaves descendant containment. It applies only to a process that exits during the second pass after starting a child after the final listing.
- [The macOS cause is inferred (A1)] → D1 does not depend on it. The macOS CI runs are the check.
- [Up to 1 s more per scan that meets a pass-2 race] → Only those scans, and only when the result can change (D2).
- [#40's F2 test changes its expectation] → Its scenario is the one the owner's decision now clears. A new test keeps a never-confirmed pass-2 pid failing the scan.

## ADRs

- **In force, constraining this change:** ADR 0001 (ledger-based crash cleanup with the workspace gate). The change keeps the gate's fail-closed rule: a process the scan cannot read and whose exit is not confirmed in time leaves the unit unresolved.
- **To record during apply:** none. D3 applies ADR 0001's existing limit.

## Test map

| Scenario (host-process-cleanup) | Test | Kind |
|---|---|---|
| A process exits during the second pass | fake table: a match triggers pass 2, where another pid is refused; `confirmedExits` answers false for it on its first and second calls (the check at its read, the first sweep) and true on its third, so only polling clears it; clean; the fake records exactly two pass listings | agent, unit |
| A live process cannot be inspected (pass 2) | the existing "refusal first seen on the second pass" test: never confirmed, `scan-unreadable` | agent, unit (existing) |
| #40's F2 case | the existing test now expects a clean scan, and its call log shows the first check of the pid before the later pid is read and the confirming check after it | agent, unit (changed) |
| D2: settle 1 left a pid unconfirmed | fake table: a pass-1 pid never confirmed and a pass-2 refused pid; `scan-unreadable` names the pass-1 pid; the pass-2 pid is asked exactly once (no settle 2) | agent, unit |
| D2: two pass-2 pids unconfirmed | fake table: pass 2 refuses two pids, neither ever confirmed; `scan-unreadable` names the first in listing order | agent, unit |
| D2: pass 2 timed out | fake table: pass 2 refuses a pid and then expires; `scan-timeout`; that pid is asked exactly once | agent, unit |
| D2: survivor and a confirmed pass-2 pid | fake table: two markers; pass 2 finds a survivor of one and a refused pid confirmed in settle 2; `remaining` names the survivor and `unreadablePid` is null | agent, unit |
| No pass-2 unread pid | fake table: pass 2 reads everything; no `confirmedExits` call after the second listing | agent, unit |
| Real tables (keep real OS coverage) | the existing real-table scan tests stay, skipped on Windows as today (`packages/process_containment/test/marker_scan_test.dart:613-632`) | agent, integration (existing) |

The fake table's answers change on a call count, never after a delay. Tests wait for the event, never for a duration, and assert order and outcome, not elapsed time (the Windows CI test rules that #29 adds to AGENTS.md).

Evidence, not a gate (performance and race rates belong in a benchmark, not the PR gate): the WSL diagnostic reruns on the fixed code for 60 s under the same load, and its counts go in the PR description.
