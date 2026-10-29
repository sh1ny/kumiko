# execution-workspaces Specification

## Purpose
Let the user open a local directory, usually a checkout, as a workspace that keeps a stable identity and path as the execution context for the views and sessions bound to it (D4, D30, ADR 0001, ADR 0004).

## Requirements

### Requirement: A local directory opens as a workspace
The user SHALL be able to open a local directory as a workspace in Personal through a native directory picker. The host SHALL resolve it to a canonical path and directory identity, store it, and the sidebar SHALL list it by folder name and path. Kumiko MUST NOT create a branch, worktree or project to do so. Source: direction "Work begins in the selected checkout", D4, D30.

#### Scenario: Open a checkout
- **WHEN** the user chooses Open folder and picks an existing directory
- **THEN** the sidebar lists a new workspace with the directory's folder name and canonical path, and the focused group's context becomes that workspace

#### Scenario: Directory is not a repository
- **WHEN** the picked directory has no version control metadata
- **THEN** it opens as a workspace like any other directory, with no prompt to create a repository or project

#### Scenario: Picker cancelled
- **WHEN** the user cancels the directory picker
- **THEN** no workspace is added and the layout is unchanged

### Requirement: Opening a directory that is already open focuses its workspace
When the picked directory has the same directory identity as a saved workspace, whatever path led to it, Kumiko SHALL focus that workspace instead of adding another one.

#### Scenario: Same directory through another path
- **WHEN** workspace A is open and the user picks a symbolic link or junction that resolves to A's directory
- **THEN** no workspace is added, and workspace A is selected as if chosen in the sidebar

#### Scenario: Same path, directory replaced
- **WHEN** workspace A's directory was deleted and recreated at the same path, and the user picks that path
- **THEN** workspace A is kept, its stored identity is updated to the new directory's identity, and no second workspace with the same path is listed

### Requirement: A failed open is reported and adds nothing
When the picked path cannot be resolved as a directory, does not answer within the resolution timeout, or the workspace limit is reached, the host SHALL refuse the open with a reason. The desktop SHALL show that reason and add no workspace.

#### Scenario: Directory vanished before resolution
- **WHEN** the picked directory is deleted before the host resolves it
- **THEN** the desktop shows that the folder cannot be opened, with the path and reason, and the workspace list is unchanged

#### Scenario: Resolution does not answer
- **WHEN** resolving the picked path does not finish within the resolution timeout
- **THEN** the open is refused as timed out, other host requests keep being answered meanwhile, and no workspace is added

#### Scenario: Workspace limit
- **WHEN** Personal already holds the maximum number of workspaces and the user opens another folder
- **THEN** the open is refused with the limit stated and no workspace is added

### Requirement: Saved workspaces are checked again on every start
At each load the host SHALL resolve every saved workspace again. A workspace whose path no longer resolves to a directory, or does not answer within the resolution timeout, SHALL be shown as *unavailable* with the reason, and kept with its tabs. It SHALL show as available again once a later check resolves it.

#### Scenario: Directory missing at reopen
- **WHEN** workspace A's directory was moved away while Kumiko was closed and the app reopens
- **THEN** the sidebar shows A as unavailable with its path, its tabs are restored in place, and other workspaces are available

#### Scenario: Older check finishes after a newer one
- **WHEN** a startup check of workspace A is slow, the user chooses Check again on A, the second check finishes first, and the first finishes afterwards with a different result
- **THEN** workspace A shows the result of the second check, and its stored identity is the one the second check found

#### Scenario: Check finishes after its timeout
- **WHEN** a check of workspace A times out, A is shown as unavailable, and the resolution later returns a result
- **THEN** that late result changes neither A's shown state nor its stored identity

#### Scenario: Directory back
- **WHEN** the missing directory of workspace A is restored and the user chooses Check again on A
- **THEN** A shows as available and its tabs show the workspace overview again

### Requirement: Cleanup-unresolved state is shown on the workspace
A workspace whose directory is under *cleanup unresolved* (see `host-process-cleanup`) SHALL show that state in the sidebar and in its Workspace overview, linking to the cleanup list. The state SHALL clear when the cleanup is retried successfully or confirmed.

#### Scenario: Unresolved workspace at startup
- **WHEN** reconciliation leaves units of workspace A's directory unresolved
- **THEN** workspace A shows *cleanup unresolved* in the sidebar, and choosing it opens the cleanup list for that workspace

#### Scenario: Unresolved units from a replaced directory
- **WHEN** units of workspace A's old directory are unresolved, and A's directory was replaced at the same path so its identity changed
- **THEN** workspace A shows *cleanup unresolved*, its cleanup link lists the units recorded under the old directory, and confirming them clears A's state

#### Scenario: Cleanup confirmed
- **WHEN** the user confirms the processes of workspace A's directory are gone
- **THEN** the *cleanup unresolved* state on workspace A is cleared without restarting the app

### Requirement: A workspace without open tabs can be removed
The user SHALL be able to remove a workspace from Personal when no tab is bound to it. Removal SHALL delete only Kumiko's workspace record, never the directory or its files. A workspace that still has bound tabs SHALL NOT be removable until those tabs are closed.

#### Scenario: Remove an unused workspace
- **WHEN** the user removes workspace C, which has no open tab
- **THEN** C is no longer listed after the change and after a reopen, and its directory and files are unchanged

#### Scenario: Removed workspace was a group's context
- **WHEN** workspace C is the context of a tab group with no tabs, and the user removes C
- **THEN** that group has no workspace context, its launcher offers Open folder for views that need a workspace, and after a reopen no group refers to C

#### Scenario: Removal during a check
- **WHEN** the user removes workspace C while a check of C is still running
- **THEN** C stays removed, and the check's result is not shown

#### Scenario: Workspace still has tabs
- **WHEN** the user tries to remove workspace A while a tab is bound to it
- **THEN** A is not removed, and the action states that A's tabs must be closed first
