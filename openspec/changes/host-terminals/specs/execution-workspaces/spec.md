# Spec Delta

## MODIFIED Requirements

### Requirement: A local directory opens as a workspace
The user SHALL be able to open a local directory as a workspace in Personal through a native directory picker. The host SHALL resolve it to a canonical path and directory identity, store it, and the sidebar SHALL list it by folder name and path. Kumiko MUST NOT create a branch, worktree or project to do so. Source: direction "Work begins in the selected checkout", D4, D30.

#### Scenario: Open a checkout
- **WHEN** the user chooses Open folder and picks an existing directory
- **THEN** the sidebar lists a new workspace with the directory's folder name and canonical path, and that workspace becomes the sidebar selection, so new tabs bind to it

#### Scenario: Directory is not a repository
- **WHEN** the picked directory has no version control metadata
- **THEN** it opens as a workspace like any other directory, with no prompt to create a repository or project

#### Scenario: Picker cancelled
- **WHEN** the user cancels the directory picker
- **THEN** no workspace is added and the layout is unchanged

### Requirement: Saved workspaces are checked again on every start
At each load the host SHALL resolve every saved workspace again. A workspace whose path no longer resolves to a directory, or does not answer within the resolution timeout, SHALL be shown as *unavailable* with the reason, and kept with the views bound to it. It SHALL show as available again once a later check resolves it.

#### Scenario: Directory missing at reopen
- **WHEN** workspace A's directory was moved away while Kumiko was closed and the app reopens
- **THEN** the sidebar shows A as unavailable with its path, the panes bound to A are restored in place, and other workspaces are available

#### Scenario: Older check finishes after a newer one
- **WHEN** a startup check of workspace A is slow, the user chooses Check again on A, the second check finishes first, and the first finishes afterwards with a different result
- **THEN** workspace A shows the result of the second check, and its stored identity is the one the second check found

#### Scenario: Check finishes after its timeout
- **WHEN** a check of workspace A times out, A is shown as unavailable, and the resolution later returns a result
- **THEN** that late result changes neither A's shown state nor its stored identity

#### Scenario: Directory back
- **WHEN** the missing directory of workspace A is restored and the user chooses Check again on A
- **THEN** A shows as available and its Workspace overview panes show the workspace overview again

### Requirement: A workspace without bound views can be removed
The user SHALL be able to remove a workspace from Personal when no view is bound to it. Removal SHALL delete only Kumiko's workspace record, never the directory or its files. A workspace that still has bound views SHALL NOT be removable until the panes holding them are closed.

#### Scenario: Remove an unused workspace
- **WHEN** the user removes workspace C, which has no open pane bound to it
- **THEN** C is no longer listed after the change and after a reopen, and its directory and files are unchanged

#### Scenario: Removed workspace was a group's context
- **WHEN** workspace C is the sidebar selection, no view is bound to it, and the user removes C
- **THEN** Personal becomes the selection, the launcher offers Open folder for views that need a workspace, and after a reopen the layout does not refer to C

#### Scenario: Removal during a check
- **WHEN** the user removes workspace C while a check of C is still running
- **THEN** C stays removed, and the check's result is not shown

#### Scenario: Workspace still has tabs
- **WHEN** the user tries to remove workspace A while a pane is bound to it
- **THEN** A is not removed, and the action states that the panes bound to A must be closed first

## RENAMED Requirements

- FROM: `### Requirement: A workspace without open tabs can be removed`
- TO: `### Requirement: A workspace without bound views can be removed`
