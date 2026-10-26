# Spec Delta

## Purpose

Keep freeform development in an explicit checkout and host context without turning shared planning membership into execution permission.

## ADDED Requirements

### Requirement: Work begins in the selected checkout
Kumiko SHALL use the currently selected checkout for task execution by default. It MUST NOT automatically create a branch, worktree, or separate workspace for every task.

#### Scenario: Begin work in the current checkout
- **WHEN** a user asks an agent to undertake work without requesting a separate workspace
- **THEN** the selected checkout is the default execution context.

#### Scenario: Another task uses the same checkout
- **WHEN** a user starts a different task without a request or identified need for separation
- **THEN** task creation alone does not create another branch, worktree, or workspace.

### Requirement: Separate workspaces are explicit freeform operations
Kumiko SHALL provide tools to create and open separate workspaces or worktrees when requested or identified as necessary by the agent or human. Branch and worktree operations SHALL remain part of freeform work rather than an enforced per-task pipeline.

#### Scenario: Separation is requested
- **WHEN** a user requests a separate worktree for task work
- **THEN** the workspace tools support creating and opening that worktree as the execution context.

#### Scenario: Workspace creation fails
- **WHEN** a requested workspace or worktree cannot be created
- **THEN** Kumiko reports the failed operation rather than presenting the nonexistent workspace as ready for execution.

### Requirement: Local working copies are not team replicas
Kumiko MUST keep personal checkouts, local branches, files, edits, and working-copy diffs on the user's PC rather than mirror them to the team server. Project/repository associations and shared activity MUST NOT upload or index their contents. Explicit user-authorized Git publication SHALL remain a separate repository operation, not permission to replicate the local working environment.

#### Scenario: Local changes remain personal
- **WHEN** a user edits files or creates a local branch in a checkout associated with a team project
- **THEN** that working-copy state remains local and is not uploaded or indexed by the team server.

#### Scenario: Git publication does not publish the working environment
- **WHEN** a user explicitly authorizes publishing selected commits to a Git remote
- **THEN** the authorized Git publication does not also upload uncommitted files, local-only branches, or working-copy diffs to the team server.

### Requirement: Planning context does not grant host authority
Kumiko MUST distinguish shared project context from the active execution host, repository checkout, and SCM context. Project-repository association, task editing, agent assignment, or team administrator status MUST NOT grant checkout access, credentials, or permission to execute on another person's host. Separate explicit host grants SHALL remain distinct from team authority and MUST NOT enable team mirroring of personal work.

#### Scenario: Authorized workspace execution
- **WHEN** a user has access to a project and separately has execution authority for its selected host and checkout
- **THEN** work uses that workspace's host, repository, and SCM context.

#### Scenario: Assignment without host permission
- **WHEN** a user, including a team administrator, assigns an agent to a task but lacks separate authority on the intended execution host
- **THEN** the assignment and team role do not authorize execution there or expose its checkout or credentials.
