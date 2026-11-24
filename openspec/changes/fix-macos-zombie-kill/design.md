# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | no | One function in `process_containment` changes, plus how its native calls are bound; its two callers keep their handling of each outcome (`packages/process_containment/lib/src/posix_unit.dart:122-145`, `packages/host/lib/src/settler.dart:198-216`). |
| T2 State (persistent state, caches, 3+ state machine) | no | No stored state. The ledger records the same reasons as before; only which outcome a refused signal maps to changes. |
| T3 Concurrency (background work, workers/isolates, async, retries) | yes | The defect is a race between the unit's leader exiting and the host signalling it (`posix_unit.dart:61-69`), and the error code of a native call can be overwritten before it is read (D4). |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | no | `killProcessGroup`'s signature and `KillOutcome` stay as they are (`posix_unit.dart:40-58`). The new seam is internal to the package (D2). The native bindings keep their Dart signatures (D4). |
| T5 Volume (grows without a fixed bound) | no | A fixed number of reads per call (Resource Bounds). |
| T6 Risk (security, money, data loss, unrecoverable user data) | no | Every answer the host cannot confirm keeps today's `failed` outcome, and the direct signal needs a confirmed leader (D1, D3). |

TIER: FULL

## Context

- `killProcessGroup` snapshots the leader and returns `failed`, with no signal, when the read is refused; `leaderGone` for a `null` or zombie snapshot; `startTimeMismatch` for another start time; then calls `killpg` (`packages/process_containment/lib/src/posix_unit.dart:58-67`). It compares start times only, not owners: an equal start time reaches `killpg` (`posix_unit.dart:65-67`).
- A `killpg` error other than `ESRCH` returns `failed` at once (`posix_unit.dart:69`). On `ESRCH` it signals the pid directly with no further check (`posix_unit.dart:73`); a direct error other than `ESRCH` is `failed`, and `ESRCH` is `leaderGone` (`posix_unit.dart:74-75`). The group is missing when the shim has not yet called `setsid` (`packages/process_containment/lib/src/unit_exec.dart:72-76`).
- The snapshot and the signals are separate system calls, so the leader can exit, and its pid be reused, between them. Nothing re-reads the leader after the first snapshot.
- **Error codes.** `posixKill` and `posixKillpg` call the native function, then read `errno` in a second call (`packages/process_containment/lib/src/posix_process_table.dart:24-29`). `kill`, `killpg` and `proc_pidinfo` are bound without `isLeaf` (`posix_process_table.dart:14-15`, `posix_process_table.dart:190-191`). The package's own rule is that a call whose `errno` is reported is a leaf call, so no VM transition runs before the read, and that the `errno` accessor is bound before the call (`packages/process_containment/lib/src/libc.dart:16-20`). The shim binds the accessor first (`unit_exec.dart:41`) and binds the calls its comment names as leaf calls; these bindings do neither. A transition between the call and the read can overwrite `errno`, so a real `ESRCH` can read as another error, which `killProcessGroup` turns into `failed`. This is a second candidate cause for issue #30, not reproduced.
- Two more calls in the table read `errno` without a leaf binding, and neither feeds the kill path: `proc_listpids` only puts it in an error message (`posix_process_table.dart:215-230`), and the environment read's `sysctl` maps it to `ProcessGone` or `ProcessReadDenied` (`posix_process_table.dart:325-336`, `posix_process_table.dart:352-355`), which the marker scan treats alike: it rechecks the process before counting it gone or unreadable (`marker_scan.dart:144-150`, `marker_scan.dart:164-173`).
- Snapshot readers:
  - Linux: a missing `/proc/<pid>` while reading `stat` and `status` is `null`, any other failure of those two reads throws `ProcessReadDenied`, and a `Z` or `X` state is a zombie (`posix_process_table.dart:96-120`). The start time and the state come from one read of `stat`; the owner comes from a second, separate read of `status`, so the owner and the start time of one snapshot can belong to two processes if the pid is reused between the reads. The start time is the raw tick count since boot from `stat`; the wall-clock `startedAt` is computed from it separately (`posix_process_table.dart:59-70`, `posix_process_table.dart:104-120`). The boot time comes from `/proc/uptime`, read once per table instance outside that catch (`posix_process_table.dart:59-71`).
  - macOS: a full read gives the real start time and the zombie flag (`posix_process_table.dart:264-275`). An empty full answer with `EPERM` or `EACCES` falls back to the short read; an empty answer with any other errno is `null`, which is not proof of absence (`posix_process_table.dart:258-262`, issue #31); a nonempty but short answer throws `ProcessReadDenied` (`posix_process_table.dart:263`). The short read answers the same way: empty with `EPERM` or `EACCES` throws `ProcessReadDenied`, empty with another errno is `null`, short throws `ProcessReadDenied` (`posix_process_table.dart:295-300`). A complete short record throws `ProcessReadDenied` for a process of the current user (`posix_process_table.dart:303`), and for another user's process returns a placeholder start time of 0 (`posix_process_table.dart:304-309`). So the placeholder comes only from a complete short record after a refused full read.
  - So a nonzero start time is a real one, read for the process it describes, on both systems; a start time of 0 is the macOS placeholder. On Linux it identifies a process only within one boot.
- A recorded start time of 0 can come from that placeholder: spawning reads the start time through the same snapshot (`posix_unit.dart:17-25`, `posix_unit.dart:222-238`, `posix_unit.dart:257-259`) and the host records it (`packages/host/lib/src/unit_manager.dart:241`). A live process of another user then matches it at the first check (issue #31).
- **Recorded units.** The ledger keeps a unit's pid and raw start time (`unit_manager.dart:241`, `packages/host/lib/src/ledger.dart:173-179`). Startup reconciliation takes the rows of earlier host instances, with no check that they come from the current boot, and stops each through `_terminateRecorded`, which calls `killProcessGroup` (`ledger.dart:230-239`, `packages/host/lib/src/cleanup_service.dart:56-67`, `settler.dart:145-159`, `settler.dart:195-220`). After a reboot, an unrelated Linux process can hold the same pid with the same tick count. `PosixUnit.terminate` stops only units this host instance started, so in the current boot (`posix_unit.dart:115-146`).
- `kill(pid, 0)` checks that a pid exists without sending a signal (POSIX). `ESRCH` is 3 (`libc.dart:25`).
- Callers:
  - `PosixUnit.terminate` turns `failed` into `TerminationResult.failed('kill-failed')` on the SIGTERM and SIGKILL steps, the reason the CI row found. On the other outcomes it waits, bounded, for the exit to be observed, and may still end in `termination-timeout` (`posix_unit.dart:122-159`).
  - The reconcile path maps `failed` to `kill-failed:<pid>` and the other two to no reason (`settler.dart:198-216`). A unit is cleaned only when it has no termination reason and the marker scan reports no failure (`settler.dart:72-90`, `settler.dart:106-120`). A cleaned unit's ledger row is deleted. Otherwise the row is marked unresolved, except at host shutdown, where only a row already unresolved is rewritten and any other is left for the next host to reconcile (`settler.dart:244-260`).
  - The marker scan signals the marked processes it finds and that are eligible, by their own pid and start time, through `PosixProcessTable.kill`, which also uses `posixKill`; that signal can fail (`marker_scan.dart:65-95`, `marker_scan.dart:131-157`, `posix_process_table.dart:42-53`).
- The host imports the package barrel (`settler.dart:4`), which exports all of `posix_unit.dart` (`packages/process_containment/lib/process_containment.dart:12`).
- ADR 0001 requires matching on pid plus start time, so a reused pid is never killed (`docs/adr/0001-desktop-and-child-execution-host.md:32`).

## Decisions

### D1: After a refused signal, recheck the leader and downgrade the failure only on a confirmed answer

- **Choice:** A *refused* signal is one whose call fails with an error other than `ESRCH`. After a refused `killpg`, or a refused direct `kill`, recheck, sending no signal. First `kill(pid, 0)`; only if it does not answer `ESRCH`, one snapshot:
  - *Confirmed exited*: the probe answers `ESRCH` (no snapshot is read), or the snapshot shows a zombie → `leaderGone`. Whatever process a zombie at the pid is, the leader is not running.
  - *Confirmed replaced*: the snapshot is not a zombie and its start time differs from the recorded one, with neither start time 0 → `startTimeMismatch`.
  - Anything else → `failed`: the same start time, a refused read, a `null` snapshot, or a start time of 0 on either side.
  The checks use only the start time and the state, which one read gives for one process (Linux `stat`, macOS `proc_pidinfo`); they never use the owner, which Linux reads separately. A nonzero start time that differs from the recorded one proves the pid is another process, whoever owns it (ADR 0001).
- **Rejected:** Mapping `EPERM` to `leaderGone` without a recheck, because a real refusal on a live leader would be reported as gone, and the macOS errno is inferred, not reproduced. Also rejected: trusting the snapshot's `null` as absence, because on macOS it also covers failed reads (issue #31). Also rejected: requiring a current-user owner for a confirmation, because on Linux the owner can come from another process than the start time, and a nonzero start time already decides identity. Also rejected: resending the signal, because it adds a loop and a real-time budget where one recheck answers.
- **Reversal cost:** low
- **Important:** yes. Chosen on weak evidence: the errno macOS returns is inferred from the log (A1).
- **Chosen by:** agent

### D2: Test the decision through an internal seam, not with real zombies

- **Choice:** Move the guarded-kill decision into a new internal library in `packages/process_containment/lib/src/`. It takes the snapshot call, `killpg`, `kill` and whether the direct fallback is allowed (D3) as parameters. `killProcessGroup` keeps its signature and calls it, with the fallback disallowed, with one `PosixProcessTable` instance's `snapshot`, so the entry read and every recheck share that instance (on Linux, one boot-time read), and with the real `posixKillpg` and `posixKill`. The package barrel does not export the new library; its unit test imports it directly and scripts each sequence of answers.
- **Note (merge with #18):** main's `killProcessGroup` gained an optional `snapshotForTesting` in #18 (`fix-spawn-exit-race`), and a recorded start time of `startTimeNotRead` (-1) means a leader known to be gone. The signature kept here is main's: `snapshotForTesting` replaces the guard's snapshot read, and the guard returns `leaderGone` for `startTimeNotRead` before any read or signal, for both the recorded-unit and the live-unit entries.
- **Rejected:** A test with a real process that exits between the snapshot and the signal, because the window cannot be held open from a test without a sleep (rule 2 of #28), and the Dart runtime reaps its children, so a zombie cannot be kept on demand (A2). Also rejected: optional parameters on the public `killProcessGroup`, because the host imports it through the barrel (`settler.dart:4`, `process_containment.dart:12`) and a test-only parameter would widen that shared interface.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent

### D3: Only a live unit gets the direct-kill fallback, and only for a confirmed leader

- **Choice:** The direct fallback exists for one case: a unit stopped before its shim reached `setsid`, which only happens to a unit this host instance started moments ago. So only `PosixUnit.terminate` uses it; it calls the internal guarded function with the fallback enabled. The public `killProcessGroup`, whose one caller outside the package is the recorded path, runs it with the fallback disabled. With the fallback disabled, a `killpg` `ESRCH` is rechecked with D1's confirmations and ends in `leaderGone`, `startTimeMismatch` or `failed`, with no direct signal. With the fallback enabled: on `killpg` `ESRCH`, recheck before `kill`, with D1's confirmations. Confirmed exited → `leaderGone`; confirmed replaced → `startTimeMismatch`. *Confirmed leader* (the probe does not answer `ESRCH`, and the snapshot is not a zombie and has the recorded start time, which is not 0) → the direct `kill`:
  - it succeeds → `signalled`;
  - it answers `ESRCH` → `leaderGone` (the pid has no process; with D4 that answer is the call's own);
  - it is refused → D1's recheck decides.
  Anything else → `failed`, with no direct signal. The guard governs only this call's signal to the pid *as the unit's leader*; a marked process that holds the pid is left to the marker scan, which decides whether it is eligible and signals it under its own pid and start time (`marker_scan.dart:65-95`, `marker_scan.dart:131-157`).
- **Rejected:** Keeping the unchecked fallback, because a leader that exits after the first snapshot can have its pid reused by a process that leads no group, so `killpg` gives `ESRCH` and the direct `kill` would hit an unrelated process, against ADR 0001. Also rejected: the fallback on the recorded path, because a recorded row can come from an earlier boot, where a Linux tick count does not identify the process, and a recorded leader that never reached `setsid` is not a case that occurs. Also rejected: recording a boot identity with each unit, because it changes the ledger format (issue #31). Also rejected: dropping the fallback, because a live unit stopped before the shim's `setsid` has no group yet and must still be signalled (`packages/process_containment/test/kill_group_test.dart:10-20`).
- **Reversal cost:** low
- **Important:** yes. It binds future changes: the ADR 0001 identity guard now covers the fallback too, and a recorded unit is never signalled by pid alone.
- **Chosen by:** agent

### D4: Read each native call's error code from that call alone

- **Choice:** Bind `kill`, `killpg` and `proc_pidinfo` in `posix_process_table.dart` with `isLeaf: true`, and bind the `errno` accessor before any of them can fail: `posixKill` and `posixKillpg` call `errno()` before the native call, and the `PosixProcessTable` constructor calls it once, as the shim does (`unit_exec.dart:41`). The Dart signatures stay as they are. They are expected to be short calls (A4): `kill` and `proc_pidinfo` act on one pid and copy at most one fixed-size record; `killpg` posts a signal to each member of one unit's group, so its work grows with that group's size but it waits on nothing. None calls back into Dart, which a leaf call must not do.
- **Rejected:** Capturing errno in native code (a C shim), because it adds a native build to a package that has none for this path, and the leaf rule already gives the guarantee the package relies on elsewhere. Also rejected: fixing only `kill` and `killpg`, because the macOS reader decides between gone, foreign and refused from the `proc_pidinfo` errno (`posix_process_table.dart:258-262`, `posix_process_table.dart:295-299`), and the recheck reads through it. Also rejected: making `proc_listpids` and the environment `sysctl` leaf calls here, because their answers grow with the process count or the environment size, so the short-call premise needs its own macOS check, and neither errno reaches the kill path (Context); they are recorded against issue #31 (C9).
- **Reversal cost:** low
- **Important:** yes. It may be the actual cause of issue #30 (A3), and every errno-based decision in the reader depends on it.
- **Chosen by:** user (owner, round 4: "add the error-code fix")

### Decision summary

| # | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|
| S1 | Which refusals are rechecked | Any error other than `ESRCH`; only confirmed absence or reuse downgrades | Only `EPERM`, mapped to gone outright | low | yes (weak evidence) | agent |
| S2 | Where the fix lands | Its own change; PR #29 waits | Fold into #29; rerun the job | low | yes (changes what users see) | user |
| S3 | Spec or skip_specs | Scenarios in `host-process-cleanup` | `skip_specs: true` | low | yes (contract) | agent |
| S4 | Scope after two REVISE rounds | New paths fail closed; reader, placeholders and host seam to #31 | Fix them all here | low | yes (leaves known gaps) | user |
| S5 | Scope after the third REVISE | Add the error-code fix; fix wording; review again | Shrink further; stop with macOS red | low | yes (may be the cause) | user |
| S6 | After the fifth REVISE | Fix the findings and go on; `USER_OVERRIDE` | A sixth round | low | yes (fixes not re-reviewed) | user |
| D1 | Outcome after a refused signal | Probe first, then one snapshot's start time and state confirm exit or reuse; else `failed` | `EPERM` → gone; trust `null`; require an own-user owner; resend | low | yes (weak evidence) | agent |
| D2 | How it is tested | Internal seam with scripted calls and a fallback switch, one table instance per call | Real zombie race; public optional parameters | low | no | agent |
| D3 | Direct-kill fallback | Live units only, to a confirmed leader; success, `ESRCH` and refusal each defined | Unchecked fallback; fallback on recorded rows; a boot identity in the ledger; no fallback | low | yes (binds future changes) | agent |
| D4 | Error-code capture | Leaf bindings for `kill`, `killpg`, `proc_pidinfo`; `errno` accessor bound first | C shim; only the kill calls; the list and environment calls too | low | yes (may be the cause) | user |

## Assumptions

- **A1:** macOS refuses `killpg` with an error other than `ESRCH` (most likely `EPERM`) when the group's leader has just become a zombie. Not checked because there is no macOS machine here and the race cannot be held open on demand; the CI log shows only the resulting `kill-failed`. Depends on it: none for correctness. D1 and D3 are right whatever the errno.
- **A2:** The Dart runtime reaps exited child processes itself, so a test cannot keep a zombie child to signal. Not checked in the Dart VM source. Depends on it: D2's rejected alternative only.
- **A3:** A non-leaf FFI call can overwrite `errno` on its way back to Dart. Taken from the package's own rule (`libc.dart:16-19`), not reproduced. Depends on it: D4's claim to be a cause; D4 is correct whether or not it is. If neither A1 nor A3 is the cause, the CI row can still fail and issue #30 stays open.
- **A4:** `kill`, `killpg` and `proc_pidinfo` with `PROC_PIDTBSDINFO` or `PROC_PIDT_SHORTBSDINFO` return without waiting on another process or on I/O, so binding them as leaf calls does not hold up the VM's safepoints for long. Not measured. Exercised, not proven, in CI on Linux and macOS: `killpg` on populated groups by the session and escaped-descendant tests (`packages/process_containment/test/spawn_test.dart:57`, `spawn_test.dart:120`), and `proc_pidinfo`'s refused full read and short read by the real-table marker scan, which on macOS reads other users' processes (`packages/process_containment/test/marker_scan_test.dart:165`). The signal-0 test (Test map) checks only error-code capture. Depends on it: D4.

## Carried constraints

- **C1:** `killProcessGroup` sends no signal and returns `failed` when its first read is refused. After a refused signal (any error but `ESRCH`) it returns `failed` unless a recheck confirms the leader exited (`kill(pid, 0)` answers `ESRCH`, or the snapshot shows a zombie) or was replaced (a snapshot with another start time, neither being 0). The new checks use the start time and state only, never the owner. Kind: invariant. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C2:** A refused signal is a failed kill unless the host confirms the leader exited or its pid now belongs to another process; the leader's pid is signalled directly, as the leader, only once confirmed; a confirmed exit removes the kill failure, not the settlement checks that follow. Kind: invariant. Destination: spec: specs/host-process-cleanup/spec.md → Requirement: Stopping a unit confirms its processes are gone
- **C3:** On the new paths (after a refused signal, and before the direct fallback) of one `killProcessGroup` call, no signal is sent without a fresh confirmation and none is resent after a refusal: the only second signal is the direct fallback, to a leader just confirmed. The window starts at the identity read, not when the snapshot returns: on Linux the start time and state come from `stat`, read before `status`, so a pid reused after the `stat` read is not seen. The read and the signal are separate calls, so a window remains. Later termination attempts (the marker scan, Retry cleanup) are separate calls. Kind: invariant. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C4:** The decision's call seam is internal: the package barrel does not export it, and only this package's tests import it. Kind: rejected alternative (public optional parameters). Destination: doc comment: the new seam library's library doc comment in packages/process_containment/lib/src/
- **C5:** The first check keeps today's mapping, gaps included: a `null` snapshot is `leaderGone` though on macOS it can come from an unconfirmed read, and owners are not compared, so a live process of another user whose placeholder start time 0 equals a recorded 0 reaches `killpg` (issue #31). Kind: deliberate gap. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C6:** The `kill-failed` reason does not carry the errno, and no host test scripts the native kill path; both stay as they are (issue #31 for the host seam). Kind: deliberate gap. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C7:** `kill`, `killpg` and `proc_pidinfo` are leaf calls, and the `errno` accessor is bound before any of them can fail. Kind: invariant. Destination: doc comment: packages/process_containment/lib/src/posix_process_table.dart, at the native bindings
- **C8:** One `killProcessGroup` call uses one `PosixProcessTable` instance for its entry read and every recheck, so no recheck reads `/proc/uptime` again. Kind: invariant. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C9:** `proc_listpids` and the environment `sysctl` still read `errno` without a leaf binding; neither reaches the kill path (issue #31). Kind: deliberate gap. Destination: doc comment: packages/process_containment/lib/src/posix_process_table.dart, at the native bindings
- **C10:** Only a unit this host instance started gets the direct fallback; the public `killProcessGroup`, used for recorded units, never signals a pid directly. Kind: invariant. Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup
- **C11:** A Linux start time is a tick count since boot, and recorded rows carry no boot identity, so after a reboot the first check can still reach `killpg` for an unrelated group leader with the same pid and ticks. Kind: deliberate gap (issue #31). Destination: doc comment: packages/process_containment/lib/src/posix_unit.dart killProcessGroup

## Test map

- **The decision (D1, D3):** a unit test of the seam, on every platform. For each path (refused `killpg`; `killpg` `ESRCH` before the direct signal; refused direct `kill`) it scripts each answer: probe `ESRCH` (and asserts no snapshot is read after it); a zombie; another start time; the same start time; a recorded or observed start time of 0; a refused read; `null` without the probe's `ESRCH`. It also scripts a confirmed leader whose direct `kill` succeeds (`signalled`), one whose direct `kill` answers `ESRCH` (`leaderGone`), and one whose direct `kill` is refused and whose recheck is inconclusive (`failed`). With the fallback disallowed, it scripts `killpg` `ESRCH` with a snapshot of the recorded start time (the equal-tick, other-boot case) and expects `failed` with no direct signal. It asserts the outcome and exactly which signals and reads were made.
- **Error-code capture (D4):** a POSIX test calls `posixKill` and `posixKillpg` with signal 0 on a pid above every system's pid limit (`0x7fffffff`), which no process can hold, and expects `ESRCH`. It is deterministic and needs no child process. It shows the binding reports the call's own errno on this run; it cannot prove that no transition ever clobbers it, which is what the leaf binding is for.
- **Host settlement of each outcome:** unchanged code (`posix_unit.dart:122-159`, `settler.dart:72-120`, `settler.dart:198-216`, `settler.dart:244-260`). Deterministic host tests that script the native kill path need a host seam, which the owner deferred to issue #31 (S4).
- **Integration evidence:** the Codex startup EOF row asserts an empty ledger after a refused start (`packages/host/test/it/codex_test.dart:2093-2110`). It does not force the refused-signal branch, so it is evidence for issue #30 on macOS, not a test of the race, and one green run confirms neither A1 nor A3.
- **Existing real-process rows stay:** the pre-`setsid` fallback (`kill_group_test.dart:10-20`), moved to the live-unit entry since the public `killProcessGroup` no longer falls back, and the stale-start-time, signalled and gone-leader checks (`packages/process_containment/test/spawn_test.dart:173-189`).

## Diagrams (FULL)

T3, the race, the recheck and the guarded fallback:

```mermaid
sequenceDiagram
    participant H as Host (killProcessGroup)
    participant K as Kernel
    participant L as Unit leader
    H->>K: snapshot(leader)
    K-->>H: running, start time matches
    L->>K: exits (zombie or gone)
    H->>K: killpg(leader) (leaf call, errno read at once)
    alt refused, not ESRCH
        H->>K: kill(leader, 0); snapshot only if not ESRCH
    else ESRCH (no group)
        H->>K: kill(leader, 0); snapshot only if not ESRCH
        Note over H: live unit only: a confirmed leader gets kill(leader): success = signalled, ESRCH = leaderGone, refusal = recheck. Recorded unit: no direct signal
    end
    alt confirmed exited
        K-->>H: leaderGone
    else confirmed replaced (other start time, neither 0)
        K-->>H: startTimeMismatch
    else not confirmed
        K-->>H: failed (kill-failed), no signal
    end
```

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| The leader's snapshot | `killProcessGroup`, per call | One call | Read again before the direct fallback and after a refused signal, through the same table instance | The OS process table at the moment of the read |
| A native call's error code | The calling thread, per call | Until the next VM transition | Read by the leaf call's wrapper at once | The thread's `errno` |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| Recheck | The read is refused, `null` without the probe's `ESRCH`, or a start time of 0 | Outcome stays `failed`, as today | Yes: the user's Retry cleanup reruns reconciliation | The user, through *cleanup unresolved* with `kill-failed` (outside host shutdown) |
| Leader alive after a refusal | Real refusal | Outcome `failed`, as today | Yes, same | The user, as above |
| `/proc/uptime` on a recheck | Not read again: the instance read it for the entry snapshot | — | — | — |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Reads per `killProcessGroup` call | The first snapshot, then at most two rechecks (before the direct fallback, after a refusal), each one probe and one snapshot | No further read | None added | Unchanged per call |

## Flow & State Gaps (FULL)

- **Leader exits after a recheck saw it alive.** A direct `kill` then answers `ESRCH` → `leaderGone`. A `killpg` refusal → recheck. The window between the last read and the signal remains (C3).
- **Pid reused between a signal and the recheck.** A process with another nonzero start time → `startTimeMismatch`, no signal. On macOS another user's process reads with the placeholder 0 → `failed`, since reuse is not confirmed (D1).
- **Pid reused between the two Linux reads.** The checks do not use the owner from the second read, so mixed evidence cannot confirm a leader. A pid reused after the `stat` read is not seen by that snapshot; the window starts there (C3).
- **A recorded unit after a reboot.** An unrelated process with the same pid and tick count that leads no group: `killpg` answers `ESRCH`, the recorded path sends no direct signal, and the outcome is `failed` (unresolved). One that leads a group still reaches `killpg` at the first check (C11, issue #31).
- **Recorded start time of 0.** No recheck confirms a replacement or a leader against it, so the outcome is `leaderGone` on a probe `ESRCH` or a zombie, else `failed`.
- **A marked descendant holds the former leader's pid.** The guard does not signal it as the leader; it is left to the marker scan.
- **Other group members alive while the leader is gone.** `leaderGone` means the group is reachable only through the marker scan (`posix_unit.dart:44-46`). The scan still runs and decides cleaned or unresolved (`settler.dart:72-90`).

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| Recheck after a refused signal | yes | Without it a gone unit blocks its workspace until the user acts | — |
| No-signal probe for absence | yes | The macOS snapshot's `null` is not proof of absence (issue #31) | The reader distinguishing absence itself (issue #31) |
| Confirmation before the direct fallback | yes | Without it a reused pid can be signalled, against ADR 0001 | — |
| Leaf bindings for `kill`, `killpg`, `proc_pidinfo` | yes | A clobbered errno turns gone into refused, silently | — |
| Leaf bindings for `proc_listpids`, environment `sysctl` | no | Their errno does not reach the kill path (C9) | A scan outcome traced to a clobbered errno |
| Errno in the `kill-failed` reason | no | Diagnosis only (C6) | `kill-failed` still seen for a leader that turned out to be gone |
| Resend the signal | no | The recheck answers directly (C3) | A refusal that a second signal would have passed |

## Risks / Trade-offs

- [The cause is neither the zombie race nor the errno clobbering, so the CI row still fails] → Issue #30 stays open until the row passes on macOS; both fixes are still correct for what they handle.
- [A real refusal on a live leader is masked] → It is not: only a confirmed exit, or a confirmed replacement (another nonzero start time), changes the outcome.
- [On macOS another user's process at a reused pid after a refusal is now unresolved, not gone] → Rare and safe: the user retries or confirms.
- [A leaf call holds up the VM's safepoints while it runs] → These calls are expected not to wait on I/O or another process (A4), and CI exercises them on Linux and macOS; `killpg`'s work grows with one unit's group.
- [A recorded unit whose leader never made its group is no longer signalled directly] → It does not occur in practice (the shim calls `setsid` at once); if it did, the unit is unresolved and the user retries or confirms.
- [The first check keeps its gaps] → Deliberate (C5, S4), tracked in issue #31.

## ADRs

- **In force, constraining this change:** ADR 0001 (pid plus start time guard; cleaned versus unresolved).
- **To record during apply:** none.
