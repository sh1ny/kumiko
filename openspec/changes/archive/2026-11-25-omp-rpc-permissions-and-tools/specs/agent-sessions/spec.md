# Spec Delta

## MODIFIED Requirements

### Requirement: Replies and tool activity stream into the chat
A session's chat SHALL show the user's prompts, the streamed reply, thinking marked as such and its plan. Claude and Codex tool cards SHALL show title, kind, status, file locations and text or diff content as reported. OMP root tool cards SHALL show the native name and status and bounded input and output without inventing a location, kind or diff. Updates SHALL change the corresponding card. Oversized content SHALL be marked truncated. Unknown update kinds SHALL be ignored.

#### Scenario: Streamed reply
- **WHEN** the user sends "explain main.dart" and the adapter streams the reply in 40 chunks
- **THEN** the reply grows in the chat as chunks arrive, in order, and the final text equals the concatenated chunks

#### Scenario: Tool call progresses
- **WHEN** the agent reports a tool call `Edit lib/a.dart` as pending, then in progress, then completed with a diff
- **THEN** one card shows that title, moves through those statuses, and shows the diff of `lib/a.dart`

#### Scenario: Oversized tool output
- **WHEN** a tool call's text content is larger than the display bound
- **THEN** the card shows the content up to the bound with a *truncated* mark, and later updates and messages still arrive

#### Scenario: Unknown update kind
- **WHEN** the adapter sends a session update of a kind the session model does not define
- **THEN** it is not shown, the session keeps running, and later known updates are shown

### Requirement: Permission requests are answered only by an explicit choice

A supported permission request SHALL be shown in its chat with the tool call it concerns and its supported options, with their names. Claude and Codex SHALL show their offered options as before. OMP SHALL show only its supported one-shot choices. Only the user choosing an option, Stop, or closing the session SHALL answer a displayed request. Stop and close SHALL answer it as cancelled. Native withdrawal SHALL retire the card without answering. While it is pending the session status SHALL be *Waiting for approval*. Source: D37.

#### Scenario: Allow once
- **WHEN** the agent asks permission to run `npm test` with options Allow, Always allow and Reject, and the user chooses Allow
- **THEN** the adapter receives the selected option's id, the request is shown answered with Allow, and the status returns to *Running*

#### Scenario: Pane moved while a request is pending
- **WHEN** a request is pending and the user moves the pane to another tab and selects another workspace
- **THEN** the request is still shown pending in the chat with its options, and no answer has been sent

#### Scenario: Stop with a pending request
- **WHEN** the user presses Stop with a permission request pending
- **THEN** the adapter receives the request's answer as cancelled before or with the cancel, and the request is shown cancelled

#### Scenario: OMP withdraws a displayed approval
- **WHEN** OMP withdraws a pending approval or reports the end of the turn before the user answers
- **THEN** the host marks that exact request cancelled without a native reply, and a stale desktop answer cannot reach OMP or answer another request

#### Scenario: OMP permission action with no transcript credit
- **WHEN** the OMP session's event channel has no credit but its host event queue has room, and OMP raises an approval
- **THEN** the card and waiting state arrive on control. An admitted explicit reply or Stop is acknowledged there, and native turn completion is reported separately. If native input cannot admit the action, it returns busy without claiming it was sent.
