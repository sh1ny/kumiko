# Spec Delta

## MODIFIED Requirements

### Requirement: An OMP session records its native identity

After readiness, the host SHALL read OMP's session identity and store it in the saved record with the target, runtime kind and version. A start whose identity is missing or invalid SHALL fail without a saved record. A missing or unusable native locator SHALL NOT invalidate an otherwise usable live session. Source: direction D29.

#### Scenario: Identity stored

- **WHEN** OMP reports a session identifier after readiness
- **THEN** the saved record holds that identifier, the immutable target, runtime kind `omp` and the OMP version

#### Scenario: Identity missing

- **WHEN** OMP's state reply has no session identifier, an identifier over the design's bound, or the reply fails
- **THEN** start fails with an OMP protocol reason, no saved record is created and the process tree is terminated

#### Scenario: Native identity has no usable locator

- **WHEN** OMP reports a valid native identity without a usable session file
- **THEN** the live chat can accept prompts, but no locator is invented or exposed to the desktop

### Requirement: OMP Stop uses native abort without process termination

Stop SHALL use native abort for the running prompt and native cancellation for known active children. It SHALL report *Stopped* only after native evidence confirms interruption, and SHALL NOT kill the process to substitute for a refused or unconfirmed Stop. Source: direction D7.

#### Scenario: Abort succeeds

- **WHEN** the user presses Stop during an OMP turn and OMP's prompt result reports aborted with no remaining work
- **THEN** the chat shows Stopped, the session becomes Idle and the OMP process remains live and accepts a new prompt

#### Scenario: Turn finished first

- **WHEN** the user presses Stop and OMP's prompt result reports completed with no remaining work
- **THEN** the chat shows Finished before Stop

#### Scenario: Abort acknowledged after its deadline

- **WHEN** Stop was shown not confirmed and OMP's response to that abort arrives after the deadline, including after many later commands have completed
- **THEN** the response is dropped, the session stays Stopping, the process is not terminated, and a later prompt result settles Stop when no other work remains

#### Scenario: Abort not confirmed

- **WHEN** OMP refuses the abort command or no prompt result arrives by the stop deadline
- **THEN** the chat shows Stop not confirmed, the status stays Stopping, the process is not terminated and Close remains available

#### Scenario: Stop a child after the parent yields

- **WHEN** the user presses Stop after the parent yields and OMP still reports a running child
- **THEN** Kumiko requests cancellation of that child, does not report Stopped on the command response alone, and reports Stopped when OMP confirms the child was interrupted and the session has no remaining work

#### Scenario: Delegated Stop is not confirmed

- **WHEN** native child cancellation is unavailable, refused, or lacks terminal evidence, or OMP still reports work that the host cannot address
- **THEN** Kumiko does not report Stopped, shows why Stop is not confirmed and leaves Close available without killing the process

### Requirement: OMP features not yet supported are visibly unavailable

OMP runs SHALL report unavailable history and child visibility with reasons where the runtime cannot provide them. Kumiko SHALL NOT claim support for steering, remembered approvals, general extension dialogs, independent child continuation or real-runtime qualification from this change.

#### Scenario: Tool activity in a turn

- **WHEN** OMP sends root tool events and separately attributed child events
- **THEN** only root tool events appear as root tool cards; child events neither update a root card nor grant child controls

#### Scenario: Continue on a saved OMP session

- **WHEN** the user reopens a saved OMP session
- **THEN** the parent offers Continue when the record and the peers support it, shows a reason if they do not, and starts nothing until explicitly requested

#### Scenario: Child controls remain read-only

- **WHEN** the user inspects a child whose messages are available
- **THEN** that pane offers no Send, Stop, permission decisions, steering or Continue of its own

### Requirement: Closing an OMP session ends its input before cleanup

An orderly close SHALL cancel known work if needed, end OMP's input and drain its output within the design's grace before settling containment. Kumiko SHALL report process settlement and whether OMP's save could be confirmed separately. A retained saved record alone SHALL NOT count as a confirmed save.

#### Scenario: Orderly close

- **WHEN** the user closes an idle OMP session with native persistence enabled and OMP exits normally within the grace after EOF
- **THEN** the session closes, containment is settled and the saved record remains, with no warning of an unconfirmed save

#### Scenario: OMP does not exit

- **WHEN** OMP is still running when the close grace ends
- **THEN** the host settles the contained process tree, reports the outcome of cleanup and shows that native history saving could not be confirmed

#### Scenario: Native persistence fails during shutdown

- **WHEN** OMP reports an unrecovered persistence failure and exits nonzero after EOF
- **THEN** the saved record remains and the user sees that the latest OMP history may not have been saved, even when process cleanup succeeded

#### Scenario: Persistence is disabled

- **WHEN** the runtime uses no native session file and exits normally
- **THEN** the host reports native history unavailable and does not claim that it saved a transcript

## ADDED Requirements

### Requirement: OMP Continue opens only the exact recorded conversation

The host SHALL retain a bounded native locator for the original OMP identity when available. Only explicit Continue SHALL attempt recovery. It SHALL use the immutable target, require OMP to confirm the exact identity, and SHALL NOT substitute another chat or submit any prompt or tool call. Source: direction D7 and D29, ADR 0004 decision 5 and S1.

#### Scenario: Explicit Continue addresses one conversation

- **WHEN** the user continues a saved OMP chat with a valid native locator using a compatible runtime
- **THEN** one contained runtime opens that conversation at the original target, with the original Kumiko and OMP ids and no prompt or tool replay

#### Scenario: Saved locator is absent

- **WHEN** a saved record has no usable exact OMP locator, including a record made by an earlier Kumiko version
- **THEN** Continue reports why it is unavailable before any run starts, preserves the record and draft, and does not search for another session

#### Scenario: Native reopen cannot be verified

- **WHEN** OMP refuses or cancels the reopen, the native file is missing, or the native identity does not match the saved one
- **THEN** Continue shows resume unavailable, the attempted unit is settled or reported unresolved, and the saved record and draft stay unchanged

#### Scenario: Profile arguments could select another session

- **WHEN** the chosen OMP profile's arguments include a session-selection or restore option, an option terminator, a positional or an unknown flag
- **THEN** Continue is refused before spawn with a bounded reason, no runtime starts, and the saved record and draft are unchanged

#### Scenario: Previous run cannot answer a continued run

- **WHEN** a delayed permission reply targets the former OMP run after Continue has opened the same record and OMP has reused a native request id
- **THEN** Kumiko refuses the stale reply, sends nothing for the replacement request and preserves its pending choice

### Requirement: OMP root history stays in the runtime

Kumiko SHALL show bounded native history in chronological order before new live output when OMP returns it. It SHALL mark unsupported content and omitted history, keep the restored data in memory, and allow verified continuation with an explicit earlier-history notice when the runtime cannot return a usable snapshot.

#### Scenario: Native history restores before live output

- **WHEN** OMP confirms the saved identity and returns multiple valid history pages
- **THEN** the parent shows supported user and assistant messages and tool cards in native order before new live output, without using replay as a live prompt or rerunning any action

#### Scenario: Native history cannot be read within its bounds

- **WHEN** OMP confirms the identity but history is unavailable, too large, invalid or changes during paging so it cannot be read as one snapshot
- **THEN** Kumiko does not present partial pages as the restored transcript, shows why earlier messages are not shown and continues the same native conversation if it is still healthy and verified

#### Scenario: Recorded content was not provided

- **WHEN** OMP returns a valid history with content the chat cannot display
- **THEN** the chat keeps the supported messages and marks the omitted content without inventing a tool outcome

### Requirement: OMP child activity uses its owning live root

Kumiko SHALL show bounded child activity for the owning OMP run and keep a child's messages and tools separate from the root and other children. Missing or conflicting attribution SHALL be withheld and shown as incomplete. A yielded root SHALL NOT imply that its children or OMP background work have ended. Source: direction D6 and S2.

#### Scenario: Children have independent messages and cards

- **WHEN** two OMP children emit interleaved messages and use the same native tool call id
- **THEN** each view shows only its child's messages and cards in order, while the root shows child activity without presenting their output as its own

#### Scenario: Child visibility is unavailable or incomplete

- **WHEN** OMP does not support child reporting or drops, clips or conflicts on identities needed for attribution
- **THEN** the chat shows unavailable or incomplete delegated activity, does not attribute the unknown content to any chat and does not use the gap as proof that no work remains

#### Scenario: Parent yields before OMP settles

- **WHEN** the prompt result arrives but OMP still reports a live child or unsettled background work
- **THEN** the completed reply does not clear the close or quit warning, and the work stays listed until the host has native evidence that it ended or containment settles

### Requirement: OMP child history is read for the selected live run

An OMP child pane SHALL offer bounded history for its exact child on the owning live run where OMP can return it. It SHALL tell the user when history is unavailable or incomplete. It SHALL NOT adopt a child with the same name or identifier from another run or use child history to grant runtime controls.

#### Scenario: Inspect available child history

- **WHEN** the user opens a child pane and the owning OMP run returns that child's saved messages and tool records
- **THEN** the pane shows that history with its source distinguished from live activity and the parent transcript is unchanged

#### Scenario: Child history cannot be inspected

- **WHEN** the owning runtime cannot supply the child's history, exceeds the history limit or has already ended
- **THEN** the child pane says history is unavailable or incomplete and does not display history from another child, remove known live activity or start a runtime
