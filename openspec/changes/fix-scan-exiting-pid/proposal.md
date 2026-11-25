# Proposal

## Why

The marker scan can leave a unit *cleanup unresolved* because an unrelated process happened to be exiting during the scan's second pass (issue #42). The second pass reads every recent process of the current user, as the first does. When it cannot read a process, it checks once, at that read, whether the process has fully exited. A process caught mid-exit is not confirmed by that one check, so the scan fails with `scan-unreadable:<pid>`, although the process is gone a moment later. The first pass already absorbs the same race: its unread pids get a settle of up to 1 s (issue #40). The second pass has none.

Evidence:
- **CI, macOS, PR #29 at 91638f5:** `reconcile_test` "killed host's units cleaned or unresolved" left both units `unresolved` with `scan-unreadable:5985`, a pid that belonged to neither unit. This test always has matches (the killed units), so it always runs the second pass. Main's last run was green.
- **WSL, full host suite:** `codex_tools_test` "Codex receives its bridge configuration" failed with `Codex version probe cleanup unresolved`. The log does not name the pid.
- **WSL reproduction:** the real scan ran in a loop for 60 s while shells, python3 and dart processes started and exited. 11 of 3570 scans were `scan-unreadable`. All 11 pids were refused in the second pass after the first pass had left another pid unread. Each was a python3 process mid-exit (state R with its environment refused, or already a zombie or gone a moment later), and each got exactly one exit check.

It blocks PR #29: the project's test rules forbid rerunning a red test to get green (the Windows CI rules that #29 adds to AGENTS.md). It does not serve a roadmap exit criterion directly. It keeps the cleanup guarantee of M2 (Daily-driver workbench) honest on a busy machine.

## What Changes

- **Scan.** A process that the second pass cannot read, and whose full exit is not confirmed at that read, is pending. After the second pass, the scan settles with a 1 s clock that stops new sweeps, the same bound and the same exit evidence as the settle after the first pass. A pending process whose full exit (or the reuse of its pid) is confirmed in that settle contributes no failure. One still unconfirmed is `scan-unreadable`, as today.
- **Unchanged:** the two-pass bound; the second pass still kills nothing, and a marked process in it is still a survivor; the first pass's pending rule and its settle; the exit evidence (`confirmedExits`); the reasons and their precedence; a pass that times out or a listing that fails still ends the scan with that reason, with no settle.
- **Known limit, widened by the owner's decision:** a process that pass 2 could not read and whose exit is confirmed only during the final settle may have started a child after the final listing; the scan does not see that child. This is the race #40 left to OS-provided grouping (ADR 0001, #9) for a pid that vanishes between the final listing and its read. The window used to end at that pid's failed read; it now ends at its confirmation in the final settle, which comes after the rest of the second pass. The settle's 1 s clock stops new sweeps but does not cap the window: a sweep already started can finish after it.
- **Tests:** the scan with the fake table, driven by call counts. #40's pre-ship F2 test, which expected a pid that exits after its failed second-pass read to fail the scan, now expects a clean scan. The real scan diagnostic reruns on WSL as evidence, not as a gate.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-process-cleanup`: "Stopping a unit confirms its processes are gone": on the final pass, a process the scan cannot read is cleared when its full exit or the reuse of its pid is confirmed before the scan's final settle ends, not only at its read. The owner's limit on descendants is widened to children started before that confirmation. The scenario "A live process cannot be inspected" changes to match, and a new scenario covers a process that exits during the second pass.

## Impact

- `packages/process_containment/lib/src/marker_scan.dart`: the settle after the second pass; the `runMarkerScan` doc comment (#40's C1, C2 and C7 move with the decision).
- `packages/process_containment/test/marker_scan_test.dart`: new and changed fake-table tests.
- `openspec/architecture.md`: the shutdown row counts a settle after each scan pass, whose 1 s clock stops new sweeps; a sweep already started and its 10 ms delay can finish after it.
- No change to the process table, the host's settler, the protocol, the ledger or Windows.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting (`decision_making: autonomous` in openspec/specwright.yaml)

### S1: Give the second pass the same settle as the first

- **Choice:** After the second pass, a pid it could not read gets up to 1 s for its full exit to be confirmed, as pass 1's pending pids do. This amends #40's D1 (the second pass only verifies, with one check per pid at its read) and D6 (the race after the final listing).
- **Rejected:**
  - **A bounded third pass** after that settle, to look for children of the pids confirmed in it. It breaks the two-pass bound (#40's D9), and the third pass has the same race with nothing after it.
  - **Keeping #40's rule.** `reconcile_test` stays flaky on a busy machine, #29 stays blocked, and a real cleanup can be left unresolved by any process exiting at the wrong moment.
  - **Serialising the tests.** The race is in the product, not only in CI.
- **Reversal cost:** low. It is local to `runMarkerScan`.
- **Important:** yes. It changes what users see (when a unit is called cleaned) and widens a documented limit of the cleanup guarantee.
- **Chosen by:** user. The owner chose option A, "same 1 s wait as pass 1", and asked for it to be recorded as amending D1 and D6.
