# Spec Delta

## MODIFIED Requirements

### Requirement: Closing a running agent asks for confirmation

Closing a pane or tab holding a session whose turn or known child work is running SHALL first ask "Are you sure you want to stop the running agent?", in one confirmation with any busy terminals. Incomplete OMP work visibility SHALL also warn that OMP may still be working. Cancel SHALL keep the session running. Confirm SHALL cancel addressable work, answer pending requests as cancelled and settle the process tree. Other sessions SHALL close without a prompt. Moving SHALL NOT warn. Source: direction "Agent tab close depends on running work", D7.

#### Scenario: Close an idle session

- **WHEN** the user closes the pane of an idle session with no known active child work and no OMP activity uncertainty
- **THEN** no confirmation is shown, the adapter's process tree is settled, the pane closes, and the session's saved record remains

#### Scenario: Cancel closing a running session

- **WHEN** the user closes the pane of a running session and chooses Cancel
- **THEN** the pane, its place in the split, and the turn keep running, and no cancel was sent to the adapter

#### Scenario: Confirm closing a running session

- **WHEN** the user closes a running session's pane and confirms
- **THEN** the turn is cancelled or stopped by containment, the process tree is settled or reported unresolved, the saved record remains, and files the agent changed are left as they are

#### Scenario: Tab with a running agent and a live terminal

- **WHEN** the user closes a tab holding a running session and a terminal running a program
- **THEN** one confirmation names both, and confirming ends both and closes the tab

#### Scenario: Turn ends while the confirmation is open

- **WHEN** the confirmation is open and the turn and any known child work end on their own, with no OMP activity uncertainty, and the user then confirms
- **THEN** the session is closed as an idle session, with no cancel sent

#### Scenario: Close idle root with running child

- **WHEN** the user closes an Idle Codex or OMP root whose known child is running
- **THEN** the shared close confirmation names delegated work, Cancel preserves it and Confirm settles the root unit and all descendants or reports unresolved cleanup

#### Scenario: Close with uncertain OMP work

- **WHEN** the user closes an OMP root that is not known to be quiescent and its delegated activity is incomplete or unavailable
- **THEN** the confirmation says OMP may still be working, and sends no close or cancel until the user confirms

### Requirement: Reopen shows saved sessions and continues only on request

After quit and reopen, a chat pane SHALL show its session as *Saved, not running*. Only explicit **Continue** SHALL open the saved native session at its immutable target. Verified recovery SHALL show native history when available, else say "earlier messages not shown" with a reason when known. Claude retains load before resume. Codex and OMP use their native identity and history paths. No runtime SHALL receive a resubmitted prompt or rerun a tool from history. Source: ADR 0004 decision 5, D7.

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

#### Scenario: OMP continuation is unavailable for this record

- **WHEN** a saved OMP record has no exact native locator or the connected host cannot continue OMP records
- **THEN** the pane shows Continue unavailable with the reason, keeps the saved record and the draft and offers no automatic replacement

## ADDED Requirements

### Requirement: A subagent pane views its parent's child without owning work

An OMP child view SHALL open from the parent's child activity as a workbench pane with the parent's workspace binding. It SHALL NOT own a process, draft, approval or Continue. Closing or moving the view SHALL NOT affect parent or child execution. Source: ADR 0011, direction D7 and S2.

#### Scenario: Open and close a child pane

- **WHEN** the user selects a child from its parent chat, moves its pane and then closes that pane while the child is running
- **THEN** it opens beside the parent as a split in the parent tab, renders only that child's chat, retains the original workspace through the move, and closes without a stop warning or a command sent to the runtime

#### Scenario: Parent ends while a child pane is open

- **WHEN** the parent is closed or the app reopens with a saved child-pane location
- **THEN** the child pane shows that its run ended or is unavailable, keeps any already displayed content in that app instance, and never starts a runtime or subscribes to a different child

#### Scenario: Split reaches its pane limit

- **WHEN** the parent tab cannot accept another split under the layout limits
- **THEN** the workbench reports the limit and leaves the parent and its components running in the unchanged layout
