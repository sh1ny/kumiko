## MODIFIED Requirements

### Requirement: Every launch is recorded before it starts
Before it spawns a unit, the host SHALL durably record a pending ledger entry with the unit id, kind, target workspace and containment id. It SHALL add the pid and process start time once the spawn returns. A spawn whose pending write fails SHALL not start. A unit that exited before its start time could be read SHALL still launch: the ledger SHALL record its pid with a start time that matches no process, so every pid and start time check treats its leader as gone and never signals a process that later reuses the pid.

#### Scenario: Unit launch records the ledger
- **WHEN** the host launches a unit
- **THEN** the ledger held a pending entry for it before the process existed, and holds its pid and start time once the launch is reported

#### Scenario: Pending write fails
- **WHEN** the store write of the pending entry fails
- **THEN** no process is started and the launch is refused with a store-error reason

#### Scenario: Unit exits before its start time is read
- **WHEN** on Linux or macOS a unit's process is gone, and the OS confirms no process has its pid, before the host reads its start time
- **THEN** the launch succeeds and the unit's exit code reaches the caller, and the start time the host records for it is one that matches no process

#### Scenario: A recorded leader that exited before its start time was read
- **WHEN** a unit's recorded start time is the one that matches no process, and the unit is ended or a later host reconciles its row
- **THEN** no signal is sent to the recorded pid and the pid is not inspected, the marker scan still runs for the unit's marker, and the unit is cleaned unless that scan leaves a marked process or cannot finish

#### Scenario: Start time read refused
- **WHEN** on Linux or macOS the read of a new unit's start time is refused, or finds no process while the OS still reports one at the pid
- **THEN** the launch fails as it does today: the spawn kills the process it started and reports an error, and no exited unit is returned
