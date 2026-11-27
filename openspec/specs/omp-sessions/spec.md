# omp-sessions Specification

## Purpose
Defines native OMP (oh-my-pi) conversations in Kumiko over OMP's own RPC mode: launch, readiness, prompts, streamed replies, Stop and shutdown, while OMP owns execution, configuration and history.

## Requirements

### Requirement: OMP uses its native RPC connection

OMP sessions SHALL run the profile's OMP executable in its native RPC mode over private stdio, with no ACP intermediary and no network listener. Each root session SHALL own its contained process tree. The session SHALL become usable only after OMP's readiness frame offers RPC protocol version 1. Source: ADR 0004 decisions 1 and 3, direction D6.

#### Scenario: Start native OMP

- **WHEN** the user starts OMP with an available compatible profile in workspace A
- **THEN** one contained OMP process starts in A with the profile's arguments unchanged, its readiness frame is received before any prompt is accepted, and the desktop shows the session as Idle

#### Scenario: Readiness never arrives

- **WHEN** OMP exits, writes a non-JSON line, or sends no readiness frame within the design's start deadline
- **THEN** start fails visibly with the stage and the last lines of OMP's error output, no saved record is created, and containment is settled or reported unresolved

#### Scenario: Unsupported protocol version

- **WHEN** the readiness frame's supported protocol versions do not include 1
- **THEN** start fails with *unsupported OMP RPC protocol* naming the offered versions, and the process tree is terminated

#### Scenario: Malformed frame after start

- **WHEN** a running OMP session writes a stdout line that is not a JSON object, or a response whose id Kumiko never issued
- **THEN** the session becomes Failed with an OMP protocol reason, its process tree is terminated and the saved record remains

### Requirement: OMP versions below the minimum are refused before spawn

Before spawning a session process, the host SHALL identify the OMP version with a bounded, contained version probe and SHALL then re-check that the executable did not change. A version below the design's minimum, or an unreadable version, SHALL refuse the start with the version or the reason named. Versions at or above the minimum SHALL NOT need an exact-version allowlist.

#### Scenario: Supported version

- **WHEN** the probe reports a version at or above the minimum
- **THEN** the session process is spawned and the session records that exact version

#### Scenario: Version too old

- **WHEN** the probe reports a version below the minimum
- **THEN** start is refused naming the version and the minimum, no session process is spawned and no saved record is created

#### Scenario: Probe fails

- **WHEN** the probe times out, exits non-zero, writes more than its output bound, or prints no recognisable version
- **THEN** start is refused with that reason, the probe's process tree is settled and no session process is spawned

#### Scenario: Executable replaced after the probe

- **WHEN** the executable's identity changes between the probe and the spawn
- **THEN** start is refused as changed during start and no session process is spawned

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

### Requirement: OMP prompt admission and completion are distinct

The chat SHALL commit a prompt only after OMP admits it. The admission response SHALL NOT end the turn: OMP's terminal prompt result SHALL decide the outcome. A prompt OMP handles without invoking the agent SHALL end the turn at admission. Failed admission SHALL keep the composer text and add no user event.

#### Scenario: Admission precedes output

- **WHEN** OMP admits a prompt and streams reply events before its prompt result
- **THEN** the user prompt is shown once before any reply text or thinking, and the session stays Running until the prompt result arrives, then becomes Idle

#### Scenario: Handled without the agent

- **WHEN** OMP admits a prompt and reports that the agent was not invoked
- **THEN** the turn ends at admission and the session becomes Idle without waiting for a prompt result

#### Scenario: Admission refused

- **WHEN** OMP answers the prompt with a failure, or the bounded write queue cannot admit it
- **THEN** Send is refused with the reason, the session does not publish Running, the composer keeps its text and no user event or staged reply is shown; the removed draft is restored unless a newer revision was saved

#### Scenario: Transport breaks after admission

- **WHEN** OMP's process exits or its output ends after a prompt was admitted and before its prompt result
- **THEN** the session becomes Failed with the exit reason and containment is settled

### Requirement: OMP replies and thinking stream in order

The chat SHALL show OMP's assistant text and thinking as they stream, in OMP's order, with thinking marked as such. OMP's final message SHALL NOT duplicate text already shown. Unknown OMP event types SHALL be ignored without ending the session.

#### Scenario: Streamed reply

- **WHEN** OMP streams a reply as 40 text deltas and then its final message
- **THEN** the reply grows as deltas arrive, and the final text equals the concatenated deltas with none repeated

#### Scenario: Thinking and text interleave

- **WHEN** OMP streams thinking deltas and then text deltas in one turn
- **THEN** the thinking is shown marked as thinking before the reply text, in that order

#### Scenario: Too many open messages

- **WHEN** OMP starts more assistant messages without ending them than the design's open-message bound
- **THEN** the session becomes Failed with an OMP protocol reason, already shown text is not repeated, and the saved record remains

#### Scenario: Unknown event

- **WHEN** OMP sends an event type the session model does not define
- **THEN** it is not shown, the session keeps running and later known events are shown

### Requirement: OMP turn errors are shown as OMP reports them

A turn that OMP ends with an error SHALL end Idle with OMP's bounded, redacted error message visible, including provider and authentication failures. OMP notices SHALL be shown as notices. Kumiko SHALL NOT retry, sign in or change the model on the user's behalf. Source: direction D20.

#### Scenario: Provider error

- **WHEN** OMP's prompt result reports status error with message "401 invalid api key"
- **THEN** the chat shows that message as the turn's error, the session becomes Idle and accepts another prompt

#### Scenario: Oversized error text

- **WHEN** the reported error message exceeds the display bound
- **THEN** it is shown truncated and marked truncated, and the session becomes Idle

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

### Requirement: OMP interactive requests are declined until supported

Kumiko SHALL offer only OMP's exact one-shot approval and denial for recognized native approval requests on an admitted root turn. It SHALL preserve the native approval policy, decline other interactive requests and take no action on display-only requests. Source: direction D6 and D37; owner decision S1.

#### Scenario: Tool approval requested

- **WHEN** OMP sends a recognized approval request on the admitted root turn
- **THEN** the chat shows OMP's supplied approval details and offers only the exact one-shot choice and `Deny`. Only choosing one sends its exact native value to that request. No remembered choice is offered or sent.

#### Scenario: Unrecognized or incomplete approval

- **WHEN** the request shape or options are not recognized, the supplied details cannot be displayed safely within the bound, or no pending slot is available
- **THEN** no approval card with an enabled choice appears, the host sends cancellation for that request and the chat shows a bounded reason

#### Scenario: Open URL request

- **WHEN** OMP sends a request to open a URL
- **THEN** no browser or process is opened and no answer grants anything

#### Scenario: Request after the turn

- **WHEN** OMP asks for interaction during launch, before prompt admission, after the turn has ended or while the run is stopping
- **THEN** the host cancels the request without waiting for an answer and gives the bounded decline notice when the chat can still show notices

#### Scenario: Non-approval dialogs remain unavailable

- **WHEN** OMP sends an ordinary select, confirm, input, editor or other unsupported interactive request
- **THEN** the host sends cancellation, never a choice, input, or a timed-out answer that would accept defaults, and the chat shows a bounded decline notice

#### Scenario: Native policy remains in force

- **WHEN** an OMP session is open, including when native policy allows an operation without asking
- **THEN** the chat explains that OMP settings decide when it asks and that Kumiko does not sandbox the runtime. Kumiko adds no approval-mode override and creates no synthetic permission request for a tool that OMP does not ask about.

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

### Requirement: OMP configuration and sign-in stay native

Kumiko SHALL launch OMP with the user's own environment and OMP configuration plus the profile's overrides, and SHALL NOT write OMP configuration, credentials or session files. Kumiko SHALL NOT copy inherited environment values into any record, log or desktop message. Text OMP itself emits is shown as OMP's output. Source: direction D20.

#### Scenario: User-configured provider

- **WHEN** the user's environment holds a provider key canary that OMP receives and does not echo
- **THEN** the canary appears in no saved record, host log, start result, state message or event that Kumiko sends

#### Scenario: Profile override does not leak

- **WHEN** an OMP profile sets an environment override and a terminal and another profile's session are started
- **THEN** neither of them sees that override

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

### Requirement: Real OMP qualification is recorded separately from regression tests

Qualification SHALL require an explicit owner-approved Windows desktop walk for one exact installed OMP version. Approval for the live walk SHALL be separate from build approval. The record SHALL identify the approval, version, OS, Kumiko revision and model, and distinguish observed results from contract differences and unobserved behavior. Fixtures SHALL NOT stand in for a real observation. Admission SHALL remain based on the existing version minimum and native protocol.

#### Scenario: Approved Windows desktop walk completes

- **WHEN** the approved walk observes start, prompt, streaming, target retention, Stop, one-shot approval and denial, root tool activity, an authorized Kumiko tool call, exact Continue, history restore, a read-only child pane, close and ordinary quit
- **THEN** the record identifies the evidence for each result and qualifies only the observed version on Windows if every required result passed

#### Scenario: A required observation fails or does not occur

- **WHEN** the real walk disagrees with an expected result or cannot observe one
- **THEN** the record names the failed or unverified item and the reason; the attempt does not qualify the version, and neither fixture results nor another version's evidence changes that outcome

### Requirement: The OMP evidence audit runs offline

The qualification audit SHALL validate recorded OMP evidence without launching the app or runtime or using a provider. It SHALL reject malformed records and report each attempt as PASS, FAIL or INCOMPLETE according to its own results. A failed or incomplete attempt that is accurately recorded SHALL remain reportable. An empty record SHALL make no qualification claim.

#### Scenario: Complete passing evidence

- **WHEN** one well-formed Windows attempt has a passing result and an observation for every required item
- **THEN** the audit prints PASS with that attempt and its exact version

#### Scenario: Failed and incomplete attempts stay separate

- **WHEN** recorded attempts contain failures or unverified results, including when their rows could be combined into a passing set
- **THEN** the audit reports FAIL for a failed attempt and INCOMPLETE for an unverified attempt without a failure, without merging evidence across attempts

#### Scenario: Malformed evidence is not a qualification claim

- **WHEN** the evidence is missing or malformed, uses an unsupported OS, repeats an attempt or item, lacks or repeats an approval reference, or lacks a required result or nonempty observation
- **THEN** the audit fails with an evidence diagnostic and does not print PASS for the invalid record

#### Scenario: No real run is recorded

- **WHEN** the evidence contains no attempts
- **THEN** the audit succeeds with no OMP qualification claim
