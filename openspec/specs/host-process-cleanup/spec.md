# host-process-cleanup Specification

## Purpose

Make every process the host starts provably cleaned up, even after an abrupt host exit, and refuse new work against a workspace whose old processes cannot be shown gone (ADR 0001, D7).

## Requirements

### Requirement: Every launch is recorded before it starts
Before it spawns a unit, the host SHALL durably record a pending ledger entry with the unit id, kind, target workspace and containment id. It SHALL durably write the pid and process start time once the spawn returns and before it reports the launch. A spawn whose pending write fails SHALL not start. On Linux and macOS, when a unit's start time cannot be read because the OS confirms that no process has its pid, and the spawn has no other failure, the unit SHALL still launch, recorded with a start time that matches no process; every leader check SHALL treat that start time as a leader known to be gone, without reading or signalling the recorded pid. When the read is refused, the spawn SHALL fail and attempt to kill the process it started, as it does today. When the read finds no process but the OS does not confirm that no process has the pid, the spawn SHALL fail without signalling by that pid, SHALL report its own spawn error even if the host's later cleanup scan fails, and the host SHALL leave the unit's row unresolved, with the pid in its reason, until the user confirms it.

#### Scenario: Unit launch records the ledger
- **WHEN** the host launches a unit
- **THEN** the ledger held a pending entry for it before the process existed, and its pid and start time were durably written before the launch was reported

#### Scenario: Pending write fails
- **WHEN** the store write of the pending entry fails
- **THEN** no process is started and the launch is refused with a store-error reason

#### Scenario: Unit exits before its start time is read
- **WHEN** on Linux or macOS a unit's process is gone before the host reads its start time, the OS confirms that no process has its pid, and the spawn has no other failure (no PTY status timeout, status read error or reported setup failure)
- **THEN** the launch succeeds, the unit's exit code reaches the caller, and before the launch is reported the ledger durably holds the unit's pid with the start time that matches no process

#### Scenario: A running unit whose leader exited before its start time was read is ended
- **WHEN** the host ends a running unit recorded with the start time that matches no process
- **THEN** the leader check neither reads nor signals the recorded pid, the marker scan still runs for the unit's marker, and the unit is cleaned only if its exit is observed in time and the scan leaves no marked process; when the exit is not observed in time, or the scan reports a marked survivor, a process table it could not list, an unreadable process or a timeout, it is unresolved. A scan that throws instead of reporting is out of scope here (issue #35)

#### Scenario: A later host reconciles such a unit
- **WHEN** a later host reconciles a row recorded with the start time that matches no process
- **THEN** the leader check neither reads nor signals the recorded pid, the marker scan still runs for the unit's marker, and the row is cleaned only if the scan ends every marked process; a scan that reports a marked survivor, a process table it could not list, an unreadable process or a timeout leaves it unresolved, and so does a scan that throws (its reason is then `reconcile-failed`)

#### Scenario: Start time read refused
- **WHEN** on Linux or macOS the read of a new unit's start time is refused
- **THEN** the launch fails, no exited unit is returned, and the spawn attempts to kill the process it started, as it does today; the host settles the row through its failed-spawn marker scan

#### Scenario: Unit identity cannot be confirmed
- **WHEN** on Linux or macOS the read of a new unit's start time finds no process and the OS does not confirm that no process has its pid, whatever other failure the spawn also reports
- **THEN** the launch fails with the spawn's own error, which the terminal API reports through its existing error mapping, no signal is sent by that pid, the unit's row is unresolved with the pid in its reason before the marker scan for the unit's marker runs, and a new launch in that workspace is refused while the scan runs, after it, and if it fails, until the user confirms

#### Scenario: Unconfirmed unit is retried or confirmed
- **WHEN** the user retries cleanup of a row left unresolved because the unit's identity could not be confirmed, or a later host reconciles it, even if that reconciliation fails
- **THEN** the row stays unresolved with the same pid-bearing reason; only the user's confirmation clears it

#### Scenario: PTY status pipe read error
- **WHEN** on Linux or macOS the host's read of a new PTY unit's status pipe fails
- **THEN** the launch fails with the `status-read` stage, the unit is settled as for any failed PTY spawn, and no unit is returned

### Requirement: Units are contained and marked
Each unit SHALL run as its own containment unit: on Windows in its own job nested in the job the desktop holds, created without breakaway; on POSIX as the leader of a new session. Each unit process SHALL carry `KUMIKO_UNIT=<containment id>` in its environment, inherited by its descendants.

#### Scenario: Descendants stay attributable
- **WHEN** a test unit starts a child, and a grandchild that starts its own POSIX session
- **THEN** all three processes carry the unit's marker, and on Windows all three are in the unit's job

#### Scenario: Breakaway refused on Windows
- **WHEN** a process inside a unit on Windows starts a child with breakaway from its job requested
- **THEN** the child start fails or the child stays inside the unit's job

### Requirement: Stopping a unit confirms its processes are gone
When the host ends a unit, it SHALL terminate its containment. On POSIX it SHALL also terminate every process of the current user that carries the unit's marker. The unit is *cleaned* only when termination is confirmed and no marked process remains. Otherwise it is *unresolved*. When the kernel refuses a signal to the unit's leader, failing it for any reason other than that no such process exists, the host SHALL count it as a failed kill unless it then confirms that the leader has exited, or that the leader's pid now belongs to another process. When the leader has no process group to signal, the host SHALL signal the leader's pid directly, as the unit's leader, only for a unit it started in its current run and only after confirming that the pid still belongs to the leader; a unit recorded by an earlier host is never signalled by its pid alone; a confirmed exit removes the kill failure, not the checks that decide whether the unit is cleaned. A process in the marker scan's population that the scan cannot read SHALL prevent a clean result unless the kernel confirms its full exit, or the reuse of its pid: on the first pass, before the scan lists the processes again; on the final pass, when the scan checks that pid right after it fails to read it. By the owner's decision, on macOS a pid that the scan cannot read is taken as another user's, and so outside the population, when the current user's process listing lacks it and a full listing made right after holds it, even though a process of the current user may have reaped and reused that pid between the two listings. By the owner's decision, a descendant started by a process after the scan's final listing, when that process vanishes before the scan reads it, is outside what the scan verifies and is left to OS-provided process grouping.

#### Scenario: Unit with an escaped descendant is ended
- **WHEN** the host ends a test unit whose descendant left the unit's POSIX session
- **THEN** the descendant is terminated through the marker scan and the unit is cleaned

#### Scenario: A process exits during the marker scan
- **WHEN** a process in the scan population cannot be read on the first pass, and the kernel confirms that it has fully exited (no thread of it remains) or that its pid now belongs to another process, at the recheck or while the scan settles and before it lists the processes again
- **THEN** that process contributes no failure, and the unit is cleaned only if its termination is confirmed, no marked process remains, and no other process is left unreadable

#### Scenario: A process exits while the process table is listed
- **WHEN** a process exits while the host lists the current processes for the marker scan, so that its entry vanishes during the listing, and a later attempt of the bounded listing completes
- **THEN** the scan uses that listing and does not fail for that reason

#### Scenario: The process table cannot be listed
- **WHEN** every attempt of the bounded listing fails because entries vanish, or the listing fails for any other reason
- **THEN** the marker scan fails because the process table could not be listed, and the unit is not cleaned

#### Scenario: The leader exits while it is being stopped
- **WHEN** the unit's leader exits after the host found it running, the kernel refuses the signal to its group, and the host then confirms that the leader has exited
- **THEN** the host records no kill failure for the leader, and the unit is cleaned only if its termination is then confirmed and the marker scan completes with no marked process left

#### Scenario: The leader's pid is not confirmed before a direct signal
- **WHEN** the unit's process group does not exist when the host signals it, and the host cannot confirm that the leader's pid still belongs to the leader
- **THEN** the host does not signal that pid as the unit's leader, and any marked process holding that pid is left to the marker scan

#### Scenario: The leader has no process group yet
- **WHEN** the host stops a unit it started in its current run, the unit's process group does not exist yet, and the host confirms that the leader's pid still belongs to the leader
- **THEN** the host signals the leader directly, and if that signal finds no such process, the host counts the leader as exited rather than as a failed kill

#### Scenario: A recorded unit's leader has no process group
- **WHEN** the host stops a unit recorded by an earlier host, its first check finds the leader alive with the recorded start time, and the signal to the unit's process group answers that no such group exists
- **THEN** the host does not signal the leader's pid directly as the unit's leader (a marked process holding that pid is left to the marker scan), and counts a failed kill unless it confirms that the leader has exited or that its pid belongs to another process

#### Scenario: A live process cannot be inspected
- **WHEN** a process in the scan population cannot be read, and the kernel has not confirmed its full exit or the reuse of its pid before the scan lists the processes again (or, on the second pass, when it is read)
- **THEN** the unit is not cleaned, even if the process disappears later in the scan, and the marker scan's reason names that process unless a reason that takes precedence in the scan (the process table could not be listed, or the scan timed out) is reported instead

#### Scenario: A marked process survives
- **WHEN** a marked process cannot be terminated (the kill fails, or it is still alive after the termination timeout)
- **THEN** the unit is unresolved with that reason, and its target workspace is *cleanup unresolved*

#### Scenario: A refused signal whose leader is not confirmed gone
- **WHEN** the kernel refuses the signal to the unit's leader, and the host cannot then confirm that the leader has exited or that its pid belongs to another process
- **THEN** the unit is not cleaned: it is recorded unresolved with a kill-failed reason and its target workspace is *cleanup unresolved*, unless the host is shutting down, when a unit not yet recorded unresolved is left for the next host to reconcile

### Requirement: The next lock holder reconciles before launching
A host that takes the lock SHALL reconcile every ledger entry left by earlier hosts before it launches anything. It terminates recorded units still alive, matching pid and start time, and on POSIX runs the marker scan. Units it cannot confirm cleaned become unresolved.

#### Scenario: Host killed with units running
- **WHEN** a host is killed while test units with descendants run, and a new host takes the lock
- **THEN** after reconciliation every unit is cleaned or unresolved with a reason, and no launch was accepted before reconciliation finished

#### Scenario: Reused pid is not killed
- **WHEN** a ledger entry's pid now belongs to an unrelated process with a different start time
- **THEN** reconciliation does not signal that process and does not count it as the unit

#### Scenario: Host killed between the pending write and the pid write
- **WHEN** a host is killed after writing a pending entry and before writing its pid
- **THEN** the next host marks that unit unresolved and its workspace *cleanup unresolved*, unless on Windows the desktop job that held it is confirmed terminated or closed, in which case the unit is cleaned

### Requirement: Cleanup unresolved refuses execution against the workspace
While a workspace has an unresolved unit, the host SHALL refuse every new unit launch whose target is that workspace, with a reason naming the unresolved cleanup. Launches against other workspaces SHALL be unaffected.

#### Scenario: Launch against an unresolved workspace
- **WHEN** a launch targets a workspace that is *cleanup unresolved*
- **THEN** the host refuses it with the reason `cleanup-unresolved` and starts no process

#### Scenario: Launch against another workspace
- **WHEN** a launch targets a different workspace while another workspace is *cleanup unresolved*
- **THEN** the launch proceeds normally

#### Scenario: Another path to the same checkout
- **WHEN** a workspace is *cleanup unresolved* and a launch targets the same directory through a symbolic link, a junction or a different letter case on a case-insensitive volume
- **THEN** the host refuses it with the reason `cleanup-unresolved`

#### Scenario: Distinct directories differing only in case
- **WHEN** a workspace is *cleanup unresolved* on a case-sensitive volume and a launch targets a different directory whose path differs from it only in letter case
- **THEN** the launch proceeds normally

#### Scenario: Target cannot be resolved
- **WHEN** a launch targets a directory that does not exist or cannot be resolved to a file identity
- **THEN** the host refuses it with the reason `target-unavailable`, writes no ledger entry, and starts no process

### Requirement: Unresolved cleanup is shown and can be retried or confirmed
The desktop SHALL list each *cleanup unresolved* workspace with its unresolved units and reasons, stating that *cleaned* means no recorded or marked process remains. Retry SHALL rerun reconciliation for those units. A unit whose identity could not be confirmed at spawn SHALL stay unresolved through Retry, keeping its pid-bearing reason, until the user confirms. Confirmation SHALL clear the workspace on the user's word.

#### Scenario: Many unresolved units
- **WHEN** reconciliation leaves more unresolved workspaces and units than fit in one control message
- **THEN** the desktop shows the unresolved count, can page through every workspace and every unit, and Retry cleanup and Confirm processes are gone each act on all units of the workspace

#### Scenario: Retry succeeds
- **WHEN** the user chooses Retry cleanup after the surviving processes have exited, and every unit of the workspace has a recorded leader identity
- **THEN** the units become cleaned, the workspace leaves the list, and launches against it are accepted

#### Scenario: Retry of a unit whose identity was not confirmed at spawn
- **WHEN** the user chooses Retry cleanup for a workspace with a unit whose identity could not be confirmed at spawn
- **THEN** the marker scan still runs for the unit's marker and attempts to end whatever carries it, and whatever the scan finds, that unit stays *cleanup unresolved* with its reason and the workspace stays in the list until the user confirms

#### Scenario: Retry still fails
- **WHEN** the user chooses Retry cleanup while a marked process is still alive and cannot be terminated
- **THEN** the workspace stays *cleanup unresolved* with the updated reason; a unit whose identity could not be confirmed at spawn keeps its pid-bearing reason

#### Scenario: User confirms the processes are gone
- **WHEN** the user chooses Confirm processes are gone for a workspace
- **THEN** its units leave the ledger, the host diagnostic log records a user confirmation for each unit id, the workspace leaves the list, and launches against it are accepted

#### Scenario: Confirmation races a new failure
- **WHEN** the user confirms a workspace while a retry for it is still running
- **THEN** the host refuses the confirmation with the reason `retry-in-progress` and the list keeps the workspace until the retry ends
