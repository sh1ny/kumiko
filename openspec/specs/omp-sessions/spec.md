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

After readiness, the host SHALL read OMP's session identity and store it in the saved record with the target, runtime kind and version. A start whose identity is missing or invalid SHALL fail without a saved record. Source: direction D29.

#### Scenario: Identity stored

- **WHEN** OMP reports a session identifier after readiness
- **THEN** the saved record holds that identifier, the immutable target, runtime kind `omp` and the OMP version

#### Scenario: Identity missing

- **WHEN** OMP's state reply has no session identifier, an identifier over the design's bound, or the reply fails
- **THEN** start fails with an OMP protocol reason, no saved record is created and the process tree is terminated

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

Stop SHALL send OMP's native abort for the running prompt and report the outcome OMP gives through the shared Stop results. *Stopped* SHALL require OMP's prompt result to report the prompt aborted. A refused or late abort SHALL be visible and SHALL NOT be replaced by process termination. Source: direction D7.

#### Scenario: Abort succeeds

- **WHEN** the user presses Stop during an OMP turn and OMP's prompt result reports aborted
- **THEN** the chat shows Stopped, the session becomes Idle and the OMP process remains live and accepts a new prompt

#### Scenario: Turn finished first

- **WHEN** the user presses Stop and OMP's prompt result reports completed
- **THEN** the chat shows Finished before Stop

#### Scenario: Abort acknowledged after its deadline

- **WHEN** Stop was shown not confirmed and OMP's response to that abort arrives after the deadline, including after many later commands have completed
- **THEN** the response is dropped, the session stays Stopping, the process is not terminated, and a later prompt result settles Stop

#### Scenario: Abort not confirmed

- **WHEN** OMP refuses the abort command or no prompt result arrives by the stop deadline
- **THEN** the chat shows Stop not confirmed, the status stays Stopping, the process is not terminated and Close remains available

### Requirement: OMP interactive requests are declined until supported

Every interactive request OMP sends to the client, including tool approval selections, SHALL be answered cancelled exactly once with a bounded visible notice naming what was asked. Nothing SHALL be granted, selected, opened or typed on the user's behalf. Display-only requests SHALL NOT trigger any action.

#### Scenario: Tool approval requested

- **WHEN** OMP asks the client to select an approval option for a tool
- **THEN** the host answers it cancelled once, the chat shows a notice that OMP approvals are not supported yet with the request title, and no approve option is sent

#### Scenario: Open URL request

- **WHEN** OMP sends a request to open a URL
- **THEN** no browser or process is opened and no answer grants anything

#### Scenario: Request after the turn

- **WHEN** an interactive request arrives while no turn is running
- **THEN** it is still answered cancelled once with the notice

### Requirement: OMP features not yet supported are visibly unavailable

OMP runs SHALL report Continue, steering and Kumiko tools unavailable with a reason, and SHALL summarise tool activity in a turn as a bounded notice rather than drop it silently.

#### Scenario: Tool activity in a turn

- **WHEN** OMP runs three tools during a turn
- **THEN** the chat shows a notice that OMP ran tools whose activity is not shown yet, with the tool count, and the turn's reply still streams

#### Scenario: Continue on a saved OMP session

- **WHEN** the user reopens a saved OMP session and chooses Continue
- **THEN** Continue is shown unavailable with the reason, no OMP process starts and the saved record is unchanged

### Requirement: Closing an OMP session ends its input before cleanup

Close SHALL first end OMP's input so OMP can shut down in order, wait up to the design's close grace for the process to exit, then settle the contained process tree. A running turn SHALL be aborted before input ends. Exit failure SHALL be reported, not hidden.

#### Scenario: Orderly close

- **WHEN** the user closes an idle OMP session and OMP exits within the grace after its input ends
- **THEN** the session closes as exited, containment is settled and the saved record remains

#### Scenario: OMP does not exit

- **WHEN** OMP is still running when the close grace ends
- **THEN** the contained process tree is terminated and the close reports the outcome of that termination

### Requirement: OMP configuration and sign-in stay native

Kumiko SHALL launch OMP with the user's own environment and OMP configuration plus the profile's overrides, and SHALL NOT write OMP configuration, credentials or session files. Kumiko SHALL NOT copy inherited environment values into any record, log or desktop message. Text OMP itself emits is shown as OMP's output. Source: direction D20.

#### Scenario: User-configured provider

- **WHEN** the user's environment holds a provider key canary that OMP receives and does not echo
- **THEN** the canary appears in no saved record, host log, start result, state message or event that Kumiko sends

#### Scenario: Profile override does not leak

- **WHEN** an OMP profile sets an environment override and a terminal and another profile's session are started
- **THEN** neither of them sees that override
