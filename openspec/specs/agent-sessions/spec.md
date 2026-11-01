# agent-sessions Specification

## Purpose

Defines how Kumiko runs, shows, stops, closes and reopens structured coding-agent chat sessions through a runtime adapter, with honest status, immutable execution targets and conversation history kept in the runtime's own store.

## Requirements

### Requirement: An agent session starts in the selected workspace
Starting a Claude Code session SHALL require a workspace selected in the sidebar. The session SHALL run with that workspace's absolute path as its working directory, with no branch, worktree or copy created. In Personal with no workspace, the launcher SHALL ask the user to open or select a folder and SHALL start nothing. Source: direction execution-workspaces "Work begins in the selected checkout", D4; user decision 2026-10-31.

#### Scenario: Start in a checkout
- **WHEN** workspace A at `/home/u/src/app` is selected and the user chooses **Claude Code** from the + menu
- **THEN** a new tab opens holding a chat pane bound to A, and the adapter's session is created with working directory `/home/u/src/app`

#### Scenario: No workspace selected
- **WHEN** Personal is selected with no workspace and the user opens the + menu
- **THEN** **Claude Code** is marked as needing a workspace with Open folder offered, and no tab, process or session record is created

#### Scenario: Workspace unavailable
- **WHEN** the selected workspace's folder has been deleted and the user starts a Claude Code session in it
- **THEN** the start is refused with *workspace unavailable*, and no adapter process or session record is created

### Requirement: A session's execution target never changes
A session's target SHALL be its host and its workspace's absolute path and directory identity, fixed when the session is created. Sidebar selection, focusing another workspace, moving its pane or tab, and layout changes SHALL NOT change it. Moving work to another workspace SHALL need a new session. Source: ADR 0004 decision 3, D5, D28.

#### Scenario: Focus another workspace
- **WHEN** a session runs in workspace A and the user selects workspace B in the sidebar and sends the session a prompt
- **THEN** the prompt goes to the same adapter session, whose working directory is still A's path, and the saved record still names A's path and identity

#### Scenario: Move the chat pane
- **WHEN** the user moves a running session's pane to a new tab and then into a split beside a terminal bound to B
- **THEN** the session keeps its process, native session id, transcript and target A, and nothing is sent to the adapter

#### Scenario: Folder replaced behind the workspace
- **WHEN** a saved session's workspace path now holds a different directory (another identity) and the user chooses Continue
- **THEN** Continue is refused with *resume unavailable: target changed*, and no adapter is started

### Requirement: Agent processes end with the session, the desktop or the host
Each session's adapter and every process it started SHALL be a contained unit, recorded before it starts, counted against the host's unit limit and refused against a workspace with *cleanup unresolved*. They SHALL be terminated when the session is closed, the desktop exits or dies, or the host exits. After an abrupt host death the next host SHALL clean them or mark the workspace *cleanup unresolved* (ADR 0001).

#### Scenario: Desktop is killed with a running session
- **WHEN** the desktop is killed while a session's agent runs a long tool command
- **THEN** no adapter, Claude Code or tool process from that session remains running

#### Scenario: Host dies abruptly
- **WHEN** the host is killed during a session's turn and the desktop starts a new host
- **THEN** the new host ends that session's process tree, or marks its workspace *cleanup unresolved* and refuses new sessions and terminals there

#### Scenario: Unit limit reached
- **WHEN** the host already runs its maximum number of units and the user starts a session
- **THEN** the start is refused with the limit stated, and no process or record is created

### Requirement: Replies and tool activity stream into the chat
A session's chat SHALL show the user's prompts, the agent's reply as it streams, its thinking marked as such, its plan, and a card per tool call with title, kind, status, file locations and text or diff content. Updates to a tool call SHALL update its card. A content item over the design's display bound SHALL be shown truncated and marked truncated. Update kinds the session model does not know SHALL be ignored without ending the session.

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
A permission request SHALL be shown in its chat with the tool call it concerns and every option the adapter offers, with their names. Only the user choosing an option, Stop, or closing the session SHALL answer it. Stop and close SHALL answer it as cancelled. While it is pending the session status SHALL be *Waiting for approval*. Source: D37.

#### Scenario: Allow once
- **WHEN** the agent asks permission to run `npm test` with options Allow, Always allow and Reject, and the user chooses Allow
- **THEN** the adapter receives the selected option's id, the request is shown answered with Allow, and the status returns to *Running*

#### Scenario: Pane moved while a request is pending
- **WHEN** a request is pending and the user moves the pane to another tab and selects another workspace
- **THEN** the request is still shown pending in the chat with its options, and no answer has been sent

#### Scenario: Stop with a pending request
- **WHEN** a request is pending and the user presses Stop
- **THEN** the adapter receives the request's answer as cancelled before or with the cancel, and the request is shown cancelled

### Requirement: One turn runs at a time
A session SHALL accept a prompt only while idle. While a turn runs, the prompt box SHALL keep the user's text and Send SHALL be disabled. A turn SHALL end when the adapter answers the prompt, and its stop reason SHALL be shown when it is not a normal end of turn.

#### Scenario: Send while running
- **WHEN** a turn is running and the user types a second prompt
- **THEN** Send is disabled, the text stays in the box, and nothing is sent until the turn ends

#### Scenario: Turn ends with a refusal
- **WHEN** the adapter answers a prompt with stop reason `refusal`
- **THEN** the session returns to *Idle* and the chat shows that the turn ended with a refusal

#### Scenario: Prompt fails
- **WHEN** the adapter answers a prompt with an error
- **THEN** the session returns to *Idle*, the chat shows the error message, and the prompt text is shown as sent

### Requirement: Session status reflects runtime evidence
Each chat pane and its tab SHALL show one status as text and icon: *Starting*, *Running*, *Waiting for approval*, *Stopping*, *Idle*, *Failed*, *Ended*, *Saved, not running* or *Stopped or unknown*, as defined in the design. A status SHALL change only on evidence from the adapter, the host or the connection. Source: direction workbench-layout "Agent status is readable...", D37.

#### Scenario: Status of a background tab
- **WHEN** a session in an inactive tab raises a permission request
- **THEN** that tab shows *Waiting for approval* without becoming active

#### Scenario: Adapter exits during a turn
- **WHEN** the adapter process exits with status 1 while a turn is running
- **THEN** the status becomes *Failed* with the exit status, the turn is shown ended without a reply, the saved record remains, and Continue is offered; whether it can load or resume is decided when the user chooses it

### Requirement: Stop interrupts the turn and reports the actual result
Stop SHALL ask the adapter to cancel the current turn and SHALL report the outcome it observes: *Stopped*, *Finished before Stop*, *Turn ended with an error after Stop*, or *Stop not confirmed* by the design's stop deadline, replaced by the late outcome if the turn ends afterwards. Stop SHALL keep the session, its history and changed files, and SHALL NOT terminate the process. Source: ADR 0004 decision 4, D7.

#### Scenario: Stop a running turn
- **WHEN** the agent is running a long tool command and the user presses Stop, and the adapter answers the prompt with stop reason `cancelled`
- **THEN** the chat shows *Stopped*, the status is *Idle*, the adapter process is still running and accepts a new prompt

#### Scenario: Turn finished first
- **WHEN** the user presses Stop and the adapter answers the prompt with `end_turn`
- **THEN** the chat shows *Finished before Stop*, not *Stopped*

#### Scenario: Adapter ignores the cancel
- **WHEN** the user presses Stop and the adapter has not answered the prompt by the stop deadline
- **THEN** the chat shows *Stop not confirmed*, the status stays *Stopping* with the turn still running, the process is not terminated, and Close remains available

#### Scenario: Turn errors after Stop
- **WHEN** the user presses Stop and the adapter answers the prompt with an error
- **THEN** the chat shows *Turn ended with an error after Stop* with the error message, not *Stopped* or *Finished before Stop*, and the status is *Idle*

#### Scenario: Turn ends after the stop deadline
- **WHEN** *Stop not confirmed* is shown and the adapter later answers the prompt with stop reason `cancelled`
- **THEN** the chat shows *Stopped (after the deadline)* in place of *Stop not confirmed*, and the status becomes *Idle*

### Requirement: Closing a running agent asks for confirmation
Closing a pane or tab holding a session whose turn is running SHALL first ask "Are you sure you want to stop the running agent?", in one confirmation with any live terminals. Cancel SHALL keep it running. Confirm SHALL cancel the turn, answer pending requests as cancelled and terminate the process tree. Other sessions SHALL close without a prompt. Moving SHALL NOT warn. Source: direction "Agent tab close depends on running work", D7.

#### Scenario: Close an idle session
- **WHEN** the user closes the pane of an idle session
- **THEN** no confirmation is shown, the adapter's process tree is terminated, the pane closes, and the session's saved record remains

#### Scenario: Cancel closing a running session
- **WHEN** the user closes the pane of a running session and chooses Cancel
- **THEN** the pane, its place in the split, and the turn keep running, and no cancel was sent to the adapter

#### Scenario: Confirm closing a running session
- **WHEN** the user closes a running session's pane and confirms
- **THEN** the turn is cancelled, the process tree is terminated, the pane closes, the saved record remains, and files the agent changed are left as they are

#### Scenario: Tab with a running agent and a live terminal
- **WHEN** the user closes a tab holding a running session and a terminal with a live shell
- **THEN** one confirmation names both, and confirming ends both and closes the tab

#### Scenario: Turn ends while the confirmation is open
- **WHEN** the confirmation is open and the turn ends on its own, and the user then confirms
- **THEN** the session is closed as an idle session, with no cancel sent

### Requirement: Each session keeps a saved record; transcripts stay in the runtime
The host SHALL store one record per session with its Kumiko session id, runtime kind, adapter name and version, native session id, role `coding` and target, written when the adapter returns the native session id. Prompts, replies and tool output SHALL NOT be written to Kumiko's store or logs; the conversation SHALL remain in the runtime's own history. Source: ADR 0004 decision 3, D29, D46.

#### Scenario: Record survives restart
- **WHEN** a session is started in workspace A and the host is restarted
- **THEN** the store holds its record with the same Kumiko id, native session id, adapter version and A's path and identity

#### Scenario: Start fails before a native id
- **WHEN** the adapter fails `session/new`
- **THEN** no session record is stored, and the pane shows the failure with Retry

#### Scenario: No transcript in Kumiko's files
- **WHEN** a session exchanges a prompt containing the text `kumiko-canary-7f3a` and the host is stopped
- **THEN** that text appears in no file under Kumiko's profile directory, including the store and host logs

### Requirement: Reopen shows saved sessions and continues only on request
After quit and reopen, a chat pane SHALL show its session as *Saved, not running* with **Continue**, and SHALL start nothing until the user asks. Continue SHALL start the adapter with the record's target and native session id, using `load` when claimed, which shows the earlier conversation, else `resume`, which shows "earlier messages not shown". Neither SHALL resubmit a prompt or re-run a tool. Source: ADR 0004 decision 5, D7.

#### Scenario: Continue through load
- **WHEN** the user chooses Continue on a saved session and the adapter started for it reports a version qualified for load
- **THEN** the earlier prompts, replies and tool cards appear in the chat, the status becomes *Idle*, no prompt is sent to the adapter, and the next prompt continues that conversation

#### Scenario: Continue through resume
- **WHEN** the user chooses Continue, and the adapter started for it has resume claimed but not load
- **THEN** the chat shows "earlier messages not shown", the status becomes *Idle*, and the next prompt continues the same native session

#### Scenario: Reopen starts nothing
- **WHEN** the app reopens with three saved chat panes
- **THEN** each shows *Saved, not running*, and the host's ledger holds no agent unit until the user chooses Continue

### Requirement: Unavailable resume is visible
When Continue cannot use load or resume, the pane SHALL show *resume unavailable* with the reason and keep the saved record. Reasons include: an unqualified version, a capability not advertised, history missing, the target missing or changed, the workspace with *cleanup unresolved*, and the record unknown to the host. Kumiko SHALL NOT start a substitute conversation.

#### Scenario: History deleted
- **WHEN** the runtime's history for a saved session was deleted and the user chooses Continue
- **THEN** the pane shows *resume unavailable* with the adapter's error, the adapter process is terminated, and no new conversation is created

#### Scenario: Cleanup unresolved
- **WHEN** the saved session's workspace has *cleanup unresolved* and the user chooses Continue
- **THEN** the pane shows *resume unavailable: cleanup unresolved*, and no process is started

#### Scenario: Start a fresh session instead
- **WHEN** a pane shows *resume unavailable* and the user chooses New session
- **THEN** a new session with a new Kumiko id starts in the same workspace, and the old record is kept unchanged

### Requirement: Host loss marks sessions stopped or unknown
When the host is lost, every open chat pane SHALL show *Stopped or unknown*, never *Running* or *Idle*. Pending permission requests SHALL be shown unanswerable. After the host restarts, the panes SHALL show *Saved, not running* with Continue for sessions that have a record.

#### Scenario: Host killed mid-turn
- **WHEN** the host is killed while a session runs a turn
- **THEN** the pane shows *Stopped or unknown* within the host-loss detection bound, and Send, Stop and the request options are disabled

#### Scenario: Restart host
- **WHEN** the user restarts the host after the loss
- **THEN** the pane shows *Saved, not running* with Continue, and no adapter is running for it

### Requirement: Native authentication is reported, never managed
Kumiko SHALL use Claude Code's existing sign-in and SHALL NOT sign in, store credentials, or pass credentials of its own to the adapter. When the adapter reports that authentication is required, the pane SHALL say Claude Code is not signed in and how to sign in natively, and offer Retry. Source: direction agent-tool-access "AI provider accounts remain native", D14, D20.

#### Scenario: Not signed in
- **WHEN** the adapter answers `session/new` with an authentication-required error
- **THEN** the pane shows that Claude Code is not signed in, suggests running `claude` in a terminal and signing in, offers Retry, and no session record is created

#### Scenario: Sign-in expires mid-session
- **WHEN** a prompt fails with an authentication-required error in a running session
- **THEN** the session returns to *Idle*, the chat shows the sign-in message, and the session record is unchanged

### Requirement: Session event volume is bounded without silent loss
Transcript events SHALL reach the desktop in order through a bounded path. When the desktop does not keep up, the host SHALL stop reading that adapter's output, not drop events. A single adapter message over the design's size bound SHALL end the session as *Failed* with the reason. The desktop SHALL keep each chat's transcript within the design's display bound, hiding the oldest entries with a visible marker.

#### Scenario: Slow consumer
- **WHEN** the desktop stops consuming a session's events while the adapter streams a long reply
- **THEN** the host stops reading that adapter's output at the bound, and once consumption resumes every event arrives in order with none missing

#### Scenario: Oversized adapter message
- **WHEN** the adapter writes one line larger than the message size bound
- **THEN** the session shows *Failed: adapter message too large*, its process tree is terminated, and the saved record remains

#### Scenario: Long conversation
- **WHEN** a chat's transcript grows past the display bound
- **THEN** the oldest entries are hidden behind a marker saying earlier messages are hidden, and the session keeps running
