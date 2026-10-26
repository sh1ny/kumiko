# Spec Delta

## Purpose

Expose workspace-aware source control and revision-aware local review feedback through a dedicated right-side panel and matching agent tools, beginning with Git.

## ADDED Requirements

### Requirement: SCM panel focus does not retarget agent sessions
Kumiko SHALL provide a dedicated right-side SCM panel for the focused workspace's backend and branch or change. Agent SCM tools MUST retain their session's explicitly selected, authorized workspace and backend; navigation MUST NOT rebind them. UI and agent tools MUST use the same integration backend for the same workspace. Initial support SHALL be Git; deferred jj and GitButler operations MUST NOT be exposed as supported or silently treated as ordinary Git.

#### Scenario: Switch active Git workspace
- **WHEN** a user switches to another Git workspace
- **THEN** the right-side panel displays that workspace's SCM backend and active branch without rebinding existing agent sessions.

#### Scenario: Agent continues in another workspace
- **WHEN** a coding agent continues in its selected, authorized Git workspace A while its owner focuses workspace B
- **THEN** the SCM panel displays B, while that agent's SCM operations still target A's backend and checkout rather than B.

#### Scenario: Deferred backend is encountered
- **WHEN** a workspace uses an unsupported jj or GitButler integration
- **THEN** its deferred operations are not offered as supported Git operations.

### Requirement: Git state and diffs are inspectable
Kumiko SHALL expose Git status, staged, unstaged, and untracked changes, ahead/behind information, diffs, and conflicts for the active workspace.

#### Scenario: Inspect changed files
- **WHEN** a user opens the SCM panel for a changed Git checkout
- **THEN** the panel distinguishes staged, unstaged, and untracked files and provides relevant diffs and branch divergence information.

#### Scenario: Checkout contains conflicts
- **WHEN** the active checkout has unresolved Git conflicts
- **THEN** the SCM surface identifies those conflicts rather than presenting the checkout as conflict-free.

### Requirement: Git changes can be managed explicitly
Kumiko SHALL provide explicit stage, unstage, discard, and commit operations for the active Git workspace.

#### Scenario: Prepare and commit selected changes
- **WHEN** a user stages selected changes and commits them
- **THEN** the operations target the active checkout and their resulting Git state is available in its SCM surface.

#### Scenario: Commit is rejected
- **WHEN** Git rejects a requested commit
- **THEN** Kumiko reports the operation as unsuccessful rather than claiming a commit was created.

### Requirement: Git remotes are operable
Kumiko SHALL provide fetch, pull, and push operations against the active Git workspace's configured remotes.

#### Scenario: Transfer commits to the configured remote
- **WHEN** a user requests a permitted push from the active Git workspace
- **THEN** the operation uses that workspace's selected remote and reports its outcome.

#### Scenario: Remote operation fails
- **WHEN** fetch, pull, or push fails because the remote is unavailable or rejects access
- **THEN** Kumiko reports the failure without claiming synchronization succeeded.

### Requirement: Branches and worktrees have explicit controls
Kumiko SHALL provide Git branch creation, switching, and deletion, and worktree creation, opening, and removal as explicit workspace operations.

#### Scenario: Open a separate worktree
- **WHEN** a user creates and opens a Git worktree through workspace controls
- **THEN** the opened worktree has its own active workspace context and branch display.

#### Scenario: Git refuses a branch or worktree operation
- **WHEN** Git rejects a requested branch switch, deletion, or worktree removal
- **THEN** Kumiko reports the rejection and does not present the requested operation as completed.

### Requirement: Open pull requests match branch and target
Kumiko SHALL show open pull requests for the current branch, linking to the correct repository and instance on GitHub.com or GitHub Enterprise Server.

#### Scenario: Current branch has an open pull request
- **WHEN** the active branch has an open pull request on its configured GitHub instance
- **THEN** the SCM surface links to that pull request on the correct repository and instance.

#### Scenario: Branch has no matching open pull request
- **WHEN** the current branch has no matching open pull request
- **THEN** Kumiko does not substitute a pull request from another branch, repository, or GitHub instance.

### Requirement: In-app review collects local draft feedback
Kumiko SHALL open SCM changed-code diffs centrally and let users author local draft review comments on selected lines/ranges, distinct from project notes, agent thoughts, and source-file comments. Adding a note MUST NOT edit source files, send instructions, trigger or interrupt agent work, or upload notes/diffs to the team server. Hosted publication SHALL remain separately authorized, not working-copy synchronization.

#### Scenario: Collect feedback while inspecting a diff
- **WHEN** a user opens a changed-file diff centrally from SCM and comments on selected lines or ranges
- **THEN** the user-authored notes remain available together as local draft review feedback until explicit submission, not project notes, agent thoughts, or comments inserted into the source file.

#### Scenario: Note is added while an agent is working
- **WHEN** a user adds a draft note while an agent is active and a pull request exists
- **THEN** the note does not edit source files, trigger agent work, interrupt or instruct the agent, upload to the team server, or appear as a published pull-request comment.

### Requirement: Review feedback is explicitly sent through chat
Kumiko SHALL let users explicitly send collected local review notes together to their selected coding agent's owner-private conversation as a revision request through normal chat, without a mandatory review/approval pipeline or team upload. Older notes SHALL remain sendable with their original excerpt/revision and a changed-context warning, without mandatory manual reanchoring. Shared or hosted feedback MUST NOT itself authorize execution by another person's agent or grant permissions.

#### Scenario: Submit collected notes to the selected agent
- **WHEN** a user selects their coding agent and explicitly sends collected review notes
- **THEN** that agent's conversation receives the notes as a revision request and work continues through normal chat.

#### Scenario: Send notes after their reviewed code changes
- **WHEN** a user explicitly sends collected notes that are marked Changed since review
- **THEN** the selected agent's private conversation receives their original reviewed excerpts and revisions with a changed-context warning, without requiring manual reanchoring or substituting current code for the reviewed context.

#### Scenario: Teammate shares feedback without execution authority
- **WHEN** a teammate supplies project-shared or explicitly published hosted review notes but lacks authority to instruct the owner's coding agent
- **THEN** the shared notes do not become an authorized execution instruction for that agent.

### Requirement: Review notes retain the reviewed context
Kumiko SHALL retain each review note and its original reviewed code excerpt with workspace, file, revision, and selected line/range when later edits occur. Later edits MUST NOT silently relocate feedback onto unrelated code or substitute another workspace's content. Moving a note to a new selection SHALL require explicit user action, not a guessed or silent relocation.

#### Scenario: Send notes for unchanged reviewed content
- **WHEN** a user submits feedback for content that still matches the reviewed revision
- **THEN** the feedback includes the original reviewed code excerpt and identifies its workspace, file, revision, and annotated line or range.

#### Scenario: Reviewed code changes before feedback is used
- **WHEN** later edits change the annotated content or line positions
- **THEN** the note and original reviewed excerpt retain their workspace, file, revision, and annotated range rather than silently targeting unrelated current code.

#### Scenario: User moves a note to a new selection
- **WHEN** a user explicitly selects a new code range and chooses to move a note there
- **THEN** the note moves only to that user-selected range; later edits alone never authorize a guessed relocation.

### Requirement: Changed review context is visible without inferred resolution
Kumiko SHALL flag an affected note as Changed since review when its annotated code changes or its current location cannot be reliably established. Code edits MUST NOT imply that a note is addressed or resolved, and this flag MUST NOT impose a mandatory review or completion pipeline.

#### Scenario: Annotated code changes
- **WHEN** later edits alter a note's annotated code
- **THEN** the affected note displays Changed since review while retaining the note and its original reviewed context, without inferring that the feedback was addressed or resolved.

#### Scenario: Current location cannot be reliably established
- **WHEN** Kumiko cannot reliably establish where the reviewed range belongs in the current file
- **THEN** the note displays Changed since review rather than silently attaching to a guessed location or treating the feedback as resolved.

### Requirement: Reviewed and current code are distinct inspection targets
Kumiko SHALL let users open a note's reviewed version and inspect the current file separately, identifying their respective contexts without equating the original reviewed excerpt or revision with the current file.

#### Scenario: Inspect original feedback alongside current edits
- **WHEN** a user opens a note's reviewed version and separately inspects the current file after later edits
- **THEN** Kumiko distinguishes the original reviewed revision and excerpt from the current file content.

#### Scenario: Original version and current file differ
- **WHEN** a note's reviewed version differs from the current file or its current location is uncertain
- **THEN** opening the reviewed version does not silently substitute the current file, and inspecting the current file does not rewrite the note's original reviewed context.
