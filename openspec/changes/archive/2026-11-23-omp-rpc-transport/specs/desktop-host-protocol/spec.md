# Spec Delta

## ADDED Requirements

### Requirement: OMP sessions require a compatible peer

OMP start SHALL require the `agent` and `omp` capabilities from both peers. Without them OMP start SHALL be refused before spawn with the missing capability named, while Claude, Codex and terminals remain usable. OMP sessions SHALL use only the shared agent methods and events. Source: ADR 0002 additive capability rule.

#### Scenario: Compatible peers

- **WHEN** both peers advertise agent and omp and the user starts an OMP profile

- **THEN** the start proceeds subject to the OMP runtime gates, and its state, events and results arrive through the shared agent channel and control messages

#### Scenario: Older desktop

- **WHEN** a desktop that lacks the omp capability asks the host to start an OMP profile

- **THEN** the start is refused before any OMP process or probe runs, naming the missing capability, and Claude and Codex starts on that connection are unaffected

#### Scenario: Older host

- **WHEN** the host does not advertise the omp capability

- **THEN** the desktop shows OMP launch disabled with the missing capability named and sends no OMP start
