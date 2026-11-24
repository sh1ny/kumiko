## MODIFIED Requirements

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
- **THEN** the leader check neither reads nor signals the recorded pid, the marker scan still runs for the unit's marker, and the unit is cleaned only if its exit is observed in time and the scan leaves no marked process; when the exit is not observed in time, or the scan reports a marked survivor, an unreadable process or a timeout, it is unresolved. A scan that throws instead of reporting is out of scope here (issue #35)

#### Scenario: A later host reconciles such a unit
- **WHEN** a later host reconciles a row recorded with the start time that matches no process
- **THEN** the leader check neither reads nor signals the recorded pid, the marker scan still runs for the unit's marker, and the row is cleaned only if the scan ends every marked process; a marked survivor or an unfinished scan leaves it unresolved

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
- **THEN** that unit stays *cleanup unresolved* with its reason, the marker scan still ends whatever carries its marker, and the workspace stays in the list until the user confirms

#### Scenario: Retry still fails
- **WHEN** the user chooses Retry cleanup while a marked process is still alive and cannot be terminated
- **THEN** the workspace stays *cleanup unresolved* with the updated reason; a unit whose identity could not be confirmed at spawn keeps its pid-bearing reason

#### Scenario: User confirms the processes are gone
- **WHEN** the user chooses Confirm processes are gone for a workspace
- **THEN** its units leave the ledger, the host diagnostic log records a user confirmation for each unit id, the workspace leaves the list, and launches against it are accepted

#### Scenario: Confirmation races a new failure
- **WHEN** the user confirms a workspace while a retry for it is still running
- **THEN** the host refuses the confirmation with the reason `retry-in-progress` and the list keeps the workspace until the retry ends
