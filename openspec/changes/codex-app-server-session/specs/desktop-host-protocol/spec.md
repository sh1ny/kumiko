## ADDED Requirements



### Requirement: Native Codex additions require a compatible peer

Codex start and Continue SHALL require `agent` and `codex` from both peers. Steering, structured questions and attributed child events SHALL additionally require `agent-extensions-v1` from both peers. Without it Codex start/Continue SHALL be refused before spawn, while Claude and terminals remain usable. Source: ADR 0002 additive capability rule.



#### Scenario: Compatible peers

- **WHEN** both peers advertise agent, codex and agent-extensions-v1

- **THEN** Codex methods and attributed events are available subject to runtime claims



#### Scenario: Older desktop

- **WHEN** a desktop lacks agent-extensions-v1

- **THEN** Codex is disabled with the missing capability named and no native requests are hidden or automatically answered



### Requirement: Extended control is sequenced and scoped to the native run

Steering and question answers SHALL identify the Kumiko run and originating native turn or request. Questions and resolutions SHALL travel on priority control, carrying the root and child identity where applicable. Late replies and stale runs SHALL be refused without native writes. Text and options SHALL obey encoded control bounds.



#### Scenario: Answer the current question

- **WHEN** the desktop answers a current question in run R and turn T

- **THEN** exactly its native request receives the answer and sequenced resolution retires its controls



#### Scenario: Prior run sends a late answer

- **WHEN** an answer arrives after Continue has created a replacement run

- **THEN** it is refused as stale and the replacement run receives nothing



### Requirement: Child events retain attribution under bounded delivery

The event channel SHALL support additive root/child/parent identities and child lifecycle events. Child tools SHALL be keyed by child and native item identity, with ordering preserved per native stream. A root summary SHALL remain visible; the full child viewer is deferred. Attribution overflow SHALL be reported as unavailable or incomplete, never silently reassigned.



#### Scenario: Two children use the same tool identifier

- **WHEN** children A and B both report native tool item X

- **THEN** their normalized identities remain distinct and each update changes only its own event



#### Scenario: Attribution capacity is exceeded

- **WHEN** more child identities arrive than the tracked-child bound

- **THEN** the root shows incomplete delegated activity, later control remains serviceable and no extra unbounded child map is retained



### Requirement: Codex control keeps the shared responsiveness contract

Stop, approval replies, question answers and close SHALL use priority control and stay within the existing control acknowledgement bound under saturated terminal output or a stalled transcript consumer. Native operation completion SHALL remain separately observable and SHALL NOT be equated with control acknowledgement.



#### Scenario: Stop while Codex output is stalled

- **WHEN** the Codex transcript consumer has no credit and the user presses Stop

- **THEN** the control acknowledgement arrives within the existing bound and native completion or timeout is reported separately



#### Scenario: Stalled native input

- **WHEN** Codex stdin cannot admit an answer or Stop sequence

- **THEN** control returns busy without reporting the native operation as performed



### Requirement: Active native turn identity reaches the desktop

The host SHALL include the current run and native turn identity in sequenced Codex Running state before offering Steer. Missing or stale identity SHALL disable steering; the desktop SHALL NOT infer it from transcript text.



#### Scenario: Running turn identity published

- **WHEN** a Codex turn is admitted and its identity is known

- **THEN** the sequenced state exposes that run and turn for explicit steering



#### Scenario: Delayed prior-turn state

- **WHEN** the desktop receives a stale Running state for an earlier turn

- **THEN** it ignores that state and cannot steer the completed turn


### Requirement: Delegated activity is reported in sequenced state
The host SHALL publish a bounded delegated-activity summary in sequenced agent state, including active child count, waiting child requests and an incomplete flag. Close, quit and Stop availability SHALL use that control state, independent of transcript credit. An incomplete registry SHALL NOT imply that no child work exists.

#### Scenario: Child starts
- **WHEN** a known child starts work
- **THEN** sequenced state reports active delegated work and the root's close and exit predicates include it

#### Scenario: Child starts with no transcript credit
- **WHEN** the event channel has no credit and a child of an Idle root starts
- **THEN** sequenced state reports active delegated work and closing the pane asks for confirmation
