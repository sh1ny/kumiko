# Proposal

## Why

A unit whose leader exits while the host is stopping it can be recorded as unresolved with `kill-failed`, although nothing is left to kill (issue #30). It showed on macOS CI for PR #29: the Codex row "startup protocol EOF preserves bounded stderr and status after cleanup" found the refused agent unit still in the ledger as `unresolved`, `kill-failed`. The commit under test only moved planning files.

`killProcessGroup` (`packages/process_containment/lib/src/posix_unit.dart`) snapshots the leader, then calls `killpg`. Any error other than `ESRCH` counts as `KillOutcome.failed`. When the leader exits between the snapshot and the signal, the kernel can refuse the signal with another error. macOS is the likely case: a group whose only member is a zombie can answer `EPERM`. The host then reports a failed kill for a unit that is already gone, the workspace becomes *cleanup unresolved*, and new launches against it are refused until the user retries or confirms.

A second cause is possible: `kill` and `killpg` are bound as ordinary FFI calls and `errno` is read in a separate call afterwards, against the package's own rule that a call whose `errno` is reported is a leaf call (`libc.dart`). A VM transition in between can overwrite `errno`, so a real "no such process" can read as another error and become `kill-failed` the same way.

The exact errno macOS returns is inferred from the log and the code, not reproduced. The fix does not depend on it: after any refused signal, the leader is looked at again, and only a leader confirmed exited, or confirmed replaced by another process, stops counting as a failed kill. Anything the host cannot confirm stays a failed kill.

PR #29 waits for this fix before it merges (owner's decision, relayed by Ormy on 2026-11-24: "b: issue + its own fix first; #29 waits").

Milestone: **M2 – Daily-driver workbench (Windows)**, the same footing as #29. A red CI job on unrelated commits works against the exit criterion that main CI builds the desktop and host. This is a bug fix outside the milestone's numbered change list, and it advances no user-verified criterion.

## What Changes

- **A refused signal is checked against the leader again, failing closed.** When `killpg`, or the direct `kill` used before the shim's `setsid`, fails with anything other than `ESRCH`, `killProcessGroup` checks the leader again. Confirmed exited → `leaderGone`; confirmed replaced by another process → `startTimeMismatch`; anything it cannot confirm → `failed`, as today.
- **The direct `kill` fallback checks the leader first, and only for live units.** When the group does not exist (`ESRCH`), the direct signal goes only to a pid confirmed to still be the leader, and only for a unit this host started in its current run; a unit recorded by an earlier host, possibly before a reboot, is never signalled by its pid alone. A window between that check and the signal remains.
- **Error codes are read from the call that set them.** The process table's native calls on the kill path whose `errno` is read (`kill`, `killpg`, `proc_pidinfo`) become leaf calls, with the `errno` accessor bound before them.
- **A deterministic unit test** drives `killProcessGroup`'s decision through an injected seam for its process reads and signals. It covers each refusal and fallback path with each answer, on every platform, with no real processes and no timing. A POSIX test checks that a signal to a pid no process can hold reports `ESRCH`.
- **Spec:** `host-process-cleanup` states when a refused signal is a failed kill and when the leader may be signalled directly as the leader, with scenarios for each.

No protocol, ledger format or Windows behaviour changes. Callers (`PosixUnit.terminate` and the host's settler) keep their handling of each `KillOutcome`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-process-cleanup`: the requirement "Stopping a unit confirms its processes are gone" states when a refused signal is a failed kill, and when the leader is signalled directly, and gains the scenarios "The leader exits while it is being stopped", "The leader's pid is not confirmed before a direct signal", "The leader has no process group yet", "A recorded unit's leader has no process group" and "A refused signal whose leader is not confirmed gone".

## Impact

- Code: `packages/process_containment/lib/src/posix_unit.dart` (`killProcessGroup` and an internal seam for its snapshot and signal calls); `packages/process_containment/lib/src/posix_process_table.dart` (leaf bindings).
- Tests: a new unit test in `packages/process_containment/test/`. Existing rows in `kill_group_test.dart` and `spawn_test.dart` stay.
- Users: a unit whose leader exited at the moment it was stopped no longer records a kill failure for that leader, once the host confirms the exit; an exit it cannot confirm still counts as a failed kill. Whether the unit is cleaned is still decided as before, by confirmed termination and the marker scan.
- Out of scope: reporting the errno in the `kill-failed` reason; any change to the marker scan or to Windows job termination; and, by the owner's decision (S4), the existing gaps the design review found outside the new paths, now issue #31: the macOS reader reading an unknown as gone, a placeholder start time recorded as a unit's identity, and a host-level seam for deterministic host tests of the kill path.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting. The owner chose the scope through Ormy: its own change before #29 merges (S2), then, after two REVISE rounds, "Narrowed round 3, follow-up issue for the rest" (S4); then, after the third, "Round 4: add the error-code fix, fix wording, re-review, ship" (S5); then, after round 5, "Take round 5: approve, or fix its findings and go on without round 6" (S6).

### S1: Recheck the leader after any refused signal, not only after EPERM

- **Choice:** Any `killpg` or `kill` error other than `ESRCH` leads to a recheck of the leader; only a confirmed absence or a confirmed reuse of its pid by another process downgrades the failure.
- **Rejected:** Treating `EPERM` as `leaderGone` outright. That would hide a real permission refusal on a live process, and it rests on the unreproduced errno.
- **Reversal cost:** low
- **Important:** yes. Chosen on weak evidence: the macOS errno is inferred, not reproduced.
- **Chosen by:** agent

### S2: Its own change, before PR #29 merges

- **Choice:** Fix the race in this change; PR #29 waits.
- **Rejected:** Folding the fix into #29 (mixes a containment fix into a test-timing change); rerunning the macOS job (rule 8 of #28).
- **Reversal cost:** low
- **Important:** yes. It changes behaviour users see (a workspace no longer blocked).
- **Chosen by:** user

### S3: A spec scenario, not skip_specs

- **Choice:** Add scenarios to `host-process-cleanup`, since the user-visible outcome (cleaned versus unresolved) changes.
- **Rejected:** `skip_specs: true`: the fix changes what the product reports, not only how it is tested.
- **Reversal cost:** low
- **Important:** yes. It changes a contract.
- **Chosen by:** agent

### S4: Narrow the change to its new paths; the reader and host-test gaps go to #31

- **Choice:** The new rechecks fail closed on their own: they confirm absence with a no-signal probe and never treat a start time of 0 as identity. The existing reader, the first check and the host test seam stay as they are, tracked in issue #31.
- **Rejected:** Fixing the macOS reader, recorded placeholders and host fault plumbing here: it widens a bug fix into a containment rework and needs more review rounds while #29 waits.
- **Reversal cost:** low
- **Important:** yes. It leaves known gaps open (deliberate gaps C5 and C6 in design.md).
- **Chosen by:** user

### S5: Add the error-code fix after the third REVISE

- **Choice:** Round 4 adds leaf bindings for the process table's errno-reporting calls, fixes the spec wording and the review's moderate findings, and goes back to review.
- **Rejected:** Shrinking to the error-code fix and the guarded fallback, moving the recheck to #31; stopping and merging #29 with macOS red.
- **Reversal cost:** low
- **Important:** yes. The error-code fix may be the actual cause of #30.
- **Chosen by:** user

### S6: Go on after round 5 without a sixth review

- **Choice:** Fix round 5's findings and go on to tasks and apply; the design review is recorded as `USER_OVERRIDE`, and the pre-ship review still runs.
- **Rejected:** A sixth design review round.
- **Reversal cost:** low
- **Important:** yes. The round-5 fixes are not design-reviewed.
- **Chosen by:** user
