# Spec Delta

## ADDED Requirements

### Requirement: The central area is a strip of tabs that contain panes
The central area SHALL show a strip of tabs. Each tab SHALL hold a split tree of panes, and each pane SHALL host exactly one view. The left sidebar, and any right sidebar, SHALL stay outside the tabs. A tab with one pane SHALL give its view the whole central area. View kinds are an open set: every kind SHALL be able to fill a tab or share a split tab with any other kind. Splits, moves and closes SHALL work the same for every kind. Source: user decision 2026-10-30.

#### Scenario: A terminal fills a tab
- **WHEN** the user opens a terminal in a new tab
- **THEN** the tab holds one pane, the terminal fills the whole central area, and the left sidebar stays beside the central area, unchanged

#### Scenario: Different view kinds side by side
- **WHEN** tab 1 holds a terminal, tab 2 holds the Workspace overview of workspace A, tab 1 is active, and the user moves tab 2 into a split to the right of tab 1
- **THEN** tab 1 shows the terminal and the Workspace overview side by side, each in its own pane, tab 2 is no longer in the strip, and the terminal keeps its shell and the overview stays bound to A

#### Scenario: A stored pane without a view
- **WHEN** the stored layout holds a pane with no view kind
- **THEN** the layout fails validation and is reported as a layout that cannot be restored, and no empty pane is shown

### Requirement: With no tabs, the central area shows the launcher
When no tab is open, the central area SHALL show the launcher: a prominent **New terminal** action and the + menu. **New terminal** SHALL open a new tab holding one terminal pane with the default shell profile, bound to the workspace selected in the sidebar, or to no workspace in Personal. The sidebars and the tab strip's + control SHALL stay visible.

#### Scenario: Close the last tab
- **WHEN** the user closes the only open tab
- **THEN** the central area shows the launcher with **New terminal** and the + menu, and the sidebar and its selection are unchanged

#### Scenario: New terminal from the empty area
- **WHEN** no tab is open, workspace A is selected in the sidebar, and the user chooses **New terminal**
- **THEN** a new tab opens and is active, holding one terminal pane bound to A and running the default profile in A's directory

#### Scenario: Terminals unavailable
- **WHEN** no tab is open and the connected host does not support terminals
- **THEN** **New terminal** is shown disabled with the reason, and the + menu's other entries work

### Requirement: Splitting a pane opens a shell beside it
**Split right** and **Split down** on a pane of any view kind SHALL place a new pane beside it, taking half of its space, running a new terminal with the default shell profile and bound to the split pane's workspace, or to none. The split SHALL NOT open a picker, and the new pane SHALL be focused. The new terminal is the only kind-specific rule of the pane model. A refused split SHALL leave the layout unchanged and say why.

#### Scenario: Split a terminal right
- **WHEN** the user chooses **Split right** on a terminal pane bound to workspace A
- **THEN** a new terminal pane opens to its right, focused, running the default profile in A's directory, and the first terminal keeps its shell and output

#### Scenario: Split a workspace overview down
- **WHEN** the user chooses **Split down** on a pane showing the Workspace overview of workspace B
- **THEN** a terminal pane opens below it, running the default profile in B's directory, and the overview pane keeps its view and binding

#### Scenario: Split at the pane limit
- **WHEN** the tab already holds the maximum number of panes per tab, or the working set the maximum number of panes, and the user chooses **Split right**
- **THEN** no pane is created, the layout is unchanged, and the split action reports the limit

#### Scenario: Default profile unavailable
- **WHEN** the default shell profile is unavailable and the user chooses **Split down**
- **THEN** no pane is created, the layout is unchanged, and the workbench says the default profile is unavailable, naming it, with a way to choose a default

#### Scenario: Host without terminals
- **WHEN** the connected host does not support terminals
- **THEN** **Split right** and **Split down** are shown disabled with the reason

### Requirement: Closing a pane gives its space to its sibling
Closing a pane SHALL remove it and its view, and its sibling SHALL take the space of their split. Closing the last pane of a tab SHALL close the tab. The workbench SHALL never hold an empty pane or a tab without panes. After a close, the most recently focused remaining pane of the tab, or of the next active tab, SHALL be focused.

#### Scenario: Close one of two panes
- **WHEN** the user closes the right pane of a tab split into two panes
- **THEN** the left pane fills the tab, the split is gone, and the left pane is focused

#### Scenario: Close a pane in a nested split
- **WHEN** a tab holds pane A beside a split of B above C, and the user closes B
- **THEN** C takes B's space, A and the ratio of the outer split are unchanged

#### Scenario: Close the last pane of the active tab
- **WHEN** the user closes the only pane of the active tab while two other tabs are open
- **THEN** the tab closes, and the tab holding the most recently focused remaining pane becomes active with that pane focused

#### Scenario: A terminal close cannot be confirmed
- **WHEN** the user confirms closing a terminal pane and the host reports that its cleanup could not be confirmed
- **THEN** the pane stays in place showing the error, and its split and sibling are unchanged

### Requirement: Panes and tabs move without changing their views
The user SHALL be able to move a pane to a new tab, and to move a whole tab into a split of the active tab, to the right or below. A move SHALL keep every view it moves, with its session, running process and workspace binding; it SHALL NOT start, stop or retarget anything. Moves SHALL work the same for every view kind. Source: direction "Tabs contain panes and rearranging preserves sessions" (amended from "Tab groups and splits remain independent", user decision 2026-10-30).

#### Scenario: Move a pane to a new tab
- **WHEN** the user chooses **Move to new tab** on a terminal pane running vim in a tab of three panes
- **THEN** a new tab right after the source tab holds that pane alone and is active, the source tab keeps the other two panes, and vim keeps running with its scrollback and binding

#### Scenario: Move a tab into a split
- **WHEN** tab 1 is active with two panes and the user chooses **Move into split below** on tab 2, which holds a Workspace overview bound to B
- **THEN** tab 1's area is split, its two panes above and the overview below, tab 2 is gone from the strip, the overview pane is focused and stays bound to B

#### Scenario: Nothing to move
- **WHEN** a pane is the only pane of its tab, or a tab is the active tab
- **THEN** **Move to new tab** on that pane, or **Move into split** on that tab, is shown disabled

#### Scenario: Move at the pane limit
- **WHEN** moving tab 2 into a split of tab 1 would put more than the maximum number of panes per tab in tab 1
- **THEN** the move is refused with the limit stated, and both tabs are unchanged

### Requirement: The launcher opens terminals
The + menu and the empty-area launcher SHALL offer **Terminal**, which opens a new tab holding one terminal pane with the default shell profile, bound to the workspace selected in the sidebar, or to none in Personal, and a way to choose another profile. Every Terminal launch SHALL open a new terminal; it SHALL NOT focus an existing one.

#### Scenario: Open a terminal from the launcher
- **WHEN** workspace A is selected in the sidebar and the user chooses **Terminal** from the + menu
- **THEN** a new tab opens, active and focused, holding one terminal pane bound to A and running the default profile in A's directory

#### Scenario: Open a second terminal
- **WHEN** the user chooses **Terminal** again
- **THEN** a second tab with a new terminal opens, and the first terminal is unchanged

#### Scenario: Choose a profile
- **WHEN** the user opens the launcher's profile choice and picks fish
- **THEN** the new terminal pane runs fish

#### Scenario: Terminals unavailable
- **WHEN** the connected host does not support terminals
- **THEN** the **Terminal** entry is shown disabled with the reason, and the other launcher entries work

### Requirement: Terminal panes are saved with the layout
A terminal pane SHALL be saved in the layout with its workspace binding and profile identity, and SHALL NOT save its output, scrollback, running programs or command history.

#### Scenario: Save a layout with terminals
- **WHEN** the layout is saved with two terminal panes, one alone in a tab and one in a split beside a Workspace overview
- **THEN** the stored layout holds each terminal pane's tab, place in its split tree, workspace binding and profile identity, and no terminal output

#### Scenario: A build without terminal support reads a terminal pane
- **WHEN** a layout with terminal panes is opened by a build that does not know the terminal view kind
- **THEN** the terminal panes are kept in place as *unsupported view* and are not dropped on the next save

### Requirement: Closing a pane or tab checks for live work
Closing a pane or a tab SHALL first collect every view in it that warns before closing, and SHALL show one confirmation naming all of them. Cancel SHALL leave the pane or tab, its panes and their arrangement unchanged.

#### Scenario: Close a tab holding live terminals
- **WHEN** the user closes a tab whose panes hold two terminals with live shells and a Workspace overview
- **THEN** one confirmation names both terminals, and on confirm the tab closes and the terminals' processes end

#### Scenario: Cancel closing a tab
- **WHEN** the user closes a tab with a live terminal and cancels the confirmation
- **THEN** the tab, its panes, their split arrangement and ratios are unchanged, and the terminal keeps running

#### Scenario: Close a pane holding a live terminal
- **WHEN** the user closes a pane whose terminal has a live shell
- **THEN** a confirmation names that terminal, and on confirm the pane closes and its sibling takes its space

#### Scenario: Tab with no live work
- **WHEN** the user closes a tab whose panes hold a Workspace overview and an ended terminal
- **THEN** the tab closes without a confirmation

### Requirement: A saved layout of the earlier format is discarded on upgrade
The first start of this build on a store holding a layout of the earlier tab-group format SHALL discard that layout once and open the first-launch layout. The saved workspaces and every other stored record SHALL be kept. There are no released builds or users of the earlier format (user decision 2026-10-30), so no conversion and no notice is given.

#### Scenario: Earlier layout discarded on upgrade
- **WHEN** the store holds a format 1 layout with two split groups and three tabs, and the user starts this build
- **THEN** the workbench shows Personal with no tabs and the launcher, as on first launch, with no restore notice, and the saved workspaces are still listed

#### Scenario: An earlier build meets the upgraded store
- **WHEN** a host that supports only the earlier store version starts on the upgraded store
- **THEN** it refuses the store as newer than supported without modifying it, and the desktop shows that error

### Requirement: The tab strip has a labeled click launcher
The tab strip SHALL show a visible + control that opens, on click, a labeled menu of the view kinds this build supports. A view chosen there SHALL open in a new tab, bound to the workspace selected in the sidebar, or to no workspace in Personal. Source: direction "The tab strip provides a labeled click launcher" (amended from "Each tab group provides a labeled click launcher", user decision 2026-10-30), D30.

#### Scenario: Open a view in a new tab
- **WHEN** workspace B is selected in the sidebar, a tab holding views bound to workspace A is active, and the user clicks + and chooses Workspace overview
- **THEN** a new tab opens, active, holding the Workspace overview bound to B, and the views bound to A are unchanged

#### Scenario: Launcher with no workspace selected
- **WHEN** Personal is selected in the sidebar with no workspace and the user opens +
- **THEN** the menu shows the view kinds, marks each one that needs a workspace as needing one with Open folder offered, and creates no tab until a workspace is chosen

#### Scenario: Pane limit reached
- **WHEN** the working set already holds the maximum number of panes and the user chooses a view kind from +
- **THEN** no tab is created and the launcher reports the limit

### Requirement: Opening an open item focuses its pane
Opening an item that already has a pane in the working set SHALL focus that pane, activating whichever tab holds it, rather than create a second view. Source: direction "Opening an existing item focuses it by default".

#### Scenario: Overview already open in another tab
- **WHEN** the Workspace overview of workspace A is open in a pane of tab 1, tab 2 is active, and the user opens the Workspace overview of A
- **THEN** tab 1 becomes active with that pane focused, and the number of tabs and panes is unchanged

#### Scenario: Item's pane was closed
- **WHEN** the user closed the pane holding the Workspace overview of workspace A and then opens it again
- **THEN** a new tab holding a new overview pane for A opens

## MODIFIED Requirements

### Requirement: First launch opens Personal without prompts
On a profile with no saved layout, Kumiko SHALL open the Personal working set with no tabs and the launcher. It MUST NOT ask for an account, project, repository, server or network connection first. Source: direction "Personal work does not require a project", D30, D41.

#### Scenario: Fresh profile
- **WHEN** the desktop starts on a profile with no store and the host connects
- **THEN** the workbench shows Personal with no tabs, the launcher with **New terminal** and its + menu, and an Open folder action, and no dialog or prompt is shown

#### Scenario: Host still reconciling
- **WHEN** the host reports that it is reconciling earlier processes at startup
- **THEN** the Personal workbench and its saved layout are shown at once, and the reconciliation state is shown without blocking the workbench

### Requirement: Workspace selection focuses existing work without retargeting
Selecting a workspace in the sidebar SHALL make it the selection that new tabs bind to, and SHALL focus that workspace's most recently focused pane, activating its tab, when it has one. It MUST NOT change the workspace binding of any existing view. Source: direction "Direct workspace navigation activates its parent context", D28, ADR 0004.

#### Scenario: Workspace with open tabs
- **WHEN** the user selects workspace B in the sidebar while a pane bound to B is open in a background tab
- **THEN** that tab becomes active with the pane focused, B is the sidebar selection, and every view keeps its workspace binding

#### Scenario: Workspace with no tabs
- **WHEN** the user selects workspace C, which has no open pane, while a tab holding panes bound to workspace A is active
- **THEN** C becomes the sidebar selection, the active tab and focused pane are unchanged, and the panes bound to A remain bound to A

### Requirement: A view's workspace binding never changes
A view's workspace binding SHALL be set when the view is created and kept for the view's whole life, including across save and restore. Focus changes, sidebar selection, splits, pane and tab closes, moves of panes and tabs, and sidebar collapse MUST NOT change it. A pane opened by a split SHALL take the split pane's binding. Source: ADR 0004 decision 3, D28.

#### Scenario: Binding after rearrangement and restore
- **WHEN** a pane bound to workspace A is moved to a new tab, that tab is moved into a split of a tab whose panes are bound to B, workspace B is selected, and the app is quit and reopened
- **THEN** the restored pane is bound to workspace A

#### Scenario: Bound workspace becomes unavailable
- **WHEN** the directory of workspace A is missing when the app reopens
- **THEN** the pane stays bound to workspace A and shows the workspace as unavailable rather than rebinding to another workspace

### Requirement: The left sidebar collapses without changing work
The user SHALL be able to collapse and expand the left sidebar. The central area SHALL take its space, and tabs, panes, splits and focus MUST stay unchanged. The collapsed state SHALL be saved with the layout. Source: direction "Sidebars collapse independently without changing work" (left sidebar; the right sidebar arrives with its tools in M2).

#### Scenario: Collapse and expand
- **WHEN** the user collapses the left sidebar with a tab split into two panes open, then expands it again
- **THEN** the same tabs, panes, splits, active tab and focused pane are shown, and an expand control stays visible while collapsed

#### Scenario: Collapsed state survives reopen
- **WHEN** the user quits with the left sidebar collapsed and reopens the app
- **THEN** the sidebar is collapsed and its expand control is visible

### Requirement: Layout is saved through the host and restored on reopen
The desktop SHALL send each layout change to the host, which stores it in the local store. On reopen the workbench SHALL restore the tabs in order, each tab's split tree with its ratios and panes, each pane's view and binding, the active tab, each tab's focused pane, the sidebar selection and the sidebar state. A pane the user closed MUST NOT return. Source: direction "App reopening restores the open layout and saved session identities" (layout part), D7.

#### Scenario: Quit and reopen
- **WHEN** the user arranges three tabs, one of them split into two panes, quits normally, and reopens Kumiko
- **THEN** the same tabs in the same order, split direction and ratio, panes, active tab and focused pane are shown

#### Scenario: Closed tab stays closed
- **WHEN** the user closes a tab, quits and reopens
- **THEN** the closed tab and its panes are not in the restored layout

#### Scenario: Closed pane stays closed
- **WHEN** the user closes a pane, quits and reopens
- **THEN** the closed pane is not in the restored layout and its sibling holds its space

#### Scenario: Desktop killed after a change
- **WHEN** the desktop is killed after a layout change and its save period has passed
- **THEN** the next launch restores the layout including that change

#### Scenario: Desktop killed during continuous changes
- **WHEN** the user keeps changing the layout without pause, for example dragging a split for ten seconds, and the desktop is killed during the drag
- **THEN** the next launch restores a layout no older than the maximum save age before the kill, not the layout from before the drag began

### Requirement: A layout that cannot be restored is reported, not hidden
When the saved layout fails validation, the workbench SHALL open Personal with no tabs and the launcher, and say the saved layout could not be restored and why. A pane holding a view of a kind this build does not know SHALL be kept in place as an *unsupported view*, and saved back unchanged.

#### Scenario: Invalid saved layout
- **WHEN** the stored Personal layout fails validation at load
- **THEN** the workbench shows Personal with no tabs and the launcher, with a notice that the saved layout could not be restored and the validation reason, and the saved workspaces are still listed

#### Scenario: Unknown view kind
- **WHEN** the saved layout holds a pane whose view kind this build does not support
- **THEN** that pane is shown in its place as an unsupported view naming the kind, it can be split, moved and closed like any other pane, and the next save keeps its view unchanged

## RENAMED Requirements

- FROM: `### Requirement: A tab's workspace binding never changes`
- TO: `### Requirement: A view's workspace binding never changes`

## REMOVED Requirements

### Requirement: Tab groups split and tabs move without changing their binding
**Reason**: User decision 2026-10-30: tabs contain panes, not the other way around. Tab groups, their own tab strips and empty groups are gone.
**Migration**: Splitting is "Splitting a pane opens a shell beside it", closing is "Closing a pane gives its space to its sibling", moving is "Panes and tabs move without changing their views", and the limit is the pane limit. Stored format 1 layouts are discarded by "A saved layout of the earlier format is discarded on upgrade".

### Requirement: Each tab group has a labeled click launcher
**Reason**: User decision 2026-10-30: there are no tab groups. The launcher belongs to the tab strip and to the empty central area.
**Migration**: See "The tab strip has a labeled click launcher" and "With no tabs, the central area shows the launcher". A new view binds to the sidebar selection instead of a group's context.

### Requirement: Opening an open item focuses it
**Reason**: User decision 2026-10-30: items open in panes inside tabs, not in group tabs.
**Migration**: See "Opening an open item focuses its pane", which keeps the same rule: an open item is focused wherever it is, never opened twice.
