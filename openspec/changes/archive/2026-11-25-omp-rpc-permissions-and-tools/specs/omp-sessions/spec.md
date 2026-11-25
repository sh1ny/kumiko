# Spec Delta

## MODIFIED Requirements

### Requirement: OMP interactive requests are declined until supported

Kumiko SHALL offer only OMP's exact one-shot approval and denial for recognized native approval requests on an admitted root turn. It SHALL preserve the native approval policy, decline other interactive requests and take no action on display-only requests. Source: direction D6 and D37; owner decision S1.

#### Scenario: Tool approval requested

- **WHEN** OMP sends a recognized approval request on the admitted root turn
- **THEN** the chat shows OMP's supplied approval details and offers only the exact one-shot choice and `Deny`. Only choosing one sends its exact native value to that request. No remembered choice is offered or sent.

#### Scenario: Unrecognized or incomplete approval

- **WHEN** the request shape or options are not recognized, the supplied details cannot be displayed safely within the bound, or no pending slot is available
- **THEN** no approval card with an enabled choice appears, the host sends cancellation for that request and the chat shows a bounded reason

#### Scenario: Request after the turn

- **WHEN** OMP asks for interaction during launch, before prompt admission, after the turn has ended or while the run is stopping
- **THEN** the host cancels the request without waiting for an answer and gives the bounded decline notice when the chat can still show notices

#### Scenario: Non-approval dialogs remain unavailable

- **WHEN** OMP sends an ordinary select, confirm, input, editor or other unsupported interactive request
- **THEN** the host sends cancellation, never a choice, input, or a timed-out answer that would accept defaults, and the chat shows a bounded decline notice

#### Scenario: Open URL request

- **WHEN** OMP sends a request to open a URL
- **THEN** no browser or process is opened and no answer grants anything

#### Scenario: Native policy remains in force

- **WHEN** an OMP session is open, including when native policy allows an operation without asking
- **THEN** the chat explains that OMP settings decide when it asks and that Kumiko does not sandbox the runtime. Kumiko adds no approval-mode override and creates no synthetic permission request for a tool that OMP does not ask about.

### Requirement: OMP features not yet supported are visibly unavailable

OMP runs SHALL report Continue and steering unavailable with a reason. The chat SHALL NOT claim support for remembered approvals, general extension dialogs, child activity or real-runtime qualification from this change.

#### Scenario: Tool activity in a turn

- **WHEN** OMP sends root tool events and separately attributed child events
- **THEN** only root tool events appear as root tool cards. Child events neither update a root card nor make child controls available.

#### Scenario: Continue on a saved OMP session

- **WHEN** the user reopens a saved OMP session and chooses Continue
- **THEN** Continue is shown unavailable with the reason, no OMP process starts and the saved record is unchanged

## ADDED Requirements

### Requirement: OMP root tool events update the corresponding card

Kumiko SHALL use OMP's root tool identity to show the reported name, status, bounded input and output. Updates SHALL change the corresponding card without repeating snapshots or inventing content or completion. Source: direction D6 and *Existing runtimes share a capability-aware interface*.

#### Scenario: Interleaved calls complete separately

- **WHEN** two root tools start and interleave progress and terminal frames
- **THEN** each has one card, each update changes only its own card, the final result replaces its partial snapshot, and each card reflects its reported success or failure

#### Scenario: Early activity waits for admission

- **WHEN** tool events arrive before the prompt is admitted and the prompt is later accepted or refused
- **THEN** accepted activity appears after the user's prompt in native order; refused activity does not appear in the transcript

#### Scenario: Missing or oversized tool data

- **WHEN** a native tool frame is clipped, has unusable fields or violates the tool tracking bound
- **THEN** Kumiko marks a visible omission or incomplete card without attributing the data to another call. It does not report success or failure without a corresponding terminal frame.
