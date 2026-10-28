# Spec Delta

## Purpose

Make every process the host starts provably cleaned up, even after an abrupt host exit, and refuse new work against a workspace whose old processes cannot be shown gone (ADR 0001, D7).

## ADDED Requirements

### Requirement: Every launch is recorded before it starts
Before it spawns a unit, the host SHALL durably record a pending ledger entry with the unit id, kind, target workspace and containment id. It SHALL add the pid and process start time once the spawn returns. A spawn whose pending write fails SHALL not start.

#### Scenario: Unit launch records the ledger
- **WHEN** the host launches a unit
- **THEN** the ledger held a pending entry for it before the process existed, and holds its pid and start time once the launch is reported

#### Scenario: Pending write fails
- **WHEN** the store write of the pending entry fails
- **THEN** no process is started and the launch is refused with a store-error reason

### Requirement: Units are contained and marked
Each unit SHALL run as its own containment unit: on Windows in its own job nested in the job the desktop holds, created without breakaway; on POSIX as the leader of a new session. Each unit process SHALL carry `KUMIKO_UNIT=<containment id>` in its environment, inherited by its descendants.

#### Scenario: Descendants stay attributable
- **WHEN** a test unit starts a child, and a grandchild that starts its own POSIX session
- **THEN** all three processes carry the unit's marker, and on Windows all three are in the unit's job

#### Scenario: Breakaway refused on Windows
- **WHEN** a process inside a unit on Windows starts a child with breakaway from its job requested
- **THEN** the child start fails or the child stays inside the unit's job

### Requirement: Stopping a unit confirms its processes are gone
When the host ends a unit, it SHALL terminate its containment. On POSIX it SHALL also terminate every process of the current user that carries the unit's marker. The unit is *cleaned* only when termination is confirmed and no marked process remains. Otherwise it is *unresolved*.

#### Scenario: Unit with an escaped descendant is ended
- **WHEN** the host ends a test unit whose descendant left the unit's POSIX session
- **THEN** the descendant is terminated through the marker scan and the unit is cleaned

#### Scenario: A process exits during the marker scan
- **WHEN** a process in the scan population exits, or its pid is reused, between being listed and having its environment read
- **THEN** the scan counts it as gone, and the unit is cleaned if no marked process remains

#### Scenario: A live process cannot be inspected
- **WHEN** a process in the scan population is still running with the same start time but its environment cannot be read
- **THEN** the unit is unresolved with a reason naming that process

#### Scenario: A marked process survives
- **WHEN** a marked process cannot be terminated (the kill fails, or it is still alive after the termination timeout)
- **THEN** the unit is unresolved with that reason, and its target workspace is *cleanup unresolved*

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
The desktop SHALL list each *cleanup unresolved* workspace with its unresolved units and reasons, stating that *cleaned* means no recorded or marked process remains. Retry SHALL rerun reconciliation for those units. Confirmation SHALL clear the workspace on the user's word.

#### Scenario: Many unresolved units
- **WHEN** reconciliation leaves more unresolved workspaces and units than fit in one control message
- **THEN** the desktop shows the unresolved count, can page through every workspace and every unit, and Retry cleanup and Confirm processes are gone each act on all units of the workspace

#### Scenario: Retry succeeds
- **WHEN** the user chooses Retry cleanup after the surviving processes have exited
- **THEN** the units become cleaned, the workspace leaves the list, and launches against it are accepted

#### Scenario: Retry still fails
- **WHEN** the user chooses Retry cleanup while a marked process is still alive and cannot be terminated
- **THEN** the workspace stays *cleanup unresolved* with the updated reason

#### Scenario: User confirms the processes are gone
- **WHEN** the user chooses Confirm processes are gone for a workspace
- **THEN** its units leave the ledger, the host diagnostic log records a user confirmation for each unit id, the workspace leaves the list, and launches against it are accepted

#### Scenario: Confirmation races a new failure
- **WHEN** the user confirms a workspace while a retry for it is still running
- **THEN** the host refuses the confirmation with the reason `retry-in-progress` and the list keeps the workspace until the retry ends
