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
- **WHEN** on Linux or macOS a unit exits, and its process is gone, before the host reads its start time
- **THEN** the launch succeeds and reports the unit's exit code, the ledger holds its pid with a start time that matches no process, and ending the unit signals no process while the marker scan still covers its descendants

#### Scenario: Start time read refused
- **WHEN** on Linux or macOS the read of a new unit's start time is refused while its process still exists
- **THEN** the launch fails as before, and the unit is not left running untracked
