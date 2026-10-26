# Spec Delta

## Purpose

Describe coordinated work across projects, repositories, tasks, milestones, and roadmaps without imposing an execution pipeline.

## ADDED Requirements

### Requirement: Projects represent coordinated efforts
Kumiko SHALL support finite or ongoing projects spanning one or more applications or repositories, with many-to-many project-to-repository associations.

#### Scenario: Cross-repository project
- **WHEN** a user organizes an effort involving multiple repositories
- **THEN** those repositories can belong to the same project with its own planning context.

#### Scenario: Repository participates in separate efforts
- **WHEN** two projects associate the same repository
- **THEN** their project planning context remains separate rather than merging because the repository is shared.

### Requirement: Native tasks own the work record
Kumiko SHALL provide native tasks containing descriptions, status, responsible human, acceptance criteria, discussion, and execution associations. Associations with private sessions or workspaces SHALL supply planning context without publishing private transcripts, terminal output, local files/diffs, or access to the underlying environment.

#### Scenario: Task connects planning and execution
- **WHEN** a user records work and associates a discussion or execution session
- **THEN** the task exposes its shared work details and applicable associations without publishing or granting access to private session or workspace content.

#### Scenario: Member follows a private execution association
- **WHEN** a project member or administrator attempts to retrieve another person's transcript, terminal output, or local edits through a task association
- **THEN** the association does not reveal that private content or cause it to be uploaded to the team server.

#### Scenario: Execution is not yet available
- **WHEN** a task has no execution session
- **THEN** its description, responsibility, acceptance criteria, and discussion remain usable without starting an agent.

### Requirement: New tasks require explicit creation
Kumiko SHALL open New task in a full central tab with its project visibly identified and, for Add subtask, the initiating task visibly identified as parent. Title SHALL be the only required input; other properties and description SHALL be available but optional. Opening or editing this tab SHALL NOT create or publish a task; only explicit Create task SHALL do so, subject to access and availability.

#### Scenario: Create with only a title
- **WHEN** an authorized user enters a title in New task and selects Create task while the required storage is available
- **THEN** the task is created in the visibly identified project without requiring other properties or a description.

#### Scenario: Add a subtask in context
- **WHEN** a user selects Add subtask on an existing task
- **THEN** a full central New task tab visibly inherits that task's project and identifies that task as parent, without creating a child until Create task succeeds.

#### Scenario: Opening and editing is not creation
- **WHEN** a user opens New task and enters a title, description, or properties without selecting Create task
- **THEN** no task is created or published and the entered content remains an unfinished creation draft.

#### Scenario: Title is missing
- **WHEN** a user attempts Create task without a title
- **THEN** no task is created and the entered optional content remains available while the missing title is identified.

### Requirement: Task properties save on committed selection
For an existing task, Kumiko SHALL save status, assignee, priority, dates, and labels when the user commits a selection. Hovering or browsing choices SHALL NOT change the stored value or initiate a save.

#### Scenario: Commit a task property
- **WHEN** an authorized user commits a new status, assignee, priority, date, or label selection on an existing task
- **THEN** that property enters the save flow without requiring a separate whole-task Save action.

#### Scenario: Browse without committing
- **WHEN** a user hovers over choices or browses a property's options and dismisses them without committing a selection
- **THEN** no save is initiated and the task retains its stored value.

### Requirement: Task text edits use explicit Save and Cancel
For an existing task's title, description, and acceptance criteria, Kumiko SHALL provide explicit Save and Cancel for each text edit. Typing SHALL NOT save the edit; Save SHALL submit it and Cancel SHALL discard that edit without changing the stored text.

#### Scenario: Save one text edit
- **WHEN** an authorized user edits a task's description and selects that edit's Save
- **THEN** the edited description enters the save flow without implicitly submitting unfinished title or acceptance-criteria edits.

#### Scenario: Cancel a text edit
- **WHEN** a user edits acceptance criteria and selects that edit's Cancel
- **THEN** the unfinished edit is discarded and the stored acceptance criteria remain unchanged.

#### Scenario: Typing does not publish text
- **WHEN** a user changes a task title without selecting its Save
- **THEN** the stored title remains unchanged and the unfinished title is not published as task content.

### Requirement: Task comments require explicit Post
Kumiko SHALL publish a task comment only through explicit Post, subject to access and availability. Unsent comment drafts SHALL remain owner-local and MUST NOT be uploaded to the team server or exposed as published task discussion.

#### Scenario: Post a comment
- **WHEN** an authorized user writes a task comment and selects Post while the required storage is available
- **THEN** the comment enters the publication flow and becomes published discussion only after success is confirmed.

#### Scenario: Unsent comment remains private
- **WHEN** a user types a comment without selecting Post and another project member reads the task discussion
- **THEN** the unsent draft remains owner-local, is not uploaded to the team server, and is not visible to the other member.

#### Scenario: Posting fails
- **WHEN** a comment Post fails
- **THEN** the comment draft is retained owner-locally with a failure indication rather than being shown as successfully published discussion.

### Requirement: Task save feedback reflects confirmed outcomes
Kumiko SHALL show Saving while a task creation, edit, or comment publication is pending, Saved only after persistence or publication is confirmed, and Couldn't save on failure. Failed entered content and selections SHALL be retained without being presented as saved or published.

#### Scenario: Save awaits confirmation
- **WHEN** a committed property change is awaiting confirmation
- **THEN** Kumiko shows Saving rather than Saved and shows Saved only when the change is confirmed.

#### Scenario: Text save fails
- **WHEN** saving an edited description fails
- **THEN** Kumiko shows Couldn't save and retains the edited description without claiming the stored description changed successfully.

#### Scenario: Task creation fails
- **WHEN** Create task fails before creation is confirmed
- **THEN** Kumiko shows Couldn't save and retains the creation draft, including its title and entered optional content, without presenting the task as successfully created.

### Requirement: Task navigation protects unfinished text
Kumiko SHALL preserve unfinished task creation text, task text edits, and comment drafts when switching tabs. Closing a tab containing unfinished text SHALL ask before discarding it; declining discard SHALL keep the tab and its unfinished text.

#### Scenario: Switch away from unfinished work
- **WHEN** a user switches away from and returns to a task or New task tab containing unfinished text
- **THEN** the unfinished creation text, task text edits, and comment draft remain available without being saved or posted by the switch.

#### Scenario: Decline discard on close
- **WHEN** a user closes a tab containing unfinished text and declines the discard prompt
- **THEN** the tab remains open with that text preserved and no implicit Save, Post, or Create task occurs.

#### Scenario: Confirm discard on close
- **WHEN** a user closes a tab containing unfinished text and confirms discarding it
- **THEN** the tab closes and its unfinished text is discarded without changing already saved task content or publishing the draft.

### Requirement: Shared task writes require current server access
Kumiko SHALL require current team-server availability and current authorization for shared task creation, edits, and comment publication. Unavailable or denied writes SHALL remain uncommitted with entered content retained. Kumiko MUST NOT silently queue these writes for later offline publication.

#### Scenario: Authorized shared write is confirmed
- **WHEN** an authorized participant submits a shared task edit while the team server is available and confirms the write
- **THEN** the edit becomes saved shared task content.

#### Scenario: Server is unavailable
- **WHEN** a participant submits shared Create task, Save, a committed property selection, or Post while the team server is unavailable
- **THEN** Kumiko reports Couldn't save, retains entered content without committing or publishing it, and does not silently queue publication when connectivity returns.

#### Scenario: Access has been revoked
- **WHEN** a participant submits a shared task write after their authorization has been revoked
- **THEN** the write is denied with Couldn't save, entered content is retained without being committed or published, and no later publication is silently queued.

### Requirement: Concurrent task edits preserve conflicting content
Kumiko SHALL reject stale same-field task writes from humans and authenticated API/agent tools at the authoritative save, including racing attempts. Comparing freshness and writing SHALL enforce this together, not through a racy read-before-write. Conflicts SHALL keep the current saved value and attempted value or draft visible and preserved without silently overwriting either or reporting Saved.

#### Scenario: No concurrent content change
- **WHEN** an authorized user saves a description whose saved content has not changed since the edit began and persistence succeeds
- **THEN** the submitted description becomes saved content and receives confirmed save feedback.

#### Scenario: Another participant changes the same content
- **WHEN** a user edits description v3 and submits it after another participant has saved description v4
- **THEN** Kumiko rejects the stale write, surfaces the conflict with saved v4 and the attempted draft visible and preserved, and neither overwrites v4 nor reports the conflicting write as Saved.

#### Scenario: Same-field attempts race
- **WHEN** two authorized human or authenticated API/agent attempts race to change the same task field from the same saved value
- **THEN** authoritative saving prevents both from silently overwriting that field; an attempt made stale by the other is rejected as a conflict with its attempted value and the current saved value preserved.

### Requirement: Task writes update only supplied fields
Task writes SHALL update only supplied fields. Independently committed changes to different fields SHALL preserve both changes without requiring a whole-task Save or treating an unrelated field change as a same-field conflict. This SHALL apply equally to human interactions and authenticated API/agent tools without changing explicit text Save/Cancel, committed property selections, or comment Post.

#### Scenario: Assignee and due date change independently
- **WHEN** authorized participants independently commit an assignee change and a due-date change from the same task view
- **THEN** both changes can save and remain stored without either write restoring the other's old value.

#### Scenario: API partial update preserves unrelated text
- **WHEN** an authenticated agent tool supplies only an assignee change after another participant has saved a new task description
- **THEN** saving the assignee preserves the new description rather than replacing it with an omitted or previously read value.

### Requirement: Conflicting task edits require manual reconciliation
Kumiko SHALL let the user inspect the current saved value alongside the retained attempted value or draft, reconcile manually, and explicitly save again. Every attempt SHALL recheck freshness at authoritative save; inspecting or reconciling SHALL NOT grant overwrite permission. Initial task editing SHALL NOT introduce live co-editing, automatic merge, or a force-overwrite bypass.

#### Scenario: Save a reconciled description
- **WHEN** a user inspects the saved description beside the conflicting draft, reconciles it manually, and explicitly selects Save without an intervening same-field save
- **THEN** the reconciled description enters the normal save flow and receives Saved only after authoritative confirmation.

#### Scenario: Reconciled draft becomes stale again
- **WHEN** another participant saves the description after the user inspects its current value but before the reconciled draft's next Save
- **THEN** the new stale attempt conflicts again, retaining the newer saved description and reconciled draft without silent overwrite or Saved feedback.

### Requirement: Task refresh preserves unfinished edits
Clean task views SHALL refresh to current saved values. Remote refresh SHALL NOT replace unfinished task edits, attempted selections, creation text, or comment drafts. Where saved values change beneath unfinished edits, Kumiko SHALL keep the local attempt separate from current saved content and enforce the same stale-write protection on submission.

#### Scenario: Clean task receives an update
- **WHEN** another participant changes a task field while the local view has no unfinished edit for that field
- **THEN** the view refreshes to the current saved value without creating an edit or requiring Save.

#### Scenario: Description refresh meets a dirty edit
- **WHEN** a remote description update arrives while the user has unfinished description text and an unsent comment
- **THEN** neither draft is replaced or published, the current saved description remains distinguishable from the local attempt, and a later stale description Save is rejected.

### Requirement: Failed and conflicting task drafts survive restart locally
Kumiko SHALL retain failed or conflicting task content and selections owner-locally across app restart, never uploading recovery drafts or automatically retrying or publishing them. Explicitly discarded drafts SHALL NOT return through recovery. Recovery SHALL NOT grant offline shared reads/writes or reveal current inaccessible content; shared submission SHALL still require current authorization, server availability, and freshness.

#### Scenario: Recover without submitting
- **WHEN** a user reopens Kumiko after a failed or conflicting task Save
- **THEN** the retained local attempt is recoverable as unsaved content without upload, automatic retry, or publication; any later submission still follows explicit Save or committed selection semantics and current access, server, and freshness checks.

#### Scenario: Discard survives restart
- **WHEN** a user explicitly discards a failed or conflicting task draft and then restarts Kumiko
- **THEN** recovery does not restore that discarded draft or change saved task content.

#### Scenario: Recovered draft is stale
- **WHEN** a user recovers a description draft after a newer description was saved and explicitly attempts Save
- **THEN** authoritative saving rejects the stale attempt and preserves both values without silently submitting recovery content over the newer saved version.

#### Scenario: Recovery does not restore shared access
- **WHEN** a retained task draft is recovered while the team server is unavailable or current task access is denied
- **THEN** only the owner-local draft is recoverable, current inaccessible shared content is not fetched or exposed, and no shared read or write is enabled or silently queued.

### Requirement: Milestones and roadmaps connect work to outcomes
Kumiko SHALL let projects optionally connect tasks and milestones to roadmap outcomes without requiring a fixed sprint or workflow-state model or an additional initiative layer. Milestone status and outcome SHALL remain independent of task completion percentage.

#### Scenario: Outcome spans multiple tasks
- **WHEN** a user organizes several tasks toward a milestone and roadmap outcome
- **THEN** the project represents those relationships.

#### Scenario: Project remains ongoing
- **WHEN** an ongoing project has work beyond a finite milestone
- **THEN** it can retain its roadmap and tasks without requiring the project itself to end.

### Requirement: Planning placement is optional and preserves task identity
Tasks SHALL exist and remain workable without a roadmap or milestone. Removing placement SHALL NOT delete a task. Users SHALL be able to move an existing task to a later milestone or roadmap Later without duplication or loss of task history. Roadmaps SHALL NOT require all unplanned tasks or mandatory Now/Next columns; deferred SHALL be a planning disposition, not a required task status.

#### Scenario: Work without roadmap placement
- **WHEN** a user creates or works on a task with no roadmap or milestone
- **THEN** the task remains a usable work record without requiring placement first.

#### Scenario: Remove a task from planning
- **WHEN** a user removes a task's milestone or roadmap placement
- **THEN** only that placement is removed and the task and its history remain accessible within their existing access boundaries.

#### Scenario: Move existing work later
- **WHEN** a user defers an existing task to a later milestone or roadmap Later
- **THEN** the same task retains its identity, content, status, and history without a duplicate task or a mandatory Deferred status.

#### Scenario: Roadmap omits unplanned work
- **WHEN** a project has tasks without roadmap placement and uses no Now/Next columns
- **THEN** the roadmap need not include those tasks or introduce those columns, and the tasks remain available outside the roadmap.

### Requirement: Milestone closure records explicit acceptance
Kumiko SHALL close a milestone only through an explicit authorized action recording outcome and acceptance notes with a remaining-work breakdown identifying deferred, unfinished, and canceled tasks. Closing SHALL NOT require 100% completion or automatically change task status, dates, or placement. Closing shared milestones SHALL require current server access and confirmed persistence.

#### Scenario: Close with remaining work
- **WHEN** an authorized user explicitly closes a milestone with outcome and acceptance notes while tasks remain deferred, unfinished, or canceled
- **THEN** confirmed closure records those notes and the remaining-work breakdown without forcing 100% or changing any task.

#### Scenario: Completion is not closure
- **WHEN** every task in an open milestone becomes completed without an explicit milestone close action
- **THEN** the milestone retains its status and outcome rather than closing automatically.

#### Scenario: Shared closure fails
- **WHEN** a shared milestone close is denied, conflicts, or cannot reach the current team server
- **THEN** closure is not reported as confirmed, the entered notes remain available, and no task is changed or closure silently queued for later.

### Requirement: Closed milestone assessments remain historical
Kumiko SHALL retain a closed milestone's recorded outcome, acceptance notes, and remaining-work assessment rather than silently rewriting them when tasks later complete or move. Moving a task out SHALL preserve its historical association and closure assessment, distinct from current placement. Closure SHALL NOT freeze the displayed percentage or prevent deferred/canceled inclusion settings from applying.

#### Scenario: Deferred task later completes
- **WHEN** a task recorded as deferred at milestone closure later becomes completed
- **THEN** its current status changes without silently changing the milestone's recorded closure assessment or outcome.

#### Scenario: Closed milestone work moves later
- **WHEN** a task from a closed milestone moves to a later milestone or roadmap Later
- **THEN** its current placement changes while its historical closed-milestone association and recorded closure assessment remain inspectable within existing access boundaries.

### Requirement: Milestone edits follow explicit save protections
Milestone prose SHALL use explicit Save and Cancel; typing SHALL NOT save it. Property selections SHALL save only when committed, as for task properties. Shared edits SHALL require current server availability and authorization, with no silent offline queue. Saving, Saved, and Couldn't save SHALL reflect pending, confirmed, and failed writes; failures SHALL retain inputs and conflicts SHALL preserve both versions without silent overwrite.

#### Scenario: Save prose and commit a property
- **WHEN** an authorized user selects Save on edited milestone acceptance notes or commits a target-date selection
- **THEN** that edit enters its save flow and shows Saved only after persistence is confirmed.

#### Scenario: Cancel prose or dismiss choices
- **WHEN** a user cancels edited milestone prose or dismisses property choices without committing
- **THEN** the stored value remains unchanged and no save is initiated for that edit.

#### Scenario: Shared milestone edit is unavailable or denied
- **WHEN** a shared milestone edit cannot reach the current team server or current authorization denies it
- **THEN** Couldn't save is shown, entered content and selections remain uncommitted, and no later publication is silently queued.

#### Scenario: Milestone prose conflicts
- **WHEN** another participant saves different milestone prose before a user's edited version is submitted
- **THEN** the conflict is surfaced, both the unfinished edit and saved version are preserved, and the conflicting write is not reported as Saved.

### Requirement: Completion visibility settings do not alter acceptance
Completion SHALL count each included task once: actually completed tasks over all included tasks. Deferred/canceled toggles SHALL change visibility and inclusion in both counts, not records, statuses, milestone outcome, or acceptance. Overview and detail SHALL use the same setting and show counts and excluded-work indication. These toggles SHALL remain distinct from arbitrary view filters and SHALL NOT suppress unfinished-descendant warnings.

#### Scenario: Include deferred work in a Done milestone
- **WHEN** a Done milestone has 10 tasks, 8 completed and 2 deferred, with deferred work included
- **THEN** overview and detail show 80% (8/10), visible deferred work, counts, and the inclusion setting while the milestone remains Done.

#### Scenario: Exclude deferred work from the same milestone
- **WHEN** the user excludes the 2 deferred tasks from that Done milestone's completion display
- **THEN** overview and detail show 100% (8/8) with an excluded-work indication, while all 10 task records, statuses, and the milestone's Done status, outcome, and recorded acceptance remain unchanged.

#### Scenario: Exclude canceled rather than complete it
- **WHEN** a milestone has 8 completed tasks and 2 canceled tasks not completed, and canceled work changes from included to excluded
- **THEN** visibility and completion change from 80% (8/10) to 100% (8/8), counts identify the 2 exclusions, and neither task completion nor milestone status or outcome changes.

#### Scenario: Nested records count once
- **WHEN** included milestone work contains a completed parent, completed child, and unfinished grandchild
- **THEN** completion counts three task records with two actually completed, not additional rolled-up totals, and the Done ancestors retain their unfinished-descendant warnings.

#### Scenario: View filter is not an exclusion setting
- **WHEN** a user applies an arbitrary view filter that hides unfinished work without changing deferred/canceled inclusion settings
- **THEN** that filter does not change those settings, masquerade as a deferred/canceled exclusion, rewrite recorded acceptance, or clear ancestor warnings.

### Requirement: Task work is freeform and explicitly updated
Kumiko SHALL let users ask agents in chat to undertake task work using their preferred workflow, without a mandatory Start action or enforced pipeline. An agent finishing its work MUST NOT automatically complete the task; task updates or closure require user instruction.

#### Scenario: Chat initiates work
- **WHEN** a user asks a coding agent to pick up a task
- **THEN** the conversation can guide the work without a separate mandatory Start action.

#### Scenario: Agent finishes before task acceptance
- **WHEN** an agent finishes its turn without an instruction to close the task
- **THEN** the task is not automatically marked complete.

#### Scenario: User completes only the parent
- **WHEN** a user explicitly marks a parent task Done while descendants remain unfinished
- **THEN** the parent becomes Done with the descendant warning, and no descendant status changes.

#### Scenario: Child completion leaves parent acceptance independent
- **WHEN** the last unfinished descendant becomes finished
- **THEN** its ancestors retain their existing statuses, and any Done ancestor's unfinished-descendant warning clears without automatically completing other ancestors.

### Requirement: Projects configure task statuses
Kumiko SHALL support project-configurable status names, colors, ordering, and custom statuses, with defaults including Backlog, To do, In progress, Blocked, and Done. Finished and unfinished meanings SHALL remain distinguishable for custom statuses without imposing a fixed status-category list.

#### Scenario: Project starts with common statuses
- **WHEN** a project begins using task statuses without customization
- **THEN** Backlog, To do, In progress, Blocked, and Done are available, with Done represented as finished.

#### Scenario: Project adapts its workflow
- **WHEN** a project customizes status names, colors, ordering, or adds a custom status
- **THEN** its tasks can use that configuration while finished and unfinished work remain distinguishable without requiring a sixth default status.

#### Scenario: Custom status participates in descendant warning
- **WHEN** a descendant uses a custom status with unfinished meaning
- **THEN** it contributes to unfinished-descendant warnings regardless of the status's display name or position.

### Requirement: Status presentation edits preserve identity
Renaming, recoloring, or reordering a status SHALL preserve its identity and existing task associations. These presentation edits MUST NOT move, recreate, or delete tasks or erase their prior change history.

#### Scenario: Rename and reorder a status in use
- **WHEN** an authorized user renames or reorders a status already used by tasks
- **THEN** those same task records remain attached to that status under its updated presentation, with prior task changes inspectable.

#### Scenario: Presentation changes do not imply a task transition
- **WHEN** an occupied status is recolored or moved beside a finished status in the configured order
- **THEN** no task changes its status identity or finished/unfinished meaning merely because of that presentation change.

### Requirement: Unused status removal changes no tasks
Kumiko SHALL allow authorized removal of an unused status without modifying tasks. A status SHALL qualify as unused only when it has no current task references at removal; a stale zero-use preview MUST NOT permit removal that leaves dangling task references.

#### Scenario: Remove a currently unused status
- **WHEN** an authorized user removes a status that still has no task references
- **THEN** the status is removed and task records and their histories remain unchanged.

#### Scenario: Status gains use after an unused preview
- **WHEN** a task begins using a status after a zero-use preview but before its removal applies
- **THEN** the stale removal is rejected rather than leaving a missing status reference, and removal requires the occupied-status migration flow.

### Requirement: Occupied status removal requires confirmed migration
Removing a status used by tasks SHALL require explicit selection of a valid surviving replacement in the same project, display of the affected task count, and confirmation. Confirmed removal SHALL move those tasks to the selected replacement and remove the old status without dangling references. Status settings MUST NOT delete tasks or erase task identity or change history.

#### Scenario: Confirm migration of twelve tasks
- **WHEN** an authorized user removes In review used by twelve tasks, selects In progress in that project, and confirms the displayed twelve-task migration
- **THEN** those same twelve tasks move to In progress, In review is removed, and their records and prior change histories remain available.

#### Scenario: Cancel occupied status removal
- **WHEN** a user cancels confirmation of an occupied status's removal
- **THEN** the old status and task assignments remain unchanged, with no migration or task deletion.

#### Scenario: Removal is requested without a replacement
- **WHEN** a user attempts to remove an occupied status without explicitly choosing a valid replacement
- **THEN** removal is rejected without choosing an implicit destination or deleting any task.

### Requirement: Status removal revalidates current configuration
Status removal and migration SHALL validate the selected replacement and relevant current configuration when applied. An invalid replacement or concurrent configuration change SHALL reject the stale request without applying a partial removal, leaving dangling task references, or selecting an implicit fallback.

#### Scenario: Selected replacement remains valid
- **WHEN** an authorized confirmed migration applies while its selected same-project replacement and relevant configuration remain valid
- **THEN** tasks reference the selected surviving status and the removed status has no dangling task references.

#### Scenario: Replacement is invalid or belongs to another project
- **WHEN** a requested replacement is missing, is the status being removed, or belongs to another project
- **THEN** the request is rejected without changing the old status or its task assignments.

#### Scenario: Configuration changes after confirmation
- **WHEN** relevant status configuration changes after a removal is confirmed but before it applies, including deletion of its selected replacement
- **THEN** the stale request is rejected without a partial migration or fallback destination, preserving a valid task/status state.

### Requirement: Task attributes describe different kinds of work
Kumiko SHALL support task types, priority, labels, assignee, start and due dates, and project-defined custom fields alongside the native work record. Optional attributes SHALL NOT prevent a task from being useful without estimates, time logs, scheduling dates, or an execution session.

#### Scenario: User classifies and schedules work
- **WHEN** a user records a task's type, priority, labels, assignee, dates, and project-defined fields
- **THEN** those values belong to that task's own work record and can be viewed and updated.

#### Scenario: Task has no optional planning values
- **WHEN** a task has no dates, estimate, time logs, or execution association
- **THEN** its description, status, assignee, acceptance criteria, and discussion remain independently usable.

### Requirement: Task discussion supports contextual collaboration
Kumiko SHALL support task comments and replies, mentions, attachments, and watching within the task's project and access boundaries. These collaboration actions MUST NOT automatically publish to linked external services or expose private agent conversations, terminal output, or working-copy content.

#### Scenario: Collaborate on an accessible task
- **WHEN** authorized project participants comment, reply, mention a participant, attach deliberately shared material, or watch a task
- **THEN** those actions remain associated with that task and visible only within the applicable access boundaries, without requiring email delivery.

#### Scenario: Task comment is not external publication
- **WHEN** a participant comments on a task linked to GitHub or Jira
- **THEN** the comment remains in Kumiko unless a separate authorized external publication is requested, and the task link does not publish any private development content.

### Requirement: Task change history is inspectable
Kumiko SHALL provide an inspectable history of task changes within the task's access boundaries. Task history MUST NOT grant access to private sessions or expose task records to users who cannot access them.

#### Scenario: Inspect changes to a task
- **WHEN** an authorized user opens the change history of a task after its status or planning attributes have changed
- **THEN** the recorded changes are available for inspection alongside that task's own work record.

#### Scenario: History is outside current access
- **WHEN** a user or agent without access to a task requests its change history
- **THEN** the history is not disclosed through a direct request, search, or a linked task.

### Requirement: Task templates are reusable starting points
Kumiko SHALL support reusable task templates for recurring work descriptions and planning attributes. Creating a task from a template SHALL produce an independently editable work record rather than a task whose later edits alter the template or other tasks.

#### Scenario: User reuses a task template
- **WHEN** a user creates a task from a reusable template
- **THEN** the task starts with the selected template content and can be adapted to the particular work.

#### Scenario: Task diverges from its template
- **WHEN** a user edits a task created from a template
- **THEN** the template and other tasks created from it retain their own content and attributes.

### Requirement: Subtasks are full tasks in an acyclic hierarchy
Kumiko SHALL let a task have direct child tasks and itself be a child, without a fixed product depth cap. Each subtask SHALL own its status, assignee, description, acceptance criteria, comments, and links rather than inherit a reduced checklist record. A task MUST NOT become its own parent or a descendant's child.

#### Scenario: Nested subtasks retain their own records
- **WHEN** a parent task contains a child task that contains another child task
- **THEN** all three remain full task records with independently editable status, assignee, description, criteria, comments, and links.

#### Scenario: User would create a hierarchy cycle
- **WHEN** a parenting operation would make a task its own parent or place it under one of its descendants
- **THEN** the operation is rejected and the existing hierarchy is preserved.

#### Scenario: Hierarchy grows beyond a fixed number of levels
- **WHEN** a user adds a child below an already deeply nested task without creating a cycle
- **THEN** the relationship is not rejected solely because it crosses a fixed product depth limit.

### Requirement: Within-project reparenting preserves the subtree
Moving a task under another parent in the same project SHALL keep its descendant subtree attached. The move SHALL preserve every affected task's identity, content, status, assignee, dates, milestone associations, and history. Circular moves and stale moves against changed hierarchy SHALL be rejected without changing the existing hierarchy.

#### Scenario: Move a multilevel subtree
- **WHEN** a user moves a task with children and grandchildren under another parent in the same project
- **THEN** only the moved task's parent relationship changes; its children and grandchildren remain attached through their existing relationships, and every affected task retains its identity, content, status, assignee, dates, milestone associations, and history.

#### Scenario: Move would create a cycle
- **WHEN** a user attempts to move a task under itself or one of its descendants
- **THEN** the move is rejected without changing any existing parent or descendant relationship.

#### Scenario: Hierarchy changes before a move applies
- **WHEN** another participant changes the relevant hierarchy after a move is prepared but before it applies
- **THEN** the stale move is rejected without overwriting the changed hierarchy or partially moving the subtree.

### Requirement: Archiving a task defaults to the selected task only
Default task archive SHALL archive only the selected task, without cascading to descendants or changing their relationships. Children SHALL remain available within current access, and opening a child SHALL identify its parent as archived. Archive SHALL NOT complete or reopen tasks or alter their other fields or history.

#### Scenario: Archive a parent with nested work
- **WHEN** a user archives only a selected parent containing children and grandchildren
- **THEN** only the parent is archived; its descendants remain available within current access with their relationships, independent statuses, other fields, and history intact.

#### Scenario: Open a child of an archived parent
- **WHEN** a user opens an accessible child whose parent is archived
- **THEN** its detail identifies the parent as archived without granting access to otherwise inaccessible parent content.

### Requirement: Deleting a task preserves its descendants by promotion
Default task deletion SHALL delete only the selected task and promote its direct children to its former parent, or to top level if it had no parent. Deeper descendant relationships SHALL remain intact. Surviving tasks SHALL retain their identities, content, independent statuses, assignees, dates, milestone associations, and history without duplicate recreation.

#### Scenario: Delete an intermediate task
- **WHEN** a user confirms deletion of only a selected task that has a parent, direct children, and grandchildren
- **THEN** the selected task is deleted, its direct children become children of its former parent, and grandchildren remain attached to their existing parents without recreating survivors or changing their other fields or history.

#### Scenario: Delete a top-level task
- **WHEN** a user confirms deletion of only a top-level task with children and deeper descendants
- **THEN** its direct children become top-level tasks, deeper relationships stay intact, and survivors retain their identities, fields, history, and independent statuses without forced completion or reopening.

### Requirement: Whole-subtree archive and deletion require explicit scope
Whole-subtree archive or deletion SHALL require an explicitly named scope, the affected task count, and confirmation before applying to the selected task and all descendants. Nesting alone SHALL NOT imply a cascade. Cancellation or missing confirmation SHALL leave all tasks unchanged; archive SHALL NOT complete or reopen tasks.

#### Scenario: Confirm whole-subtree archive
- **WHEN** a user explicitly selects whole-subtree archive for a parent with two children and one grandchild and confirms the displayed four-task scope
- **THEN** those four tasks are archived with their relationships, independent statuses, other fields, and history intact.

#### Scenario: Confirm whole-subtree deletion
- **WHEN** a user explicitly selects whole-subtree deletion for a parent with two children and one grandchild and confirms the displayed four-task scope
- **THEN** those four tasks are deleted rather than promoting the selected parent's children, without deleting tasks outside that subtree.

#### Scenario: Cancel a subtree operation
- **WHEN** a user cancels confirmation of a whole-subtree archive or deletion
- **THEN** no task is archived or deleted and all existing relationships and statuses remain unchanged.

#### Scenario: Subtree operation lacks confirmation
- **WHEN** a user selects whole-subtree archive or deletion but has not confirmed its named scope and affected task count
- **THEN** the operation does not apply and no task or relationship changes merely because tasks are nested.

### Requirement: Task detail navigates immediate hierarchy relationships
Kumiko SHALL show a task's direct children in its detail and provide navigation to its immediate parent when present. Large direct-child lists SHALL be bounded or paged; viewing a task SHALL NOT require fetching or expanding its entire descendant tree.

#### Scenario: User follows a nested relationship
- **WHEN** a user opens a task that has both a parent and children
- **THEN** the detail exposes its immediate parent and direct children, and selecting either opens that task's own detail.

#### Scenario: Task has many children and deeper descendants
- **WHEN** a user opens a task with a large direct-child list and further descendants
- **THEN** the direct-child list is bounded or paged, and descendants are not automatically expanded as a complete tree.

#### Scenario: Top-level task has no children
- **WHEN** a user opens a task without a parent or children
- **THEN** its work record remains usable without a fabricated parent or child relationship.

### Requirement: Done ancestors warn about unfinished descendants
A Done task with unfinished descendants at any depth SHALL retain its actual Done status and show an amber or yellow warning distinct from normal green Done, with accessible non-color text or icon and an unfinished-descendant count. Each unfinished task SHALL count once per ancestor's warning, not again through rolled-up intermediate counts.

#### Scenario: Done child contains an unfinished grandchild
- **WHEN** a Done task has a Done child whose child is In progress
- **THEN** both Done ancestors retain Done and show the warning with an unfinished-descendant count of one, while the grandchild remains In progress.

#### Scenario: User completes a parent before its children
- **WHEN** a parent is explicitly marked Done while a direct child is unfinished
- **THEN** completion is allowed, the parent displays the warning instead of normal green Done, and no child is completed or parent reopened automatically.

#### Scenario: Intermediate unfinished parent also has unfinished work
- **WHEN** a Done ancestor has one unfinished child and that child has one unfinished child
- **THEN** the Done ancestor's warning counts two distinct unfinished descendants rather than counting an intermediate roll-up as additional tasks.

#### Scenario: All descendants become finished
- **WHEN** a Done task no longer has unfinished descendants
- **THEN** its warning clears and the ordinary Done presentation returns without changing its actual status.

### Requirement: Description checklists remain smaller steps
Kumiko SHALL support simple checklists within task descriptions for smaller steps without requiring full subtasks. Agent execution plans or checklists SHALL NOT automatically become project tasks, and checklist completion SHALL NOT automatically change task or hierarchy statuses.

#### Scenario: User records small steps
- **WHEN** a user adds and checks off description checklist items
- **THEN** those items remain simple steps within the task rather than acquiring separate task records.

#### Scenario: Agent creates an execution checklist
- **WHEN** an agent plans its execution with a checklist
- **THEN** that plan does not automatically create project tasks or subtasks.

#### Scenario: Checklist finishes before task acceptance
- **WHEN** every description checklist item is checked without an instruction to complete the task
- **THEN** the task and its parent retain their existing statuses.

### Requirement: Task links express work relationships without automating workflow
Kumiko SHALL support dependency, related-work, and duplicate links between tasks, distinct from parent-child relationships. Recording these links SHALL NOT by itself reschedule tasks, change statuses, or complete linked work.

#### Scenario: User records related and dependent work
- **WHEN** a user links tasks as dependencies, related work, or duplicates
- **THEN** the relationship is visible and navigable without turning either task into the other's child.

#### Scenario: Dependency dates or completion change
- **WHEN** a linked dependency changes dates or becomes finished without an instruction to update other work
- **THEN** linked tasks retain their own dates and statuses rather than being automatically rescheduled or completed.

### Requirement: Task views present the same work with saved perspectives
Kumiko SHALL support board, table, and timeline task views with filtering, grouping, sorting, configurable displayed fields, and saved views/filters. Task overviews SHALL present matching accessible tasks flat rather than automatically expanding hierarchical trees. Changing views SHALL preserve each task's own record; opening a view or choosing a default SHALL be personal navigation and SHALL NOT switch another user's view.

#### Scenario: User changes perspective on work
- **WHEN** a user changes between board, table, and timeline views using a saved filter, grouping, and sort
- **THEN** the views present the applicable tasks from the same work records using the chosen perspective.

#### Scenario: Filter matches parent and nested descendant
- **WHEN** an overview's filter matches a parent and a deeply nested descendant but not an intermediate task
- **THEN** the matching tasks appear as flat results without automatically adding or expanding the intermediate task or entire hierarchy.

#### Scenario: Undated task is viewed on a timeline
- **WHEN** a matching task has no scheduling dates
- **THEN** the view does not invent dates or silently schedule the task to place it on the timeline.

### Requirement: Saved views have explicit personal and project scope
Saved views SHALL be personal by default. Publishing a view to a project SHALL require an explicit action and current applicable permissions. A personal copy of a shared view SHALL be independent. View definitions and results SHALL respect current access and MUST NOT disclose inaccessible task data or private execution content. Deleting a view SHALL NOT delete its tasks.

#### Scenario: Save and publish deliberately
- **WHEN** a user saves a new view and later explicitly publishes it with the applicable project permissions
- **THEN** it remains personal until that publication succeeds and then becomes available within the project's access boundaries.

#### Scenario: Publication lacks permission
- **WHEN** a user without the applicable project permission attempts to publish a personal view
- **THEN** publication is denied without exposing the personal definition as a project view.

#### Scenario: Personal copy diverges
- **WHEN** a user updates a personal copy of a shared view
- **THEN** the shared definition and other users' copies remain unchanged, and later shared updates do not silently rewrite the personal copy.

#### Scenario: View cannot bypass access
- **WHEN** a user opens a saved view whose definition or results would reveal inaccessible task data or private execution content
- **THEN** that content is not disclosed through the definition, results, counts, or navigation.

#### Scenario: Delete a saved perspective
- **WHEN** an authorized user deletes a saved view
- **THEN** that view is removed without deleting or changing the tasks it previously displayed.

### Requirement: Saved view definitions change only through explicit update
Temporary filter, grouping, sorting, or displayed-field changes SHALL NOT rewrite a saved view's definition until the user explicitly updates it with applicable permissions. Opening or selecting a default view SHALL change only that user's navigation preference, not the saved definition or another user's active or default view.

#### Scenario: Temporarily explore a saved view
- **WHEN** a user changes filters, grouping, sorting, or displayed fields without explicitly updating the saved view
- **THEN** those changes affect the current perspective without rewriting the saved definition.

#### Scenario: Explicitly update a saved definition
- **WHEN** a user with applicable permissions explicitly updates a saved view after changing its configuration
- **THEN** the saved definition adopts that configuration without changing task records.

#### Scenario: Default is personal navigation
- **WHEN** a user opens a project view or selects it as their default
- **THEN** that user's navigation changes without switching another user's active view or default or modifying the saved definition.

### Requirement: Calendar presents internal work dates
Kumiko SHALL provide an internal calendar for enabled dated tasks, milestones, or cycles, with filters and navigation to the underlying work using their date-only planning values. Calendar SHALL NOT require external calendar accounts or provide Google or Outlook synchronization, meeting scheduling, or meeting invitations.

#### Scenario: User follows a work deadline
- **WHEN** a user filters the calendar to an enabled dated work source and selects an entry
- **THEN** the calendar shows the applicable internal work dates or deadlines and opens the corresponding work record.

#### Scenario: Milestones supply dates without tasks
- **WHEN** Tasks is disabled but an enabled milestone source supplies dates
- **THEN** the calendar can display those milestones without requiring Tasks or an external calendar account.

#### Scenario: Work has no date
- **WHEN** an enabled task, milestone, or cycle lacks a calendar-relevant date
- **THEN** the calendar does not invent a date or create an external event for that work.

### Requirement: Planning dates are date-only values
Planning start, due, target, and cycle dates SHALL be date-only values without a time picker, implicit midnight, or timezone-dependent day shift. Calendar and other planning views SHALL preserve the selected day across timezones. Activity timestamps and time logging SHALL remain separate from planning dates rather than assigning times to them.

#### Scenario: Select and view a planning date
- **WHEN** a user selects a task due date, milestone target date, or cycle start or end date
- **THEN** the choice requires only a calendar date without a time picker or implicit midnight.

#### Scenario: View the same date in another timezone
- **WHEN** a planning date selected as 21 October is viewed in a different timezone
- **THEN** the calendar and other planning views still show 21 October rather than the previous or following day.

#### Scenario: Activity and duration remain separate
- **WHEN** a dated task receives a timestamped activity or a time log
- **THEN** that activity timestamp or logged time remains separate and does not add a time of day to or shift the task's planning dates.

### Requirement: Optional cycles organize timeboxed task work
Kumiko SHALL offer optional sprint-like cycles with a goal, timebox, linked tasks, and visible progress. Tasks, milestones, and roadmaps SHALL remain usable without cycles; a cycle's timebox or progress SHALL NOT itself complete or reschedule linked tasks or trigger another cycle.

#### Scenario: Project uses a cycle
- **WHEN** a user creates a cycle with a goal and timebox and links tasks
- **THEN** the cycle exposes its goal, dates, linked work, and progress.

#### Scenario: Cycle timebox elapses with unfinished work
- **WHEN** a cycle's end date passes while linked tasks remain unfinished
- **THEN** Kumiko indicates that the timebox has elapsed without finishing the cycle, starting another cycle, or completing or rescheduling any linked task.

#### Scenario: Project plans without cycles
- **WHEN** a project does not use cycles
- **THEN** tasks can still connect to milestones and roadmap outcomes without being assigned to a cycle.

### Requirement: Cycle start and finish require explicit actions
Kumiko SHALL start and finish cycles only through explicit authorized actions, not through dates or task progress. Finishing SHALL be permitted with unfinished tasks and SHALL show a finished/unfinished task breakdown before requiring confirmation. Cancellation or missing confirmation SHALL leave the cycle unfinished and its tasks unchanged. Finishing a cycle SHALL NOT itself claim that an unfinished goal was achieved.

#### Scenario: Explicitly start a cycle
- **WHEN** an authorized user explicitly starts a cycle and persistence succeeds
- **THEN** the cycle is shown as started without changing linked task statuses, assignees, dates, or milestone associations.

#### Scenario: Scheduled start date arrives
- **WHEN** a cycle's start date arrives without an explicit start action
- **THEN** the cycle does not start automatically and its linked tasks remain unchanged.

#### Scenario: Confirm finish with remaining work
- **WHEN** an authorized user requests Finish for a cycle containing finished and unfinished tasks and confirms after seeing their breakdown
- **THEN** successful persistence finishes the cycle without requiring every task to be finished.

#### Scenario: Cancel cycle finish
- **WHEN** a user cancels after reviewing the finished/unfinished task breakdown
- **THEN** the cycle remains unfinished and no linked task changes.

#### Scenario: Finish lacks confirmation
- **WHEN** a user requests Finish but has not confirmed the displayed finished/unfinished task breakdown
- **THEN** the cycle remains unfinished and no linked task changes.

#### Scenario: Goal remains unfinished at closure
- **WHEN** a cycle is explicitly finished while its goal remains unachieved
- **THEN** closure does not present that goal as achieved merely because the cycle is finished.

#### Scenario: Edit cycle dates
- **WHEN** a user changes a cycle's date-only start or end date, including to a past date
- **THEN** the selected calendar dates retain their date-only semantics without starting or finishing the cycle, starting another cycle, or completing or rescheduling linked tasks.

### Requirement: Cycle closure preserves task placement by default
Finishing a cycle SHALL by default leave every linked task associated with that closed cycle and preserve each task's own status, assignee, dates, and milestone associations. Closure SHALL NOT imply carry-forward.

#### Scenario: Close without moving work
- **WHEN** an authorized user confirms cycle finish without separately confirming a carry-forward operation
- **THEN** finished and unfinished tasks alike remain linked to the closed cycle with their own statuses, assignees, dates, and milestone associations unchanged.

### Requirement: Cycle carry-forward uses explicit task and destination selection
Carry-forward SHALL separately require selected unfinished tasks, a destination, affected count, and confirmation. It SHALL move existing records without cloning, preserve prior cycle association in inspectable history and other fields/relationships, and leave unselected tasks unchanged. Subtasks MUST be explicitly selected, not inferred from a parent. Cancellation or missing confirmation/destination SHALL leave all tasks unchanged.

#### Scenario: Carry forward a selected subset
- **WHEN** an authorized user selects two of three unfinished tasks from a closed cycle, selects a destination cycle, and confirms the displayed two-task scope
- **THEN** successful persistence moves those two existing records to that destination without cloning or changing their other attributes, retains their previous cycle association in history, and leaves the unselected task linked to the closed cycle.

#### Scenario: Cancel carry-forward
- **WHEN** a user selects unfinished tasks and a destination but cancels carry-forward confirmation
- **THEN** all tasks retain their existing cycle associations and other attributes.

#### Scenario: Carry-forward lacks confirmation
- **WHEN** unfinished tasks and a destination cycle have been selected but the affected task count has not been confirmed
- **THEN** no task is moved or cloned.

#### Scenario: Carry-forward lacks destination
- **WHEN** unfinished tasks are selected without a destination cycle
- **THEN** carry-forward does not move any task or choose a destination automatically.

#### Scenario: Move a parent without its subtasks
- **WHEN** a user confirms carry-forward of an unfinished parent without explicitly selecting its children or grandchildren
- **THEN** only that parent changes cycle; its descendants retain their existing cycle associations and all parent-child relationships remain intact.

#### Scenario: Move an explicitly selected subtask
- **WHEN** a user confirms carry-forward of an unfinished subtask without selecting its parent
- **THEN** only that subtask changes cycle, with its parent relationship preserved and the unselected parent unchanged.

### Requirement: Shared cycle actions require current authoritative access
Shared cycle start, finish, and carry-forward SHALL require current team-server availability, current authorization for the affected cycle and task records, and authoritative confirmation before being reported as successful. Denied or unavailable actions SHALL remain uncommitted without silently queued execution. Cycle work, breakdowns, and historical associations SHALL remain within current access boundaries.

#### Scenario: Shared action is confirmed
- **WHEN** a currently authorized participant explicitly starts or confirms finishing a shared cycle or carrying selected tasks forward and the team server confirms persistence
- **THEN** Kumiko reports success for that action without implying any unrequested task or cycle changes.

#### Scenario: Server is unavailable for cycle action
- **WHEN** a participant attempts shared cycle start, finish, or carry-forward while the team server is unavailable
- **THEN** the action remains uncommitted, no cycle or task change is reported as confirmed, and execution is not silently queued for reconnection.

#### Scenario: Access is revoked before commitment
- **WHEN** current authorization for an affected cycle or selected task has been revoked before a shared cycle action is committed
- **THEN** the action is denied without changing those records, reporting success, or disclosing currently inaccessible work through its breakdown or history.

### Requirement: Task dashboards distinguish records from descendant summaries
Kumiko SHALL offer task dashboards and statistics with filtered flat task results. A task's own status and attributes SHALL remain distinct from descendant summaries; task counts SHALL count each included record once, without counting rolled-up parent totals again as additional tasks.

#### Scenario: Dashboard summarizes nested work
- **WHEN** a dashboard includes a Done parent, its Done child, and an In progress grandchild
- **THEN** it counts three task records with two Done and one In progress, while descendant warnings remain supplementary indicators rather than extra tasks or replacement statuses.

#### Scenario: Filter excludes ancestors
- **WHEN** only a nested descendant matches a dashboard filter
- **THEN** the filtered task count includes that matching record without automatically adding ancestors, siblings, or their rolled-up totals.

#### Scenario: User inspects a parent's summary
- **WHEN** a dashboard shows a parent's own values beside descendant progress or counts
- **THEN** the presentation distinguishes the parent's record from its descendant aggregate rather than replacing its own status, estimate, or time log with the aggregate.

### Requirement: Estimates are optional task planning information
Kumiko SHALL support optional task estimates independently of time logging. Tasks without estimates SHALL remain usable, and an absent estimate SHALL remain distinguishable from a recorded zero rather than being invented from descendants or elapsed time.

#### Scenario: User estimates without tracking time
- **WHEN** a user records a task estimate without enabling or using time logging
- **THEN** the task retains that estimate independently of any time logs.

#### Scenario: Task has no estimate
- **WHEN** a task or descendant summary includes work with no recorded estimate
- **THEN** that missing value is not represented as a recorded zero or silently replaced by elapsed time.

### Requirement: Time logging is optional and independent of estimates
Kumiko SHALL support optional time logging against tasks independently of estimates. Time recorded against a task SHALL remain distinguishable from time recorded against descendants, and absence of time logs SHALL NOT prevent planning or completion.

#### Scenario: User logs time without estimating
- **WHEN** a user records time against a task that has no estimate
- **THEN** the time is associated with that task without requiring or inventing an estimate.

#### Scenario: Parent and child each have logged time
- **WHEN** a task and its descendant each have recorded time
- **THEN** their own logs remain identifiable, and a descendant roll-up does not duplicate the same logged time as additional work.

#### Scenario: User completes work without time logs
- **WHEN** a user instructs completion of a task with no time logs
- **THEN** missing time logs do not prevent the explicit task update.
