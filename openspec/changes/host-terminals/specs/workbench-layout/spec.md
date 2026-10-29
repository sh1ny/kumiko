# Spec Delta

## ADDED Requirements

### Requirement: The launcher opens terminals
Each tab group's launcher SHALL offer **Terminal**, which opens a new terminal tab in that group with the default shell profile in the group's workspace context, and a way to choose another profile. Every Terminal launch SHALL open a new terminal; it SHALL NOT focus an existing one.

#### Scenario: Open a terminal from the launcher
- **WHEN** the user chooses **Terminal** in a group's launcher
- **THEN** a new terminal tab opens and is focused in that group, running the default profile in the group's workspace

#### Scenario: Open a second terminal
- **WHEN** the user chooses **Terminal** again in the same group
- **THEN** a second terminal tab opens alongside the first, and the first is unchanged

#### Scenario: Choose a profile
- **WHEN** the user opens the launcher's profile choice and picks fish
- **THEN** the new terminal tab runs fish

#### Scenario: Terminals unavailable
- **WHEN** the connected host does not support terminals
- **THEN** the **Terminal** entry is shown disabled with the reason, and the other launcher entries work

### Requirement: Terminal tabs are saved with the layout
A terminal tab SHALL be saved in the layout with its workspace binding and profile identity, and SHALL NOT save its output, scrollback, running programs or command history.

#### Scenario: Save a layout with terminals
- **WHEN** the layout is saved with two terminal tabs in different groups
- **THEN** the stored layout holds each terminal tab's group, position, workspace binding and profile identity, and no terminal output

#### Scenario: Older build reads a terminal tab
- **WHEN** a layout with terminal tabs is opened by a build without terminal support
- **THEN** the terminal tabs are kept in place as *unsupported view* and are not dropped on the next save

### Requirement: Closing groups and splits checks for live work
Closing a tab group, or a split that removes groups, SHALL first collect every tab that warns before closing, and SHALL show one confirmation covering all of them. Cancel SHALL leave the whole group or split unchanged.

#### Scenario: Close a split holding live terminals
- **WHEN** the user closes a split whose groups hold two terminals with live shells and a workspace overview
- **THEN** one confirmation names both terminals, and on confirm all three tabs close and the terminals' processes end

#### Scenario: Cancel closing a group
- **WHEN** the user closes a group with a live terminal and cancels the confirmation
- **THEN** the group, its tabs and their order are unchanged, and the terminal keeps running

#### Scenario: Group with no live work
- **WHEN** the user closes a group whose tabs are a workspace overview and an ended terminal
- **THEN** the group closes without a confirmation
