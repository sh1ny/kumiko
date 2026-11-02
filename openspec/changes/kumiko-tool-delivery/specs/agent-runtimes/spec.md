# Spec Delta

## ADDED Requirements

### Requirement: Kumiko tool delivery is qualified per adapter version
Real qualification of an adapter version SHALL record a `kumiko tool call` item per OS: an authenticated `kumiko_session_info` call that succeeded, or the failure observed. The qualification checker SHALL require that item for every listed adapter version. A version whose tool delivery was observed to fail SHALL be listed with that failure, and sessions on that exact version SHALL report it. Source: ADR 0005 qualification in M1; ADR 0012 decisions 5 to 7.

#### Scenario: Passing tool call recorded
- **WHEN** real qualification runs on an OS, and the adapter's session calls `kumiko_session_info` successfully
- **THEN** the evidence for that version and OS records `kumiko tool call` as `pass`

#### Scenario: Evidence missing the item
- **WHEN** a listed adapter version's evidence for an OS has no `kumiko tool call` result
- **THEN** the checker fails, naming the adapter version, the OS and the missing item

#### Scenario: Recorded failure is reported
- **WHEN** a version's tool delivery is listed as failed with its observed failure, and a session starts with that exact name and version
- **THEN** the session shows Kumiko tools *unavailable* for that version with that failure text, and other versions are not affected

#### Scenario: Failure without its observation
- **WHEN** evidence records `kumiko tool call` as `fail` without the observed failure text
- **THEN** the checker fails, naming the adapter version and OS

#### Scenario: Recorded failure matches evidence
- **WHEN** a version's Windows evidence records `kumiko tool call` as `fail` with an observed failure, and the failure list names that version with the same text, and every other checked item passes
- **THEN** the checker reports **QUALIFIED** and prints the recorded tool delivery failure with adapter, version, OS and text

#### Scenario: Evidence failure without a list entry
- **WHEN** evidence records `kumiko tool call` as `fail` with an observed failure, and the failure list does not name that adapter version
- **THEN** the checker fails, naming the adapter version and OS

#### Scenario: List entry contradicts the evidence
- **WHEN** the failure list names an adapter version whose evidence records `kumiko tool call` as `pass`, or as `fail` with different text
- **THEN** the checker fails, naming the adapter version and OS
