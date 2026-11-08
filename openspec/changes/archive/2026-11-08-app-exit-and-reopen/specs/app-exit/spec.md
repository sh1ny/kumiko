# Spec Delta

## Purpose

Decide what quitting the whole app does to the user's running agents and terminals: quit at once when nothing is affected, otherwise let the user stop each item or all of them, or cancel, while keeping the open layout for reopening.

## ADDED Requirements

### Requirement: Quitting with no affected work asks nothing
A cancellable quit (window close or Quit) SHALL first collect the affected items: agent sessions running a turn, awaiting a permission reply, stopping or sending a prompt; busy or unknown-activity terminals (terminal-sessions); and chat panes whose latest draft is not stored after the quit flush (agent-sessions). With none, Kumiko SHALL flush pending saves and quit without asking. Source: D7.

#### Scenario: Quit with idle work
- **WHEN** the user closes the window while one agent session is idle and two terminals sit at their shell prompts
- **THEN** no dialog is shown, the pending layout and draft saves are sent, and the desktop, its host, the adapter and both shells have exited

#### Scenario: Activity cannot be read in time
- **WHEN** the user quits and the host does not answer the terminal activity query within its deadline
- **THEN** every live terminal is listed as *may be running programs* in the exit dialog, and nothing is ended until the user decides

### Requirement: The exit dialog lists every affected item
With affected items, the quit SHALL be held and one exit dialog SHALL list each item with its pane title, its kind and what is running: the agent's state, or up to three program names for a terminal. It SHALL offer **Stop** per item, **Stop processes and close**, and **Cancel**. While it is open the list SHALL follow the live state: an item that becomes idle or ends leaves it. Source: direction "App exit resolves affected work per item", D7.

#### Scenario: Agent turn and terminal program
- **WHEN** the user quits while session A runs a turn and terminal T runs vim
- **THEN** the exit dialog lists A as *running a turn* and T with `vim`, each with **Stop**, and the window stays open

#### Scenario: Item finishes while the dialog is open
- **WHEN** the exit dialog lists session A and terminal T, and A's turn ends on its own
- **THEN** A leaves the list, T stays, and nothing is sent to A

#### Scenario: Another quit while the dialog is open
- **WHEN** the exit dialog is open and the user closes the window again
- **THEN** the same dialog stays open with the same list, and no second dialog is shown

### Requirement: Stopping one item keeps the rest and the layout
**Stop** on an item SHALL end only that item's unit, as a confirmed close does, without removing its pane from the layout. When the last unresolved item leaves the list, Kumiko SHALL quit. A Stop that fails SHALL keep its item with the error and *cleanup unresolved*, without Stop, until the user chooses the bulk action or Cancel; live-state updates SHALL NOT remove it. Source: direction "App exit resolves affected work per item", D7.

#### Scenario: Stop items one by one
- **WHEN** the exit dialog lists session A and terminal T, and the user chooses **Stop** on A and then on T
- **THEN** A's turn is cancelled and its process tree ends, then T's processes end, and Kumiko quits once both are gone

#### Scenario: Reopen after stopping items
- **WHEN** the user stopped A and T from the exit dialog and Kumiko quit, and the user reopens Kumiko
- **THEN** A's pane is restored as *Saved, not running* and T's pane as *ended, not restored*, both in their saved places

#### Scenario: A Stop fails
- **WHEN** the user chooses **Stop** on terminal T and the host reports `terminal/closeFailed`
- **THEN** T stays in the list with the error and *cleanup unresolved* and no Stop, the dialog stays open, the other items are unchanged, and later activity polls reporting T ended do not remove it

### Requirement: The bulk action states and ends all affected work
**Stop processes and close** SHALL state that every listed process will be stopped and every listed unsaved draft lost, then flush pending saves and quit; the host ends every unit within its shutdown deadline. It SHALL NOT delete saved session records or unsent drafts, and SHALL NOT mark panes closed. Source: direction "Bulk exit states process and file-discard consequences" (process part), D7.

#### Scenario: Bulk stop and close
- **WHEN** the exit dialog lists session A and terminals T and U, and the user chooses **Stop processes and close**
- **THEN** the desktop and host exit, no adapter, shell or program of A, T or U remains, and on reopen A's record and draft and all three panes are restored

#### Scenario: Unsaved draft at quit
- **WHEN** the user quits while session A is idle and its latest draft save was refused `draft-too-large`
- **THEN** the exit dialog lists A as *Draft not saved: too long* without Stop, and **Stop processes and close** states that the draft will be lost

#### Scenario: Bulk close with an item that cannot be ended
- **WHEN** the user chooses **Stop processes and close** and one of T's processes cannot be terminated before the host's shutdown deadline
- **THEN** Kumiko quits after the deadline, T's unit stays in the ledger, and the next launch shows T's workspace as *cleanup unresolved*

### Requirement: Cancel keeps unresolved work running
**Cancel** SHALL close the dialog and keep the app and every unresolved item running, with the layout unchanged. Items already stopped SHALL stay stopped and be shown so, never as restored. Source: direction "App exit resolves affected work per item", D7.

#### Scenario: Cancel after stopping one item
- **WHEN** the user stops session A from the exit dialog and then chooses **Cancel** while terminal T still runs vim
- **THEN** the app stays open, T and vim keep running with no input or output lost, and A's pane shows *Saved, not running*

#### Scenario: Cancel at once
- **WHEN** the user chooses **Cancel** without stopping anything
- **THEN** every listed item keeps running, and the tabs, panes and split ratios are unchanged

### Requirement: An exit that cannot be cancelled still ends everything
When the OS asks the app to exit without allowing cancellation, Kumiko SHALL NOT show the exit dialog. The host SHALL end every unit as on desktop loss. Edits not yet stored are lost; stored layout and drafts remain. Source: execution-host "Host lifetime is tied to the desktop".

#### Scenario: OS-required exit with running work
- **WHEN** the OS requires the app to exit while session A runs a turn
- **THEN** no dialog is shown, A's adapter and its tools are terminated by the host within its shutdown deadline, and A's record remains

#### Scenario: Host already lost at quit
- **WHEN** the user quits while the desktop shows *host lost* and every composer's text is stored
- **THEN** no dialog is shown and the desktop exits at once

#### Scenario: Host lost with an unsaved draft
- **WHEN** the user quits while the desktop shows *host lost* and session A's composer holds text typed after the host was lost
- **THEN** the exit dialog lists A as *Draft not saved: host lost*, and quitting needs **Stop processes and close**, which states the draft will be lost, or the user cancels

#### Scenario: Host lost while the dialog is open
- **WHEN** the exit dialog lists terminal T and session A's unsaved draft, and the host is lost
- **THEN** T leaves the list, A's draft item stays, and the app does not quit until the user decides
