# workbench-layout Specification

## Purpose
Give Kumiko a project-optional desktop workbench: a Personal working set of tab groups and splits whose layout the host saves and restores, and whose tabs keep their workspace binding through any navigation or rearrangement (D7, D28, D30, D41, ADR 0004).

## Requirements

### Requirement: First launch opens Personal without prompts
On a profile with no saved layout, Kumiko SHALL open the Personal working set with one empty tab group and its launcher. It MUST NOT ask for an account, project, repository, server or network connection first. Source: direction "Personal work does not require a project", D30, D41.

#### Scenario: Fresh profile
- **WHEN** the desktop starts on a profile with no store and the host connects
- **THEN** the workbench shows Personal with one empty tab group, its + launcher and an Open folder action, and no dialog or prompt is shown

#### Scenario: Host still reconciling
- **WHEN** the host reports that it is reconciling earlier processes at startup
- **THEN** the Personal workbench and its saved layout are shown at once, and the reconciliation state is shown without blocking the workbench

### Requirement: Tab groups split and tabs move without changing their binding
The workbench SHALL let the user split a tab group horizontally or vertically, move a tab to another group, and close a tab. Moving or splitting MUST keep the same view and its workspace binding; closing the last tab of a group that is not the only group SHALL remove that group. Source: direction "Tab groups and splits remain independent".

#### Scenario: Move a tab to another group
- **WHEN** the user moves a Workspace overview tab for workspace A into a different tab group
- **THEN** the destination group shows that tab active, still bound to workspace A, and the source group no longer lists it

#### Scenario: Close the last tab of a split group
- **WHEN** the user closes the only tab in one of two split groups
- **THEN** that group and its split are removed and the remaining group fills the central area

#### Scenario: Split at the group limit
- **WHEN** the user tries to split a group while the working set already has the maximum number of tab groups
- **THEN** no group is created, the layout is unchanged, and the split action reports the limit

### Requirement: Each tab group has a labeled click launcher
Every tab group SHALL show a visible + control that opens, on click, a labeled menu of the view kinds this build supports. A view chosen there SHALL open in that group, bound to the group's workspace context. Source: direction "Each tab group provides a labeled click launcher", D30.

#### Scenario: Open a view from an unfocused group
- **WHEN** group 1 is focused with workspace A, and the user clicks + in group 2, whose context is workspace B, and chooses Workspace overview
- **THEN** the new tab opens in group 2, bound to workspace B, and group 2 becomes the focused group

#### Scenario: Launcher in a group with no workspace context
- **WHEN** the user opens + in a group with no workspace context
- **THEN** the menu shows the view kinds, marks each one that needs a workspace as needing one with Open folder offered, and creates no tab until a workspace is chosen

#### Scenario: Tab limit reached
- **WHEN** the working set already holds the maximum number of tabs and the user chooses a view kind from +
- **THEN** no tab is created and the launcher reports the limit

### Requirement: Opening an open item focuses it
Opening an item that already has a tab in the working set SHALL focus that tab, in whichever group holds it, rather than create a second view. Source: direction "Opening an existing item focuses it by default".

#### Scenario: Overview already open in another group
- **WHEN** the Workspace overview of workspace A is open in group 1 and the user chooses Workspace overview for A from group 2's launcher
- **THEN** the existing tab in group 1 becomes active and focused, and the tab count is unchanged

#### Scenario: Item's tab was closed
- **WHEN** the user closed the Workspace overview of workspace A and then opens it again
- **THEN** a new tab for A opens in the group whose launcher was used

### Requirement: Workspace selection focuses existing work without retargeting
Selecting a workspace in the sidebar SHALL focus that workspace's most recently active tab, or, when it has none, make it the focused group's workspace context. It MUST NOT change the workspace binding of any existing tab. Source: direction "Direct workspace navigation activates its parent context", D28, ADR 0004.

#### Scenario: Workspace with open tabs
- **WHEN** the user selects workspace B in the sidebar while a tab bound to B is open in a background group
- **THEN** that tab becomes active and its group focused, and every tab keeps its workspace binding

#### Scenario: Workspace with no tabs
- **WHEN** the user selects workspace C, which has no open tab, while a group holding tabs bound to workspace A is focused
- **THEN** the focused group's context becomes C, and the tabs bound to A remain bound to A

### Requirement: A tab's workspace binding never changes
A tab's workspace binding SHALL be set when the tab is created and kept for the tab's whole life, including across save and restore. Focus changes, sidebar selection, group context changes, moves, splits and sidebar collapse MUST NOT change it. Source: ADR 0004 decision 3, D28.

#### Scenario: Binding after rearrangement and restore
- **WHEN** a tab bound to workspace A is moved, its group is split, workspace B is focused, and the app is quit and reopened
- **THEN** the restored tab is bound to workspace A

#### Scenario: Bound workspace becomes unavailable
- **WHEN** the directory of workspace A is missing when the app reopens
- **THEN** the tab stays bound to workspace A and shows the workspace as unavailable rather than rebinding to another workspace

### Requirement: The left sidebar collapses without changing work
The user SHALL be able to collapse and expand the left sidebar. The central area SHALL take its space, and groups, splits, tabs and focus MUST stay unchanged. The collapsed state SHALL be saved with the layout. Source: direction "Sidebars collapse independently without changing work" (left sidebar; the right sidebar arrives with its tools in M2).

#### Scenario: Collapse and expand
- **WHEN** the user collapses the left sidebar with two split groups open, then expands it again
- **THEN** the same groups, splits, tabs, active tabs and focused group are shown, and an expand control stays visible while collapsed

#### Scenario: Collapsed state survives reopen
- **WHEN** the user quits with the left sidebar collapsed and reopens the app
- **THEN** the sidebar is collapsed and its expand control is visible

### Requirement: Layout is saved through the host and restored on reopen
The desktop SHALL send each layout change to the host, which stores it in the local store. On reopen the workbench SHALL restore groups, splits and ratios, tabs and their bindings, each group's active tab, the focused group and the sidebar state. A tab the user closed MUST NOT return. Source: direction "App reopening restores the open layout and saved session identities" (layout part), D7.

#### Scenario: Quit and reopen
- **WHEN** the user arranges three tabs in two split groups, quits normally, and reopens Kumiko
- **THEN** the same groups, split direction and ratio, tabs, active tabs and focused group are shown

#### Scenario: Closed tab stays closed
- **WHEN** the user closes a tab, quits and reopens
- **THEN** the closed tab is not in the restored layout

#### Scenario: Desktop killed after a change
- **WHEN** the desktop is killed after a layout change and its save period has passed
- **THEN** the next launch restores the layout including that change

#### Scenario: Desktop killed during continuous changes
- **WHEN** the user keeps changing the layout without pause, for example dragging a split for ten seconds, and the desktop is killed during the drag
- **THEN** the next launch restores a layout no older than the maximum save age before the kill, not the layout from before the drag began

### Requirement: A failed layout save is visible
When the host cannot store a layout, the workbench SHALL keep the current layout in memory and show that layout changes are not being saved, with the host's reason. It SHALL try again on the next change or on Retry, and clear the notice after a successful save.

#### Scenario: Store write fails
- **WHEN** the host reports a store error for a layout save
- **THEN** the workbench shows "Layout not saved" with the reason and a Retry action, and the arrangement on screen is unchanged

#### Scenario: Host does not answer a save
- **WHEN** the host accepts a layout save request but sends no answer within the save deadline
- **THEN** the workbench shows "Layout not saved" with a reason saying the host did not answer, and a later change or Retry sends a new save

#### Scenario: Retry succeeds
- **WHEN** the user chooses Retry after a failed save and the host stores the layout
- **THEN** the notice is cleared and a reopen restores that layout

### Requirement: A layout that cannot be restored is reported, not hidden
When the saved layout fails validation, the workbench SHALL open an empty Personal layout and say the saved layout could not be restored and why. A tab of a view kind this build does not know SHALL be kept in place as an *unsupported view*, and saved back unchanged.

#### Scenario: Invalid saved layout
- **WHEN** the stored Personal layout fails validation at load
- **THEN** the workbench shows an empty Personal layout with a notice that the saved layout could not be restored and the validation reason, and the saved workspaces are still listed

#### Scenario: Unknown view kind
- **WHEN** the saved layout holds a tab whose view kind this build does not support
- **THEN** that tab is shown in its group as an unsupported view naming the kind, and the next save keeps it unchanged
