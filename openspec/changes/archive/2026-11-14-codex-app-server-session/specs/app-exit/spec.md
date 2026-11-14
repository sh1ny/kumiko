## MODIFIED Requirements

### Requirement: Quitting with no affected work asks nothing
A cancellable quit (window close or Quit) SHALL first collect the affected items: agent sessions running a turn, awaiting a permission reply, stopping or sending a prompt, and roots with known active child work; busy or unknown-activity terminals (terminal-sessions); and chat panes whose latest draft is not stored after the quit flush (agent-sessions). With none, Kumiko SHALL flush pending saves and quit without asking. Source: D7.

#### Scenario: Quit with idle work
- **WHEN** the user closes the window while one agent session is idle with no known active child work and two terminals sit at their shell prompts
- **THEN** no dialog is shown, the pending layout and draft saves are sent, and the desktop, its host, the adapter and both shells have exited

#### Scenario: Activity cannot be read in time
- **WHEN** the user quits and the host does not answer the terminal activity query within its deadline
- **THEN** every live terminal is listed as *may be running programs* in the exit dialog, and nothing is ended until the user decides


#### Scenario: Quit with idle root and active child
- **WHEN** the user quits while the Codex root is Idle but its child is running
- **THEN** the root is an affected item, the dialog names delegated work and quit waits for an explicit decision

### Requirement: The exit dialog lists every affected item
With affected items, the quit SHALL be held and one exit dialog SHALL list each item with its pane title, its kind and what is running: the agent's state, or up to three program names for a terminal. It SHALL offer **Stop** per item, **Stop processes and close**, and **Cancel**. While it is open the list SHALL follow the live state: an item that becomes idle with no known active child work, or ends, leaves it. Source: direction "App exit resolves affected work per item", D7.

#### Scenario: Agent turn and terminal program
- **WHEN** the user quits while session A runs a turn and terminal T runs vim
- **THEN** the exit dialog lists A as *running a turn* and T with `vim`, each with **Stop**, and the window stays open

#### Scenario: Item finishes while the dialog is open
- **WHEN** the exit dialog lists session A and terminal T, and A's turn ends on its own with no known active child work
- **THEN** A leaves the list, T stays, and nothing is sent to A

#### Scenario: Another quit while the dialog is open
- **WHEN** the exit dialog is open and the user closes the window again
- **THEN** the same dialog stays open with the same list, and no second dialog is shown


#### Scenario: Root finishes before child
- **WHEN** the root turn ends while a known child remains active and the exit dialog is open
- **THEN** the root item stays listed as delegated work until the child ends or the user stops the unit
