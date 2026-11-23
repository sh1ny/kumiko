# Spec Delta

## MODIFIED Requirements

### Requirement: Activity and draft requests are bounded
`terminal/activity` SHALL name at most 64 terminals and be answered within the activity deadline; ids past the bound SHALL be refused `invalid-params`. A draft's encoded JSON string contents, UTF-8 and escaping counted, SHALL be at most 256 KiB, so a draft always fits a control message; a larger `agent/draftSave` SHALL be refused `draft-too-large`, and one past the total draft bound `draft-cap`. Under saturated output `terminal/activity` SHALL stay answered within the control-latency bound, and an `agent/draftSave`, whose answer waits for a durable commit, within the draft deadline. Source: ADR 0002, ADR 0014, issue #25.

#### Scenario: Too many terminals
- **WHEN** the desktop sends `terminal/activity` naming 65 terminals
- **THEN** the host refuses it `invalid-params` and reads no process table

#### Scenario: Oversized draft
- **WHEN** the desktop sends `agent/draftSave` whose text encodes to one byte over 256 KiB of JSON string contents
- **THEN** the host refuses it `draft-too-large` and the stored draft is unchanged

#### Scenario: Unknown session
- **WHEN** the desktop sends `agent/draftSave` for a session id with no saved record
- **THEN** the host refuses it `unknown-session` and stores nothing

#### Scenario: Draft save under saturated output
- **WHEN** terminal A streams output continuously, session B's event channel has no credit, and the desktop saves session C's draft
- **THEN** the save is acknowledged with its revision within the draft deadline, and terminal A's output keeps arriving while it commits
