# Spec Delta

## MODIFIED Requirements

### Requirement: Child events retain attribution under bounded delivery

The event channel SHALL support additive root and child identities, a direct parent identity when known, and child lifecycle events. Child tools SHALL be keyed by child and native item identity, with order preserved per native stream. A root summary SHALL remain visible. OMP can open a read-only viewer; the Codex viewer remains deferred. Attribution overflow SHALL be reported as unavailable or incomplete, never silently reassigned.

#### Scenario: Two children use the same tool identifier

- **WHEN** children A and B both report native tool item X
- **THEN** their normalized identities remain distinct and each update changes only its own event

#### Scenario: Attribution capacity is exceeded

- **WHEN** more child identities arrive than the tracked-child bound
- **THEN** the root shows incomplete delegated activity, later control remains serviceable and no extra unbounded child map is retained

#### Scenario: OMP does not supply the direct parent

- **WHEN** the private OMP run supplies a child's identity but not its immediate parent's identity
- **THEN** child-aware peers carry the owning root and child identities, omit the unknown direct parent and do not infer a relationship from text or tool names; the parent chat shows only lifecycle rows for that child

### Requirement: OMP sessions require a compatible peer

OMP start SHALL require the `agent` and `omp` capabilities from both peers. Without them OMP start SHALL be refused before spawn with the missing capability named, while Claude, Codex and terminals remain usable. OMP Continue and child chat views SHALL require the additional `omp-history` capability from both peers. Source: ADR 0002 additive capability rule.

#### Scenario: Compatible peers

- **WHEN** both peers advertise agent and omp and the user starts an OMP profile
- **THEN** the start proceeds subject to the OMP runtime gates, and its state, events and results arrive through the shared agent channel and control messages

#### Scenario: Older desktop

- **WHEN** a desktop that lacks the omp capability asks the host to start an OMP profile
- **THEN** the start is refused before any OMP process or probe runs, naming the missing capability, and Claude and Codex starts on that connection are unaffected

#### Scenario: Older host

- **WHEN** the host does not advertise the omp capability
- **THEN** the desktop shows OMP launch disabled with the missing capability named and sends no OMP start

#### Scenario: A peer lacks the OMP history capability

- **WHEN** both peers advertise agent and omp but one does not advertise omp-history
- **THEN** OMP start and ordinary root controls remain usable, Continue and child chat viewing report unavailable on a desktop that supports them, and the host sends no OMP child event that the older peer cannot decode
- **AND** the host still reports known active child counts or incomplete activity through the existing delegated summary, so the older peer can warn about closing or quitting

## ADDED Requirements

### Requirement: Child history uses a run-scoped read and the parent event channel

The desktop SHALL request OMP child history by an opaque child reference bound to its parent run, never by a native path. History SHALL travel as bounded attributed events on the parent event channel, not as a control payload. The control result SHALL not claim that the history has arrived at the desktop.

#### Scenario: Read one child's history

- **WHEN** the user opens the view for a child on a compatible live root
- **THEN** the host sends the child-specific history or its unavailable reason without including an OMP path in any desktop message

#### Scenario: Request refers to another run

- **WHEN** a child history request is stale, belongs to a different root, or names a child never offered by the host
- **THEN** the host refuses the request without sending a native read or revealing another child's history

#### Scenario: Child transcript has no credit

- **WHEN** the parent event channel has no transcript credit during a child's history read
- **THEN** history waits on the bounded event channel, and the host continues handling control without calling the read delivered or completed on the desktop
