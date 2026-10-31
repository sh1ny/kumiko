# Spec Delta

## ADDED Requirements

### Requirement: The launcher opens Claude Code sessions
The + menu SHALL offer **Claude Code**, which opens a new tab holding one chat pane bound to the workspace selected in the sidebar and starts a new session with the default runtime profile, with a way to choose another runtime profile. Every launch SHALL start a new session; it SHALL NOT focus an existing one.

#### Scenario: Open Claude Code from the launcher
- **WHEN** workspace A is selected and the user chooses **Claude Code** from the + menu
- **THEN** a new tab opens, active and focused, holding one chat pane bound to A showing *Starting*

#### Scenario: Second session in the same workspace
- **WHEN** a session already runs in A and the user chooses **Claude Code** again
- **THEN** a second tab with a new session opens, and the first session is unchanged

#### Scenario: No runtime profile
- **WHEN** no runtime profile exists and the user chooses **Claude Code**
- **THEN** no tab opens, and the user is asked to add a runtime profile, naming the adapter package

### Requirement: Chat panes are saved with the layout
A chat pane SHALL be saved in the layout with its workspace binding and its Kumiko session id, and nothing from the conversation. On reopen it SHALL be restored in its tab and split position. A pane whose session started but has no saved record yet SHALL be restored as *Ended* with New session.

#### Scenario: Reopen a split with a chat and a terminal
- **WHEN** a tab holds a chat pane beside a terminal pane and the user quits and reopens Kumiko
- **THEN** the tab has the same split and ratio, the chat pane shows *Saved, not running* for the same session id, and the terminal shows *ended, not restored*

#### Scenario: Pane state holds no conversation text
- **WHEN** a chat pane's session exchanged prompts and replies and the layout is saved
- **THEN** the saved pane holds the session id and display state only, and no prompt or reply text

#### Scenario: Session never got a record
- **WHEN** the app is killed while a chat pane is still *Starting*, and it is reopened
- **THEN** the pane shows *Ended* with New session and no Continue
