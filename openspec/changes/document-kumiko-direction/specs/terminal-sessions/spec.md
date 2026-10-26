# Spec Delta

## Purpose

Provide interactive terminals using the execution host's shell configuration without tying terminal use to one shell or agent protocol.

## ADDED Requirements

### Requirement: Interactive terminals are shell agnostic
Kumiko SHALL support user-selected interactive shells rather than hardcoding PowerShell, bash, or zsh, including Nushell on Windows and fish on macOS when installed on the execution host. A shell profile SHALL specify the executable, argument list, working directory, and environment overrides.

#### Scenario: Launch the selected shell
- **WHEN** a user opens a terminal with an installed Nushell or fish profile
- **THEN** the execution host starts the configured executable with its argument list, working directory, and environment overrides.

#### Scenario: Shell executable is unavailable
- **WHEN** the selected shell executable is missing on the execution host
- **THEN** terminal launch reports the failure rather than silently substituting a hardcoded shell.

### Requirement: Shell integration is optional
Kumiko SHALL provide basic terminal interaction without requiring shell-specific integration. For an otherwise launchable unknown shell, unavailable shell-specific enhancements MUST be omitted without disabling the terminal.

#### Scenario: Known shell supports enhancements
- **WHEN** an installed shell has supported optional integration
- **THEN** the terminal can expose those enhancements alongside basic interaction.

#### Scenario: Unknown shell has no integration
- **WHEN** an installed shell has no Kumiko-specific integration
- **THEN** input and output remain available as a basic terminal without unsupported enhancements.

### Requirement: Terminals and agent tool shells remain distinct
Kumiko MUST distinguish a human interactive terminal from an agent's tool shell and structured agent connection. Terminal processes SHALL belong to their execution host rather than the terminal view while the app is open; this ownership MUST NOT imply survival after confirmed terminal closure or app exit.

#### Scenario: Human selects an interactive shell
- **WHEN** a user selects a shell for a human terminal
- **THEN** the terminal uses that profile without implying that the agent's tool shell or structured protocol has changed.

#### Scenario: Agent protocol does not provide a terminal
- **WHEN** an agent adapter offers structured conversations but no interactive terminal
- **THEN** Kumiko does not represent that protocol connection as a terminal; terminal access uses a separately host-owned terminal process.

### Requirement: Terminal-native agents are first-class without a Chat UI adapter
Kumiko SHALL support running installed Claude Code, Codex, OMP, and other CLI programs directly in real terminals as first-class work alongside structured Chat UI. Terminal use MUST NOT require a project, repository, team account, or Chat UI adapter for the selected CLI, and MUST NOT require collapsed sidebars or a separate application mode.

#### Scenario: Run an installed CLI in Personal
- **WHEN** a user without a project, repository, or team account starts an installed coding-agent CLI in a Personal terminal
- **THEN** the CLI runs through the real terminal with normal input and output, independently of a structured Chat UI connection.

#### Scenario: No structured adapter exists
- **WHEN** an installed CLI has no Kumiko Chat UI adapter
- **THEN** the user can still run it in a real terminal with either sidebar visible, without creating an adapter or changing application modes.

### Requirement: Closing terminals warns about affected running processes
Kumiko SHALL warn before a tab, pane, or group closure terminates running terminal processes, identifying all affected sessions and process loss. Cancel SHALL preserve those sessions and processes; confirmation SHALL terminate the affected processes and close the selected views without implying that their applications can later resume.

#### Scenario: Confirm closing a terminal application
- **WHEN** a user closes a terminal running vim or lazygit and confirms the process-loss warning
- **THEN** Kumiko terminates that terminal's affected processes and closes its view rather than keeping the application running invisibly.

#### Scenario: Cancel closing a terminal
- **WHEN** a user cancels the warning for a terminal with running work
- **THEN** its view, session, and running processes remain intact.

#### Scenario: Close a pane or group containing multiple terminals
- **WHEN** a user requests closure of a pane or group containing multiple running terminals
- **THEN** the warning covers all affected terminal sessions and their process loss before confirmation rather than warning about only the focused terminal.

### Requirement: Reopening restores terminal arrangement rather than processes
Kumiko SHALL preserve terminal layout for app reopening, not the lifetime of terminal processes. Reopening MUST NOT restore terminated applications, represent them as still running, or replay prior commands automatically. Layout restoration SHALL remain distinct from launching a shell.

#### Scenario: Reopen a four-pane terminal arrangement
- **WHEN** a user exits with four terminal panes containing vim and lazygit after confirming termination of the affected processes, then reopens Kumiko
- **THEN** the four-pane arrangement is restored without restoring those vim or lazygit processes or automatically replaying their launch commands.

#### Scenario: A restored pane refers to terminated work
- **WHEN** a restored terminal pane previously contained an application terminated during closure or exit
- **THEN** Kumiko does not claim that application is running or has resumed, and restoring the pane alone does not imply a shell-launch policy.

### Requirement: Personal terminals are not team-server streams
Kumiko MUST keep personal terminal sessions and output outside team-server storage, synchronization, indexing, and streaming, including administrator access. Task or project association MUST NOT publish a terminal or its output. Separate explicit host grants and user-authorized external operations MUST NOT become automatic team mirroring.

#### Scenario: Terminal work is associated with a shared task
- **WHEN** a user associates personal terminal work with a shared project task
- **THEN** the association does not upload, synchronize, index, or stream the terminal session or its output through the team server.

#### Scenario: Administrator requests terminal output
- **WHEN** a team administrator requests a member's personal terminal stream or history through the team service
- **THEN** the service does not provide that personal terminal data or treat administrator authority as a host grant.

#### Scenario: CLI contacts its selected provider
- **WHEN** a user runs a CLI that makes authorized requests to a selected AI provider or publishes through an explicitly authorized integration
- **THEN** those external operations remain separate from team-server terminal mirroring rather than implying a network-silent CLI.
