# Spec Delta

## MODIFIED Requirements

### Requirement: Quitting with no affected work asks nothing

A cancellable quit (window close or Quit) SHALL first collect the affected items: agent sessions running a turn, awaiting a permission reply, stopping or sending a prompt, and roots with known active child work; OMP sessions that may still have work; busy or unknown-activity terminals (terminal-sessions); and chat panes whose latest draft is not stored after the quit flush (agent-sessions). With none, Kumiko SHALL flush pending saves and quit without asking. Source: D7.

#### Scenario: Quit with idle work

- **WHEN** the user closes the window while one agent session is idle with no known active child work or unresolved activity and two terminals sit at their shell prompts
- **THEN** no dialog is shown, the pending layout and draft saves are sent, and the desktop, its host, the adapter and both shells have exited

#### Scenario: Activity cannot be read in time

- **WHEN** the user quits and the host does not answer the terminal activity query within its deadline
- **THEN** every live terminal is listed as *may be running programs* in the exit dialog, and nothing is ended until the user decides

#### Scenario: Quit with idle root and active child

- **WHEN** the user quits while a Codex or OMP root is Idle but its child is running
- **THEN** the root is an affected item, the dialog names delegated work once no matter how many child panes are open, and quit waits for an explicit decision

#### Scenario: Quit when OMP activity cannot be ruled out

- **WHEN** the user quits while the parent has yielded but OMP is still unsettled or the host lacks evidence that work ended
- **THEN** the dialog says OMP may still be working and waits for an explicit decision

### Requirement: The exit dialog lists every affected item

With affected items, the quit SHALL be held and one exit dialog SHALL list each item with its pane title, its kind and what is running: the agent's state, or up to three program names for a terminal. It SHALL offer **Stop** per item, **Stop processes and close**, and **Cancel**. While it is open the list SHALL follow the live state: an item that is no longer affected or ends leaves it. Source: direction "App exit resolves affected work per item", D7.

#### Scenario: Agent turn and terminal program

- **WHEN** the user quits while session A runs a turn and terminal T runs vim
- **THEN** the exit dialog lists A as *running a turn* and T with `vim`, each with **Stop**, and the window stays open

#### Scenario: Item finishes while the dialog is open

- **WHEN** the exit dialog lists session A and terminal T, and A's turn ends on its own with no known active child work or uncertainty
- **THEN** A leaves the list, T stays, and nothing is sent to A

#### Scenario: Another quit while the dialog is open

- **WHEN** the exit dialog is open and the user closes the window again
- **THEN** the same dialog stays open with the same list, and no second dialog is shown

#### Scenario: Root finishes before child

- **WHEN** the root turn ends while a known child remains active and the exit dialog is open
- **THEN** the root item stays listed as delegated work until the child ends or the user stops the unit

## ADDED Requirements

### Requirement: Ordinary quit gives OMP a bounded native shutdown

On ordinary quit, the host SHALL give OMP runtimes their bounded native shutdown before containment fallback without extending the shared shutdown deadline. If OMP's save is unconfirmed, its restored parent pane SHALL say so. The saved record, stored draft and saved layout SHALL remain. A persistence warning SHALL NOT stand for unresolved process cleanup or a successful Continue. Source: D7 and S3.

#### Scenario: Ordinary quit closes idle and confirmed working OMP sessions

- **WHEN** the desktop announces ordinary quit and closes its connection, with idle OMP sessions or after the user confirmed stopping work
- **THEN** the host gives those runtimes native shutdown, settles their contained processes, and the same parent and child panes reopen in their saved places without starting a runtime

#### Scenario: OMP save is unconfirmed on quit

- **WHEN** an OMP runtime could not finish native shutdown before fallback termination or exits with a persistence failure
- **THEN** its restored parent names the unconfirmed save, the saved record and draft are retained, and unresolved unit cleanup, if any, is reported separately

#### Scenario: Disconnect does not authorize ordinary quit

- **WHEN** the desktop dies or its connection fails without completing the ordinary quit handshake
- **THEN** the host uses the existing desktop-loss cleanup, and Kumiko does not claim OMP history saved or the previous exit was ordinary
