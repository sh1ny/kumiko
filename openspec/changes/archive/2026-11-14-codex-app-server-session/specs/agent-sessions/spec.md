## MODIFIED Requirements

### Requirement: An agent session starts in the selected workspace
Starting a Claude Code or Codex session SHALL require a workspace selected in the sidebar. The session SHALL run with that workspace's absolute path as its working directory, with no branch, worktree or copy created. In Personal with no workspace, the launcher SHALL ask the user to open or select a folder and SHALL start nothing. Source: direction execution-workspaces "Work begins in the selected checkout", D4; user decision 2026-10-31.

#### Scenario: Start in a checkout
- **WHEN** workspace A at `/home/u/src/app` is selected and the user chooses **Claude Code** from the + menu
- **THEN** a new tab opens holding a chat pane bound to A, and the adapter's session is created with working directory `/home/u/src/app`

#### Scenario: No workspace selected
- **WHEN** Personal is selected with no workspace and the user opens the + menu
- **THEN** **Claude Code** is marked as needing a workspace with Open folder offered, and no tab, process or session record is created

#### Scenario: Workspace unavailable
- **WHEN** the selected workspace's folder has been deleted and the user starts a Claude Code session in it
- **THEN** the start is refused with *workspace unavailable*, and no adapter process or session record is created


#### Scenario: Codex launcher
- **WHEN** workspace A is selected and the user chooses Codex from the + menu
- **THEN** a chat pane starts bound to A after a compatible profile is selected; an incompatible default opens the compatible picker and starts nothing

#### Scenario: Codex without a workspace
- **WHEN** Personal has no workspace and the user chooses Codex
- **THEN** Open folder is offered and no process, tab or record is created

### Requirement: One turn runs at a time
A session SHALL accept a prompt only while idle. While a turn runs, the prompt box SHALL keep the user's text and Send SHALL be disabled. A Claude ACP turn SHALL end when the adapter answers the prompt; a Codex turn SHALL end on its native terminal turn event, not the turn-start response, and its stop reason SHALL be shown when it is not a normal end of turn.

#### Scenario: Send while running
- **WHEN** a turn is running and the user types a second prompt
- **THEN** Send is disabled, the text stays in the box, and nothing is sent until the turn ends

#### Scenario: Turn ends with a refusal
- **WHEN** the adapter answers a prompt with stop reason `refusal`
- **THEN** the session returns to *Idle* and the chat shows that the turn ended with a refusal

#### Scenario: Prompt fails
- **WHEN** the adapter answers a prompt with an error
- **THEN** the session returns to *Idle*, the chat shows the error message, and the prompt text is shown as sent


#### Scenario: Explicit steering is separate from Send
- **WHEN** a compatible Codex turn is running
- **THEN** Send remains disabled and an explicit steering action targets that turn without starting another

### Requirement: Reopen shows saved sessions and continues only on request
After quit and reopen, a chat pane SHALL show its session as *Saved, not running* with **Continue**, and SHALL start nothing until the user asks. Continue SHALL start the adapter with the record's target and native session id, using qualified history restoration when available, else qualified continuation with "earlier messages not shown". Claude retains its load-before-resume preference; Codex uses native thread resume and history reads. Neither SHALL resubmit a prompt or re-run a tool. Source: ADR 0004 decision 5, D7.

#### Scenario: Continue through load
- **WHEN** the user chooses Continue on a saved session and the adapter started for it reports a version qualified for load
- **THEN** the earlier prompts, replies and tool cards appear in the chat, the status becomes *Idle*, no prompt is sent to the adapter, and the next prompt continues that conversation

#### Scenario: Continue through resume
- **WHEN** the user chooses Continue, and the adapter started for it has resume claimed but not load
- **THEN** the chat shows "earlier messages not shown", the status becomes *Idle*, and the next prompt continues the same native session

#### Scenario: Reopen starts nothing
- **WHEN** the app reopens with three saved chat panes
- **THEN** each shows *Saved, not running*, and the host's ledger holds no agent unit until the user chooses Continue


#### Scenario: Codex restores through native history
- **WHEN** the user continues a compatible Codex saved thread
- **THEN** native thread resume and bounded history reads restore that thread without sending a turn-start request

### Requirement: Stop interrupts the turn and reports the actual result
Stop SHALL ask the runtime to cancel the current turn and known active child turns and SHALL report the outcome it observes: *Stopped*, *Finished before Stop*, *Turn ended with an error after Stop*, or *Stop not confirmed* by the design's stop deadline, replaced by the late outcome if the turn ends afterwards. Stop SHALL keep the session, its history and changed files, and SHALL NOT terminate the process. Source: ADR 0004 decision 4, D7.

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


#### Scenario: Codex native interruption completes
- **WHEN** native Codex reports the addressed root and known active child turns interrupted
- **THEN** Stop shows Stopped, the session becomes Idle and its App Server remains live

#### Scenario: Root idle with active child
- **WHEN** a Codex root is Idle with a known running child and the user presses Stop
- **THEN** the host interrupts the child, shows Stopping until a native outcome, and does not kill the process

#### Scenario: One child interruption is unsupported
- **WHEN** an addressed child's interruption cannot be confirmed by the deadline
- **THEN** Stop shows Stop not confirmed with the child reason, stays Stopping and leaves Close available

### Requirement: Closing a running agent asks for confirmation
Closing a pane or tab holding a session whose turn or known child work is running SHALL first ask "Are you sure you want to stop the running agent?", in one confirmation with any busy terminals. Cancel SHALL keep it running. Confirm SHALL cancel the turn, answer pending requests as cancelled and terminate the process tree. Other sessions SHALL close without a prompt. Moving SHALL NOT warn. Source: direction "Agent tab close depends on running work", D7.

#### Scenario: Close an idle session
- **WHEN** the user closes the pane of an idle session with no known active child work
- **THEN** no confirmation is shown, the adapter's process tree is terminated, the pane closes, and the session's saved record remains

#### Scenario: Cancel closing a running session
- **WHEN** the user closes the pane of a running session and chooses Cancel
- **THEN** the pane, its place in the split, and the turn keep running, and no cancel was sent to the adapter

#### Scenario: Confirm closing a running session
- **WHEN** the user closes a running session's pane and confirms
- **THEN** the turn is cancelled, the process tree is terminated, the pane closes, the saved record remains, and files the agent changed are left as they are

#### Scenario: Tab with a running agent and a live terminal
- **WHEN** the user closes a tab holding a running session and a terminal running a program
- **THEN** one confirmation names both, and confirming ends both and closes the tab

#### Scenario: Turn ends while the confirmation is open
- **WHEN** the confirmation is open and the turn ends on its own, and the user then confirms
- **THEN** the session is closed as an idle session, with no cancel sent


#### Scenario: Close idle root with running child
- **WHEN** the user closes an Idle Codex root whose known child is running
- **THEN** the shared close confirmation names delegated work, Cancel preserves it and Confirm settles the root unit and all descendants

### Requirement: Native authentication is reported, never managed
Kumiko SHALL use the selected runtime's existing sign-in and SHALL NOT sign in, store credentials, or pass credentials of its own to the adapter. When the adapter reports that authentication is required, the pane SHALL name that runtime and explain how to sign in natively, and offer Retry. Source: direction agent-tool-access "AI provider accounts remain native", D14, D20.

#### Scenario: Not signed in
- **WHEN** the adapter answers `session/new` with an authentication-required error
- **THEN** the pane shows that Claude Code is not signed in, suggests running `claude` in a terminal and signing in, offers Retry, and no session record is created

#### Scenario: Sign-in expires mid-session
- **WHEN** a prompt fails with an authentication-required error in a running session
- **THEN** the session returns to *Idle*, the chat shows the sign-in message, and the session record is unchanged


#### Scenario: Codex authentication is required
- **WHEN** a Codex start or turn returns an authentication signature confirmed by exact-version real evidence
- **THEN** the pane names Codex, suggests native Codex sign-in and offers explicit Retry while preserving the saved identity when present

#### Scenario: Unrecognized Codex auth-like error
- **WHEN** a Codex error resembles an authentication failure but has no confirmed classifier signature
- **THEN** the pane shows its bounded native error without claiming auth-required or managing credentials
