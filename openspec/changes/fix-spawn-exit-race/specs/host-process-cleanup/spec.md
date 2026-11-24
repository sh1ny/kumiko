## MODIFIED Requirements

### Requirement: Every launch is recorded before it starts
Before it spawns a unit, the host SHALL durably record a pending ledger entry with the unit id, kind, target workspace and containment id. It SHALL durably write the pid and process start time once the spawn returns and before it reports the launch. A spawn whose pending write fails SHALL not start. A unit that exited before its start time could be read SHALL still launch, recorded with a start time that matches no process. Every leader check SHALL treat that start time as a leader known to be gone, without reading or signalling the recorded pid. A spawn that can neither read the start time nor prove the process gone SHALL fail, SHALL NOT signal the pid, and SHALL leave its row unresolved.

#### Scenario: Unit launch records the ledger
- **WHEN** the host launches a unit
- **THEN** the ledger held a pending entry for it before the process existed, and its pid and start time were durably written before the launch was reported

#### Scenario: Pending write fails
- **WHEN** the store write of the pending entry fails
- **THEN** no process is started and the launch is refused with a store-error reason

#### Scenario: Unit exits before its start time is read
- **WHEN** on Linux or macOS a unit's process is gone before the host reads its start time, the OS confirms that no process has its pid, and the spawn has no other failure (no PTY status timeout, status read error or reported setup failure)
- **THEN** the launch succeeds, the unit's exit code reaches the caller, and before the launch is reported the ledger durably holds the unit's pid with the start time that matches no process

#### Scenario: A recorded leader that exited before its start time was read
- **WHEN** a unit's recorded start time is the one that matches no process, and the unit is ended or a later host reconciles its row
- **THEN** the leader check neither reads nor signals the recorded pid and treats the leader as gone. The marker scan still runs for the unit's marker, and the unit is cleaned only if the leader's exit is observed and the scan leaves no marked process; a termination timeout, a marked survivor or an unfinished scan leaves it unresolved

#### Scenario: Start time read refused
- **WHEN** on Linux or macOS the read of a new unit's start time is refused
- **THEN** the launch fails, no exited unit is returned, and the spawn kills the process it started, as it does today

#### Scenario: Unit identity cannot be confirmed
- **WHEN** on Linux or macOS the read of a new unit's start time finds no process while the OS still reports a process at its pid
- **THEN** the launch fails, no signal is sent to that pid, the host runs the marker scan for the unit's marker, and the unit's row is left unresolved whatever the scan finds, so the workspace stays gated until the user retries or confirms

#### Scenario: PTY status pipe read error
- **WHEN** on Linux or macOS the host's read of a new PTY unit's status pipe fails
- **THEN** the launch fails with the `status-read` stage, the unit is settled as for any failed PTY spawn, and no unit is returned
