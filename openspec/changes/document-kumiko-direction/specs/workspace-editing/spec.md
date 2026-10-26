# Spec Delta

## Purpose

Offer lightweight workspace browsing and text editing, with configurable external application handoff, rather than a full integrated development environment.

## ADDED Requirements

### Requirement: Workspace files are accessible for lightweight editing
Kumiko SHALL provide workspace file browsing and source editing for Markdown, configuration, and occasional code changes in the selected workspace.

#### Scenario: Open workspace content
- **WHEN** a user selects a Markdown, configuration, or code file from the active workspace
- **THEN** Kumiko exposes that file's source for lightweight editing in that workspace context.

#### Scenario: File is unavailable
- **WHEN** a selected file is missing or inaccessible in the active workspace
- **THEN** Kumiko reports that it cannot open the file rather than displaying unrelated workspace content as that file.

### Requirement: Markdown has source and rendered views
Kumiko SHALL provide Markdown source editing and a rendered preview without requiring WYSIWYG authoring.

#### Scenario: Preview Markdown
- **WHEN** a user opens Markdown content for editing
- **THEN** the user can access its source and rendered preview.

#### Scenario: Open non-Markdown configuration
- **WHEN** a user opens a configuration file rather than Markdown
- **THEN** the source remains accessible without requiring the content to be interpreted as Markdown or edited through a rendered document surface.

### Requirement: Editing remains a lightweight product surface
Kumiko MUST NOT require full-IDE facilities such as debugging, language-server features, refactoring, or an extension marketplace to perform its lightweight editing workflow.

#### Scenario: Edit without IDE services
- **WHEN** a user edits Markdown or configuration without IDE services installed
- **THEN** lightweight source editing remains available.

#### Scenario: Full-IDE feature is unavailable
- **WHEN** a user needs debugging or language-aware refactoring outside the lightweight surface
- **THEN** Kumiko does not present that unprovided functionality as part of its initial editor capabilities.

### Requirement: Open in supports configurable applications
Kumiko SHALL provide an Open in button/menu with VS Code and Zed presets and let users add other programs without limiting the list to editors. A preset MUST NOT imply that the application is installed or available on every host.

#### Scenario: User adds another program
- **WHEN** a user configures a custom application for opening workspace content
- **THEN** that application becomes a selectable Open in target alongside the initial VS Code and Zed presets.

#### Scenario: Selected application is unavailable
- **WHEN** a selected preset or custom program is unavailable for the target environment
- **THEN** Kumiko reports it unavailable rather than claiming it opened or silently launching a different program.

### Requirement: Application handoff preserves workspace identity
Kumiko SHALL let an explicitly selected Open in application receive the active workspace or selected file where supported. The target MUST retain its actual checkout and host identity rather than use a copied shadow workspace or silently substitute a local path for a remote target.

#### Scenario: Open the active workspace
- **WHEN** a user opens an accessible local workspace in a configured application
- **THEN** the handoff targets that same checkout and Kumiko's task and conversation remain available.

#### Scenario: Remote opening is unsupported
- **WHEN** the selected application has no supported opening mechanism for a remote workspace
- **THEN** Kumiko reports that handoff unavailable rather than opening an unrelated local path or a copied workspace.

### Requirement: Workspace file changes require explicit Save by default
Kumiko SHALL use explicit Save by default for workspace files. Typing changes the editor buffer, not the file on disk. The modified indicator SHALL represent unsaved differences, not mere disk activity; successful Save writes the buffer to its file and clears the indicator.

#### Scenario: Type without saving
- **WHEN** a user changes workspace file content in the editor
- **THEN** the buffer shows the changes and a modified indicator while the file on disk remains unchanged until Save.

#### Scenario: Save changed content
- **WHEN** a user explicitly saves changed workspace file content successfully
- **THEN** the file contains the saved buffer content and the editor no longer marks that content as modified.

#### Scenario: Return to unchanged content
- **WHEN** a user reverses all unsaved changes so the buffer again matches its unchanged file
- **THEN** the editor clears the modified indicator rather than treating prior typing alone as unsaved work.

### Requirement: Clean editors follow external file changes
Kumiko SHALL refresh an editor with no unsaved differences when an agent or another external actor changes its workspace file. The refresh MUST NOT mark the buffer modified or cause an unsaved-changes close prompt.

#### Scenario: Refresh after an external write
- **WHEN** an agent or another external actor writes a workspace file whose open editor has no unsaved differences
- **THEN** the editor displays the updated file content without a modified indicator.

#### Scenario: Close after external refresh
- **WHEN** a user closes an editor refreshed from external writes without making unsaved changes
- **THEN** it closes without an unsaved-changes prompt.

### Requirement: Closing unsaved editors requires a disposition
Kumiko SHALL offer Save, Don't Save, and Cancel when a user closes an editor with unsaved changes, including during app exit. Save SHALL close it only after a successful write; a failed Save SHALL show an error and keep the editor and unsaved content open, preventing ordinary exit until successful Save or explicit discard.

#### Scenario: Save before closing
- **WHEN** a user chooses Save in the unsaved-editor close prompt and the write succeeds
- **THEN** Kumiko saves the content and closes the editor.

#### Scenario: Discard before closing
- **WHEN** a user chooses Don't Save in the unsaved-editor close prompt
- **THEN** Kumiko closes the editor without writing its unsaved buffer to the file.

#### Scenario: Cancel closing
- **WHEN** a user chooses Cancel in the unsaved-editor close prompt
- **THEN** the editor stays open with its unsaved content intact.

#### Scenario: Save fails while closing
- **WHEN** a user chooses Save in the unsaved-editor close prompt but the write fails
- **THEN** Kumiko shows the error and leaves the editor open with its unsaved content intact rather than closing it or claiming it saved.

#### Scenario: Save before app exit
- **WHEN** a user chooses Save for an unsaved file during app exit and the write succeeds
- **THEN** Kumiko writes that buffer to its original file and treats that editor's exit decision as resolved without requiring another unsaved-changes prompt.

#### Scenario: Save fails during app exit
- **WHEN** a user chooses Save for an unsaved file during app exit but the write fails
- **THEN** Kumiko shows the error, keeps the editor and unsaved content open, and prevents ordinary exit until a later successful Save or explicit discard rather than treating the failed Save as permission to close.

#### Scenario: Cancel an editor's app-exit decision
- **WHEN** a user chooses Cancel for an unsaved editor during app exit
- **THEN** exit remains incomplete and that editor retains its unsaved content without undoing other explicitly completed saves or confirmed process stops.

### Requirement: Navigation preserves unsaved workspace buffers
Kumiko SHALL preserve unsaved workspace file edits when the user navigates between tabs, panes, workspaces, or projects, without saving or prompting merely because of navigation. Returning SHALL recover the same unsaved buffer associated with its original file and workspace.

#### Scenario: Switch tabs or panes
- **WHEN** a user leaves an unsaved workspace file editor for another tab or pane and returns
- **THEN** its unsaved content remains without navigation having saved it or prompted for a save decision.

#### Scenario: Switch workspaces or projects
- **WHEN** a user navigates to another workspace or project while a workspace file buffer is unsaved and later returns
- **THEN** the original file's unsaved buffer remains in its original workspace without navigation having saved it, prompted, or substituted another workspace's content.

### Requirement: Recovery drafts remain owner-local and separate from workspace files
Kumiko SHALL automatically protect unfinished workspace file edits with owner-local recovery drafts across crashes and reopening. Recovery SHALL restore unsaved content without silently writing the checkout or uploading drafts to team storage. Explicit Don't Save or bulk file discard MUST invalidate recovery of those discarded edits, not distinct chat drafts. Drafts MUST NOT be shared offline documents; failed recovery MUST NOT be reported as successful.

#### Scenario: Restore unfinished editing
- **WHEN** Kumiko reopens after a crash with a recoverable draft of an unfinished workspace file edit
- **THEN** it restores the draft as unsaved editor content for the original file and workspace rather than silently writing it to the checkout.

#### Scenario: Keep recovery private
- **WHEN** an owner-local recovery draft exists while a user works in a team project
- **THEN** it remains private to its owner and is not uploaded as shared team content or treated as an offline copy of a shared document.

#### Scenario: Recovery fails
- **WHEN** Kumiko cannot restore a recovery draft
- **THEN** it reports the recovery failure rather than claiming the unsaved content was restored or saved.

#### Scenario: Reopen after explicitly discarding a file edit
- **WHEN** a user chooses Don't Save for a workspace file and later reopens Kumiko or recovers after a crash
- **THEN** recovery does not resurrect that intentionally discarded edit or silently write it to the file.

#### Scenario: Bulk exit discards files but preserves chat drafts
- **WHEN** a user explicitly confirms bulk exit discarding unsaved workspace file edits and later reopens Kumiko or recovers after a crash
- **THEN** those discarded file edits do not return through recovery, while distinct local unsent chat drafts and saved conversation histories remain preserved.

### Requirement: External changes preserve unsaved edits for explicit resolution
Kumiko SHALL preserve an unsaved buffer when its workspace file changes externally and warn the user, offering Reload from Disk, Keep My Edits, and simple Compare. It MUST NOT automatically merge, retry a conflicting save, or silently overwrite either version. Saving retained edits over external content SHALL require a clear overwrite warning and the user's explicit Save.

#### Scenario: External write meets unsaved edits
- **WHEN** an agent or another external actor changes a workspace file whose editor has unsaved changes
- **THEN** Kumiko preserves the unsaved buffer, warns of the external change, and offers the resolution choices rather than replacing or automatically merging the buffer.

#### Scenario: Reload external content
- **WHEN** a user explicitly chooses Reload from Disk for an externally changed file with unsaved edits
- **THEN** the editor replaces its unsaved buffer with the file's current disk content and no longer marks that loaded content as modified.

#### Scenario: Retain local content
- **WHEN** a user chooses Keep My Edits after an external file change
- **THEN** Kumiko retains the unsaved buffer without writing it over the externally changed file.

#### Scenario: Compare differing content
- **WHEN** a user chooses Compare after an external file change
- **THEN** Kumiko presents a simple comparison of the unsaved buffer and disk content without automatically merging or writing either version.

#### Scenario: Save retained edits over external content
- **WHEN** a user elects to save retained edits over externally changed file content
- **THEN** Kumiko clearly warns that the save will overwrite that external content and writes only with the user's explicit Save, not through an automatic retry.
