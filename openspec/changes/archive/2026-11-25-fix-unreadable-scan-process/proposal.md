# Proposal

## Why

Ending a unit on Linux or macOS can leave it *cleanup unresolved* for no reason (issue #40). The marker scan reads the environment of every recent process of the current user. A process that is in the middle of exiting can no longer have its environment read:
- Linux answers EACCES (reproduced).
- macOS presumably answers EINVAL from `KERN_PROCARGS2`, because the task is no longer IPC-active. This is inferred from the XNU source and not observed (design A1).

The scan then rechecks the process. An exiting process is not yet a zombie, so the recheck finds it "still there", and the scan fails with `scan-unreadable:<pid>`. The unit is unresolved and its workspace refuses new launches. Separately, on Linux the listing of `/proc` itself fails (`scan-unlistable`) when an entry vanishes while it is being listed.

This is a race in the product: any process of the user that exits during a scan can trigger it. It turns CI red at random:
- **macOS on PR #29 at b378c49:** `close failed: scan-unreadable:10938`, plus three `Codex version probe cleanup unresolved` rows.
- **macOS and Ubuntu on main at 71f2db3:** `no agent/exited`, `version probe cleanup unresolved`.

It blocks PR #29. The owner asked for it to be fixed first, as its own change, as with #18.

Reproduced on Linux (WSL), with the real scan in a loop while shell loops start and end processes. In 7031 scans over 60 s:
- 56 scans were `scan-unlistable`. `Directory('/proc').listSync` failed with ENOENT on `/proc/<n>`.
- 1 scan was `scan-unreadable`. The process was `bash` in state R with vsize and RSS 0, and its stat flags held `PF_EXITING`.

This change serves no roadmap exit criterion directly. It keeps the cleanup guarantee of M2 (Daily-driver workbench) honest under load and unblocks PRs.

## What Changes

- **Exit check.** The process table answers whether a process has *fully exited*, on kernel evidence only:
  - **Linux:** its `/proc` entry is gone (trusted only when `/proc` is not mounted with `hidepid`), its pid was reused, or one read of its status shows a zombie counted as exactly one thread.
  - **macOS:** the existing non-waiting `proc_pidinfo` read shows another start time, or the pid is absent from one complete process listing. No errno is relied on, and no call can wait. A zombie its parent has not reaped is therefore not confirmed.
- **Scan.** A process in the scan population that the first pass cannot read, and whose full exit is not confirmed, is *pending*:
  - The scan settles (at most 1 s, as today after a kill), waiting for each pending process's exit to be confirmed, and then runs its second pass. A process whose exit was confirmed at the first recheck also makes the second pass run, so the second listing always comes after the exit evidence.
  - A pending process whose exit is confirmed during the settle contributes no failure. Every process it started is in the second listing.
  - One whose exit is not confirmed by then is `scan-unreadable`, as today, even if it disappears later.
  - A null or zombie snapshot is no longer taken as proof of exit on its own.
  - The second pass only verifies, as today: it kills nothing.
  - **Known limit, by the owner's decision:** a process that starts a child after the final listing, and vanishes before it is read, is left to OS-provided grouping (ADR 0001, #9).
- **Listing.** On Linux, a `/proc` listing that fails only because an entry vanished is listed again, at most 8 times. Otherwise the table is unlistable, as today.
- **Unchanged:** the two-pass bound, the 1 s settle, the 10 s pass timeout, the result's reasons and the snapshots.
- **Tests:**
  - The scan with a fake table, driven by call counts, not time.
  - The exit evidence decoded by pure functions on every OS.
  - The listing retry with an injected listing.
  - The real exit check on Linux and macOS.
  - The existing real-table tests stay.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-process-cleanup`: "Stopping a unit confirms its processes are gone":
  - The scenario for a process that exits during the scan: a process that could not be read contributes no failure only when its full exit (or the reuse of its pid) is confirmed before the scan lists the processes again.
  - New scenarios cover a process that exits while the process table is listed, and a listing that cannot be completed.
  - "A live process cannot be inspected": a process that could not be read, and whose exit was not confirmed in time, fails the scan even if it disappears later. The scan names it unless a failure that takes precedence in the scan (`scan-unlistable` or `scan-timeout`) is reported instead, and the unit's reported reason still follows the host's precedence (a termination failure first).

## Impact

- `packages/process_containment/lib/src/process_table.dart`: `ProcessTable.confirmedExits`.
- `packages/process_containment/lib/src/posix_process_table.dart`: `confirmedExits` for Linux and macOS, and the Linux listing retry.
- `packages/process_containment/lib/src/marker_scan.dart`: pending pids, the settle over them, and the verification-only second pass.
- `packages/host/lib/src/settler.dart`: the wrapping table forwards `confirmedExits`.
- `packages/process_containment/lib/src/process_table.dart`: the `ProcessSnapshot.zombie` doc comment is corrected (a Linux zombie is the leader's state).
- `openspec/architecture.md`: the shutdown row says its limits are checked between synchronous reads.
- Tests in `packages/process_containment/test/`, and the fake table.
- No protocol, ledger, snapshot or Windows change. The kill guard, spawn and unit listing keep their zombie handling.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting (`decision_making: autonomous` in openspec/specwright.yaml)

### S1: Fix the scan's handling of processes that exit during it, not the tests

- **Choice:** A process the first pass cannot read is cleared only by a confirmed full exit seen before the second listing (at its first recheck or during the settle). Otherwise it stays unreadable.
- **Rejected:**
  - **The kernel's exit-in-progress flag (design round 1).** It is not proof that the process starts nothing more.
  - **Clearing a process that is gone or readable on the second pass (round 2).** It could have started a child after the second listing.
  - **Retrying until a deadline.** That is a new real-time budget.
  - **Serialising the tests.** The race is in the product.
  - **Treating every unreadable process as gone.** That would give up the fail-closed guarantee.
- **Reversal cost:** low
- **Important:** yes. It decides when an unreadable process fails the cleanup guarantee.
- **Chosen by:** user. The owner chose option A after the two REVISE rounds were escalated, and accepted the design after round 4 with its fixes.

### S2: Fix the vanished-entry listing failure in the same change

- **Choice:** Fix it here. It has the same cause (a process exiting during the scan), the same symptom (cleanup unresolved) and the same reproduction.
- **Rejected:** A separate issue. It would leave CI red after this change.
- **Reversal cost:** low
- **Important:** no. It is a small, local fix.
- **Chosen by:** agent
