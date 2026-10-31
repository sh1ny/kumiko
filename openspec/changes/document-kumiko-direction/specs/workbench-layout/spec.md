# Spec Delta

## Purpose

Provide a project-optional desktop workbench whose personal working sets combine full working views, terminals, and contextual tools without constraining work to one layout.

## ADDED Requirements

### Requirement: The workbench separates navigation working views and contextual tools
Kumiko SHALL provide left navigation with global My tasks and Needs attention above member projects, workspaces, and project chat; a central working area; and right-side Files, Sessions, SCM, current-branch PRs, and Tasks tool selectors. Contextual tools MUST NOT replace full working views with cramped sidebar editors.

#### Scenario: Navigate and inspect contextual work
- **WHEN** a user opens a project workspace in the workbench
- **THEN** left navigation identifies the project and workspace, global My tasks and Needs attention remain above project navigation, and right-side selectors expose contextual tools for the active work.

#### Scenario: A tool selection needs a full editor
- **WHEN** a user opens a task, document, file, or other editable work object from a contextual tool
- **THEN** its full working view opens in the central area rather than requiring editing inside the sidebar.

### Requirement: Notifications remains reachable without sidebars
Kumiko SHALL provide a small, accessible, labeled Notifications button in the global top bar, reachable with either or both sidebars hidden. It SHALL open one newest-first panel of the user's attention notifications, including dismissed and handled records, without requiring a project or replacing the current session.

#### Scenario: Open Notifications with both sidebars collapsed
- **WHEN** a user hides both sidebars while working in Personal and activates the top-bar Notifications button by keyboard
- **THEN** the newest-first panel opens with its accessible label and the current session unchanged.

#### Scenario: No notification is currently active
- **WHEN** all retained notifications are dismissed or have handled sources
- **THEN** the button still opens their history rather than becoming unreachable or requiring an active Needs attention item.

### Requirement: Notifications and Needs attention use the same records
The panel SHALL distinguish source pending/handled, notification dismissed, and seen/unseen independently; identify source type, project or Personal context, session, and task when applicable within authorized in-app views; and open each row's exact source without authorizing action. Needs attention and its count SHALL be the active undismissed pending subset of these same records, not a separate inbox.

#### Scenario: Inspect a dismissed but pending approval
- **WHEN** a user dismisses an approval notification while its source still awaits a decision
- **THEN** the panel shows it as dismissed and pending with its seen state and source context, while Needs attention and its count exclude it without claiming all waiting requests are handled.

#### Scenario: Open a handled notification row
- **WHEN** a user selects a handled notification in the panel
- **THEN** its exact source opens under current access rules without sending an answer, approval, denial, or review decision.

#### Scenario: Retained context is no longer authorized
- **WHEN** a retained notification refers to a shared source the user can no longer access
- **THEN** the panel does not reveal restricted project, session, task, or source details and cannot bypass source authorization.

### Requirement: Agent status is readable and independent of notification dismissal
Agent tabs or headers and the Sessions list SHALL persistently show readable icon-and-text states where reported by the runtime: Running, Idle, Waiting for your answer, Waiting for approval, Failed, or Disconnected — status unknown. Dismissal MUST NOT change agent state. Review requested SHALL be a separate indicator, not an inferred Idle or waiting state. Unsupported terminal CLIs MUST NOT imply richer status detection.

#### Scenario: Dismiss an approval while the agent waits
- **WHEN** the runtime reports Waiting for approval and the user dismisses its notification
- **THEN** the agent tab or header and Sessions list retain the readable waiting state rather than switching to Idle or hiding the wait.

#### Scenario: Review is requested during running work
- **WHEN** a supported runtime reports Running while its session has an explicit review request
- **THEN** both agent surfaces show Running with a separate Review requested indicator rather than treating review as an inferred idle or waiting state.

#### Scenario: A runtime connection is lost
- **WHEN** an agent's runtime connection is lost and its current state cannot be determined
- **THEN** both surfaces show Disconnected — status unknown rather than retaining stale Running or claiming Idle.

#### Scenario: A terminal CLI has no structured status support
- **WHEN** a terminal-native CLI provides no supported structured agent state
- **THEN** Kumiko preserves basic terminal use, identifies agent status as unavailable, and does not infer waiting, failure, or review readiness from ordinary terminal activity.

### Requirement: Full working views use the central area
Kumiko SHALL support chat, real terminals, files, diffs, task details, planning, and project documents as full central tabs. Creation and editing SHALL use these full working views rather than being confined to navigation or contextual sidebars.

#### Scenario: Create and edit project work
- **WHEN** a user creates a task or opens a project document for editing
- **THEN** the creation or editing view occupies a full central tab.

#### Scenario: A sidebar cannot fit a working view
- **WHEN** a contextual selector identifies a diff or planning view needing substantial working space
- **THEN** Kumiko opens the view centrally without requiring the user to expand the sidebar into an editor.

### Requirement: Task details organize content and properties within the task tab
Kumiko SHALL identify the project, task, and applicable parent in a full task-detail tab. Description with Markdown source/preview, acceptance criteria, direct subtasks, linked work, discussion, and change history SHALL occupy the task view, with compact properties inside that view rather than replacing the application-wide contextual sidebar. The view SHALL provide task-link copying and watching.

#### Scenario: Inspect a task alongside an agent conversation
- **WHEN** a user opens a task beside an agent chat in a wide enough pane
- **THEN** its main content has most of the task-view space, status, assignee, type, priority, labels, dates, and applicable planning/custom properties appear in a compact internal column, and the task does not require launching an agent.

#### Scenario: Task is nested within other work
- **WHEN** a user opens a nested task with children of its own
- **THEN** the header identifies its navigable parent and the subtask section exposes only direct children with their own statuses and assignees, not an expanded descendant tree.

### Requirement: Task views adapt to pane width and enabled features
Kumiko SHALL stack task properties above content in a narrow pane rather than squeeze the description into an unusable column. Disabled optional feature sections and properties MUST be absent rather than empty mandatory steps. Task details and creation SHALL remain full central views using the same content/property organization.

#### Scenario: Narrow the task pane beside other work
- **WHEN** a user narrows a task-detail pane while keeping another working view alongside it
- **THEN** properties stack above the task content without moving task editing into the application-wide right sidebar.

#### Scenario: Create work in a Tasks-only project
- **WHEN** a user opens New task in a project whose optional planning features are disabled
- **THEN** the central creation view offers its title, description, and applicable properties without empty cycle, milestone, estimate, or other disabled sections.

### Requirement: Contextual tools preserve their project and workspace scopes
Kumiko SHALL identify the current scope of contextual tools. Files, SCM, and current-branch PRs SHALL follow the focused workspace and its applicable repository and host. Tasks SHALL remain project-scoped. Tool focus MUST NOT retarget existing sessions or present another workspace's state as the selected workspace's state.

#### Scenario: Focus changes to another workspace
- **WHEN** a user focuses a pane for a different workspace and opens Files, SCM, or branch PRs
- **THEN** the tool identifies and displays that workspace's applicable repository and host context without changing either pane's existing session identity.

#### Scenario: Multiple workspaces belong to one project
- **WHEN** the focused workspace changes within a project while the Tasks tool is selected
- **THEN** Tasks remains scoped to that project rather than silently becoming only the newly focused workspace's task list.

### Requirement: A Tasks-only project provides complete basic task use
Kumiko SHALL support a project with Tasks enabled and all other planning features disabled. Its basic task list and full task detail SHALL remain usable without enabling boards, timelines, calendars, milestones, roadmaps, cycles, dashboards, documents, notes, estimates, or time logging.

#### Scenario: Use a Tasks-only project
- **WHEN** a project enables only Tasks among its planning features
- **THEN** authorized users can find tasks in its basic list and create, open, and edit full task details without enabling another planning feature.

#### Scenario: No cycle or dashboard is wanted
- **WHEN** a user manages tasks without enabling cycles, roadmaps, or task dashboards
- **THEN** Kumiko does not require those features or fabricate their records to support basic task use.

### Requirement: Tasks has a full central view and compact contextual entry point
Kumiko SHALL provide a full central Tasks main view, with the right Tasks tool remaining a compact entry point. List SHALL be the basic default; Board, Timeline, and Calendar SHALL appear only when enabled. The main-view toolbar SHALL offer search, filters, grouping, sorting, visible fields, and saved-view controls without making optional views prerequisites for task use.

#### Scenario: Open the main Tasks view
- **WHEN** a user follows the compact right Tasks entry point in a Tasks-only project
- **THEN** a full central List opens with its toolbar, without Board, Timeline, or Calendar choices.

#### Scenario: An optional view is disabled
- **WHEN** a project disables Board while List and Timeline remain available
- **THEN** Board disappears from the view choices without removing basic List access or enabling another view.

### Requirement: Saved-view controls distinguish personal use from project publishing
Saved-view controls SHALL distinguish personal/project scope, save personally by default, and expose explicit permission-controlled publication. Temporary toolbar changes SHALL visibly mark the working view modified without replacing a saved definition until explicit update. Users SHALL be able to make independent personal copies. Opening or choosing a default view SHALL affect only personal navigation; deleting a view MUST NOT delete tasks.

#### Scenario: Keep a personal variation of a project view
- **WHEN** a user changes a project view's filters and saves an independent personal copy
- **THEN** the original project definition remains unchanged and the copy is identified as personal.

#### Scenario: Publish a saved view to the project
- **WHEN** a user with permission explicitly publishes a saved view to the project
- **THEN** the controls identify its project scope without treating ordinary opening or default selection as publishing.

#### Scenario: An unprivileged user changes a shared view's toolbar
- **WHEN** a user without project-publishing permission changes a project view's grouping or visible fields
- **THEN** the temporary display can change without rewriting the project definition or offering unauthorized publishing.

### Requirement: Task lists show matching records and open full details
List SHALL show matching tasks as flat rows, including matching subtasks without matching ancestors, with identity/title, status, assignee, applicable dates, and descendant warnings. A task click SHALL open full detail; Open beside SHALL keep List visible alongside detail, reusing an existing detail view when applicable. Empty states SHALL distinguish no project tasks from no filter matches.

#### Scenario: A subtask matches without its parent
- **WHEN** a search matches a nested task but not its parent
- **THEN** the matching task appears as a flat row and clicking it opens the same full task detail, without an expanded ancestor tree.

#### Scenario: Inspect work beside the list
- **WHEN** a user chooses Open beside for a task not already open
- **THEN** its full detail opens alongside the list rather than replacing the list or using a sidebar editor.

#### Scenario: Existing detail is not beside the list
- **WHEN** a user chooses Open beside for a task whose detail is already open elsewhere
- **THEN** the existing detail view is arranged beside the still-visible List rather than merely focusing it elsewhere or creating a duplicate.

#### Scenario: Filters hide existing tasks
- **WHEN** tasks exist but none match the current search and filters
- **THEN** List explains that there are no matches and offers adjustment of the query, rather than claiming the project has no tasks.

#### Scenario: The project has no tasks
- **WHEN** an authorized user opens List for a project with no tasks
- **THEN** the empty state identifies the absence of tasks and offers task creation rather than reporting a filter mismatch.

### Requirement: Inline task properties save committed edits visibly
Kumiko SHALL save inline task-property changes on explicit edit commit, while description and other prose editing remain in task detail. Hovering or canceling an edit MUST NOT save it. A failed property save SHALL visibly remain unsaved with the intended value retained; the UI MUST NOT present that intended value as successfully persisted.

#### Scenario: Commit an inline assignee change
- **WHEN** a user selects an assignee and commits the inline edit
- **THEN** Kumiko saves that property while prose editing remains available in full task detail.

#### Scenario: A property save fails
- **WHEN** a committed inline priority change cannot be saved
- **THEN** the intended priority remains visibly unsaved with the failure identified, rather than disappearing or being shown as persisted.

#### Scenario: Cancel an inline edit
- **WHEN** a user changes an inline property selection but cancels before committing
- **THEN** the stored property remains unchanged.

### Requirement: Board shows compact flat cards in project status columns
Board SHALL use the project's configured status columns and order. Compact cards SHALL show ID, title, assignee, priority, due date when present, and unfinished-descendant warnings, without descriptions by default. Matching subtasks SHALL be flat cards. Column counts SHALL count matching task records, not hidden hierarchy. Narrow panes SHALL permit horizontal scrolling rather than lose columns.

#### Scenario: Review matching parent and child work
- **WHEN** both a parent and its subtask match the Board filters
- **THEN** each appears as its own card in its status column, counts include both records, and unfinished-descendant warnings remain visible where applicable.

#### Scenario: Board is narrower than its columns
- **WHEN** a pane cannot show every configured status column at once
- **THEN** horizontal scrolling reaches the remaining columns in project order without hiding them or expanding cards into descriptions.

### Requirement: Board status changes require a committed action
Board SHALL save a dragged task's status only on drop into a status column and offer a keyboard-accessible status picker as an alternative. Hovering or canceling a drag MUST NOT change status. Failed status saves SHALL visibly retain the intended change as unsaved. Column New task SHALL preselect that column's status but create no record until explicit Create.

#### Scenario: Drop a card into another status
- **WHEN** a user drops a card into another status column or commits that status through the keyboard-accessible picker
- **THEN** Kumiko saves the selected status rather than requiring drag and drop.

#### Scenario: Hover and cancel a drag
- **WHEN** a user drags a card over another column and cancels without dropping
- **THEN** the task's status remains unchanged.

#### Scenario: A dropped change fails to save
- **WHEN** a status save after dropping a card fails
- **THEN** Board identifies the failure and retains the intended status as visibly unsaved rather than reporting a successful move.

#### Scenario: Start task creation from a column
- **WHEN** a user chooses New task in a status column and then cancels creation
- **THEN** the creation view had that status preselected but no task record is created without explicit Create.

### Requirement: Timeline distinguishes dated and unscheduled tasks
Timeline SHALL show a date bar for tasks with start and due dates, a due-date marker for due-only tasks, and an Unscheduled area for undated tasks. Entries SHALL retain task identity and open the same full task detail as List. The view MUST NOT imply a date range for a task whose only date is its due date.

#### Scenario: Review mixed scheduling information
- **WHEN** matching tasks include start-and-due, due-only, and undated records
- **THEN** Timeline shows date bars, due markers, and Unscheduled entries respectively, with each entry opening its task detail.

#### Scenario: A task has only a due date
- **WHEN** a user inspects a due-only task in Timeline
- **THEN** it has a due marker rather than a fabricated start date or duration.

### Requirement: Timeline date edits require commitment without automatic scheduling
Timeline SHALL save dates only after a committed move, resize, or date-picker edit, with a date-picker alternative to pointer manipulation. Canceled gestures MUST leave dates unchanged; failed saves SHALL retain intended dates as visibly unsaved. Edits MUST NOT automatically schedule dependencies, subtasks, or parents.

#### Scenario: Commit a timeline date change
- **WHEN** a user commits a bar move, resize, or date-picker change
- **THEN** the task's chosen dates are saved without automatically changing dependency, subtask, or parent schedules.

#### Scenario: Cancel a timeline gesture
- **WHEN** a user previews a bar move or resize but cancels before committing
- **THEN** no task dates change.

#### Scenario: Timeline dates cannot be saved
- **WHEN** a committed date change fails to save
- **THEN** the intended dates remain visibly unsaved with the failure identified, not presented as persisted.

### Requirement: Calendar presents enabled dated work as work rather than meetings
Calendar SHALL initially show a month with Previous, Next, Today, and filter controls. Task and milestone entries SHALL show identity, title, and status rather than meeting times; enabled cycles SHALL appear as date bands. Disabled sources SHALL disappear. Calendar MUST NOT require external accounts or create event copies of its source records.

#### Scenario: Browse a project's dated work
- **WHEN** a user opens Calendar with dated tasks, milestones, and cycles enabled
- **THEN** the initial month exposes Previous, Next, Today, and filters, task and milestone identities, titles and statuses, and cycle date bands without meeting times or an external account.

#### Scenario: A calendar source is disabled
- **WHEN** a project disables its task source while an enabled milestone source keeps Calendar available
- **THEN** task entries disappear and milestone entries remain, without retained task-event copies.

### Requirement: Calendar overflow and creation preserve source identity
Calendar SHALL show a crowded day's remaining-entry count and let the user open those remaining entries. Opening an entry SHALL open the same source detail used elsewhere. A day's New task action SHALL preselect that due date and require explicit Create before creating a task; the action SHALL be absent when Tasks is disabled.

#### Scenario: Open work on a crowded day
- **WHEN** a day has more entries than can be displayed and a user opens its remaining-entry count
- **THEN** the remaining entries become accessible and selecting a task or milestone opens its existing source detail.

#### Scenario: Cancel date-prefilled task creation
- **WHEN** a user selects a day's New task and then cancels
- **THEN** that due date was preselected but no task or copied calendar event is created without explicit Create.

### Requirement: Milestone detail puts outcomes before task progress
Milestone full detail SHALL lead with outcome and acceptance criteria, show linked tasks with status, assignee, dates, blockers, and unfinished-descendant warnings, and make those tasks clickable. It SHALL expose linked documents when enabled, discussion, and closure assessment. Task progress SHALL be displayed separately from milestone status rather than substituting a percentage for outcome assessment.

#### Scenario: Inspect a milestone's deliverable
- **WHEN** a user opens milestone detail with linked tasks and documents enabled
- **THEN** outcome and criteria appear first, linked task properties and warnings are visible, tasks open their full details, and documents, discussion, and closure assessment are accessible.

#### Scenario: Task completion does not settle the outcome
- **WHEN** all included tasks are completed but milestone acceptance remains unmet
- **THEN** detail shows task progress separately and does not present that percentage as a successful closure assessment.

### Requirement: Milestone closure remains assessable after work moves
Milestone detail SHALL show closure assessment independently of task percentage and allow closure with deferred, unfinished, or canceled work without automatically changing tasks. Historical closure assessment and prior milestone association SHALL remain accessible after deferred work moves. Closing MUST NOT freeze the displayed percentage or force it to 100%.

#### Scenario: Review deferred work after a move
- **WHEN** deferred work is moved from a closed milestone to a later milestone
- **THEN** the closed milestone's historical assessment and the task's prior association remain accessible rather than being erased by its current placement.

#### Scenario: Close with unfinished work
- **WHEN** a user closes a milestone while linked work remains unfinished, deferred, or canceled
- **THEN** its assessment records the closure without automatically completing, canceling, moving, or otherwise changing those tasks.

### Requirement: Roadmap presents milestones and explicitly placed Later work
Roadmap SHALL show milestone-by-milestone status, task-completion percentage with numerator and denominator, and date-only target when present. Milestones and shown tasks SHALL open their details. A Later list SHALL show explicitly placed work with explicit move and remove actions; it MUST NOT dump all tasks lacking roadmap placement or make placement necessary for task existence or workflow.

#### Scenario: Drill down from the roadmap
- **WHEN** a user reviews milestone progress and selects a milestone or shown task
- **THEN** its full detail opens, with roadmap progress expressed by status, percentage, numerator and denominator, and any date-only target.

#### Scenario: Remove work from Later
- **WHEN** a user explicitly removes a task from Later while other tasks have never been placed on the roadmap
- **THEN** the task loses that roadmap placement without deletion or workflow change, and never-placed tasks are not automatically added to Later.

### Requirement: Milestone progress controls expose excluded work consistently
Roadmap and milestone detail SHALL offer deferred/canceled-work inclusion controls, show included completed/total counts and deferred, canceled, and excluded-work counts, and synchronize that percentage setting. Only these inclusion controls SHALL change the agreed completion denominator, not arbitrary text filters. Toggles SHALL apply to closed milestones without changing task data, milestone status, or outcome.

#### Scenario: Toggle deferred work on a Done milestone
- **WHEN** a Done milestone has ten tasks, eight completed and two deferred, and the user includes then excludes deferred work
- **THEN** overview and detail show 80% (8/10) with deferred rows included, then 100% (8/8) with those rows hidden and the two exclusions indicated, while the milestone remains Done.

#### Scenario: Include canceled work in progress
- **WHEN** a user changes canceled-work inclusion in milestone detail
- **THEN** roadmap uses the same setting, reflects included actual completed tasks in its counts and percentage, identifies excluded work, and does not change task statuses or milestone outcome.

#### Scenario: A search hides unfinished tasks
- **WHEN** a text filter hides unfinished linked tasks without changing deferred/canceled inclusion
- **THEN** displayed matching records may change but the milestone's agreed completion denominator does not shrink to imply completion.

### Requirement: Projects can select optional planning features independently
Kumiko SHALL let authorized users configure optional task views, subtasks and checklists, milestones and roadmaps, cycles, calendars, task dashboards and statistics, documents and notes, estimates, and time logging, subject to prerequisites. Estimates and time logging SHALL be independently optional. Documents and notes MUST NOT require Tasks.

#### Scenario: Use project notes without tasks
- **WHEN** a project enables documents or notes while Tasks is disabled
- **THEN** authorized users can use that enabled content feature without enabling task planning.

#### Scenario: Estimate without logging time
- **WHEN** a project enables estimates but leaves time logging disabled, or enables time logging without estimates
- **THEN** the enabled feature remains usable without requiring the other.

### Requirement: Planning features enforce their work prerequisites
Task boards, tables, timelines and other optional task views, subtasks and checklists, cycles, estimates, time logging, and task dashboards and statistics SHALL require Tasks. Calendar SHALL require an enabled dated work source, such as tasks, milestones, or cycles. A feature MUST NOT be active without its prerequisites or silently enable them.

#### Scenario: Enable a calendar over milestones
- **WHEN** a project has enabled dated milestones but no Tasks
- **THEN** its internal calendar can show those milestones without requiring Tasks or an external calendar account.

#### Scenario: Tasks is unavailable to a dependent feature
- **WHEN** an authorized user attempts to enable task dashboards, cycles, or another Tasks-dependent feature while Tasks is disabled
- **THEN** Kumiko explains the Tasks prerequisite and does not activate the feature or silently enable Tasks.

#### Scenario: Calendar has no enabled dated source
- **WHEN** a project has no enabled dated work source and a user attempts to enable Calendar
- **THEN** Kumiko explains the missing prerequisite rather than activating an empty feature backed by a disabled source.

### Requirement: Disabled features are inactive without losing their data
Disabling a project feature SHALL hide its entry points and make existing feature views inactive. Kumiko MUST reject disabled-feature reads and changes through application APIs and agent tools, not just hide controls. Disabling MUST NOT delete retained feature data; re-enabling SHALL restore its availability subject to current permissions and required server connectivity.

#### Scenario: Re-enable retained planning work
- **WHEN** an authorized user re-enables a previously disabled feature with retained records and its prerequisites available
- **THEN** those records become available again subject to current access and required server connectivity, without recreation or an implied access grant.

#### Scenario: An agent bypasses hidden navigation
- **WHEN** an API caller or agent tool attempts to query or change records belonging to a disabled project feature
- **THEN** Kumiko rejects the disabled-feature operation even if the caller previously accessed it, and retained records remain unchanged.

#### Scenario: A saved layout references a disabled feature
- **WHEN** a user returns to an open or restored view whose project feature is now disabled
- **THEN** the view is inactive with the disabled state explained rather than making the feature usable through saved navigation.

### Requirement: Disabling prerequisites requires explicit dependent confirmation
Before disabling a prerequisite, Kumiko SHALL identify affected enabled dependent features and explain that they must also become inactive. It MUST require explicit confirmation covering those dependent features before disabling them together. Cancellation SHALL leave their enabled states and data unchanged; no feature change SHALL silently cascade or delete data.

#### Scenario: Disable Tasks with task dashboards active
- **WHEN** an authorized user requests disabling Tasks while task dashboards and cycles are enabled
- **THEN** Kumiko identifies those dependents and disables them with Tasks only after explicit confirmation covering all affected features, preserving their data.

#### Scenario: Cancel a prerequisite change
- **WHEN** a user declines confirmation to disable dependent features
- **THEN** the prerequisite and its dependents retain their prior enabled states and records rather than being partially or implicitly disabled.

#### Scenario: Calendar retains another valid source
- **WHEN** Tasks is disabled but Calendar still has an enabled dated milestone source
- **THEN** Calendar need not be disabled and cannot use the disabled task source.

### Requirement: Feature switches do not replace access or personal work
Enabling a feature MUST NOT grant access to its project, records, sessions, or operations. Disabling project Tasks or optional planning features MUST NOT disable Personal or private chats, agent sessions, terminals, private usage, or Needs attention. Existing project access, server-required shared work, and owner-local privacy rules SHALL continue to apply.

#### Scenario: Private work continues without project Tasks
- **WHEN** Tasks is disabled for a project associated with a user's private chat, terminal, or agent session
- **THEN** that private work, private usage, and owner-local Needs attention remain available without requiring Tasks or changing the session's context or privacy.

#### Scenario: Feature enabling does not grant membership
- **WHEN** an authorized configurator enables a planning feature containing restricted records
- **THEN** only users already entitled to access those records can use them, and the switch grants no membership, record access, or operational authority.

### Requirement: Tabs contain panes and rearranging preserves sessions
Kumiko SHALL show central tabs between the sidebars. Each tab SHALL hold a horizontal and vertical split arrangement of panes, each hosting one view of any supported type; a one-pane tab gives its view the whole central area. Panes SHALL move into their own tabs and tabs into splits. Moving a view or changing the split arrangement MUST preserve its associated session, workspace, and host rather than starting a replacement or retargeting it. Source: user decision 2026-10-30.

#### Scenario: Move a pane into its own tab
- **WHEN** a user moves an existing chat or terminal pane out of a split into its own tab
- **THEN** that same view fills the new tab with its existing session, workspace, and host unchanged.

#### Scenario: Mix view types in one tab
- **WHEN** a user places a chat view in a pane beside a terminal in one tab
- **THEN** both views share the tab, each keeps its own session, workspace, and host, and either can later fill a tab of its own.

#### Scenario: Rearrange a running terminal
- **WHEN** a terminal has a running process while its pane, tab, or split is rearranged
- **THEN** the process remains attached to the same terminal session without being stopped or relaunched.

#### Scenario: Close one pane of a split
- **WHEN** a user closes one pane of a split
- **THEN** its sibling takes the freed space, and no empty pane remains.

### Requirement: The tab strip provides a labeled click launcher
The central tab strip SHALL provide a visible + control, also with no tab open, opening a readable, labeled click menu of supported view types. With no tab open, the central area SHALL show a short empty state with a prominent New terminal action. A new view SHALL open in a new tab, inheriting the project, workspace, and host context selected in navigation. Hover MUST NOT be required to discover or activate the menu. Source: user decisions 2026-10-30, replacing the per-group launcher.

#### Scenario: Open a new view in a new tab
- **WHEN** a user with a workspace selected clicks the tab strip's + control and selects a supported new terminal or chat view
- **THEN** the labeled menu opens by click and the new view opens in a new tab with the applicable project, workspace, and host inherited.

#### Scenario: No tab is open
- **WHEN** the user has closed every tab
- **THEN** the central area shows a short empty state with a prominent New terminal action and its shortcut, the tab strip's + control still offers the labeled choices, and no empty pane is shown.

#### Scenario: Launcher is used without hovering
- **WHEN** a user clicks the tab strip's + control without first hovering over it
- **THEN** the same labeled choices are available without requiring a hover-only submenu or discovery step.

### Requirement: Opening an existing item focuses it by default
Kumiko SHALL focus an already-open item rather than create another view of the same item by default, including when it is in a pane of another tab. This focus operation MUST NOT launch duplicate sessions or processes.

#### Scenario: Reopen an existing task
- **WHEN** a user selects a task already open in a pane of another central tab
- **THEN** Kumiko focuses that task's existing view by default.

#### Scenario: Select a running session again
- **WHEN** a user selects a chat or terminal session already represented by an open pane
- **THEN** Kumiko focuses the existing session view without launching another agent or terminal process.

### Requirement: Direct project navigation restores its personal working set
A direct project click SHALL activate that project's owner-local working set, restoring its open tabs, splits, selected contextual tool, and last active workspace and pane. Switching projects MUST NOT stop processes, silently retarget existing terminals or chats, or launch duplicate work.

#### Scenario: Return to a project's work
- **WHEN** a user clicks a project previously used with multiple tabs and splits
- **THEN** Kumiko restores that project's tabs, split arrangement, selected tool, and last active workspace.

#### Scenario: Switch away from running work
- **WHEN** a user clicks another project while the current project has running terminals or chats
- **THEN** the original sessions keep their existing contexts and processes, and activating the other project does not duplicate them.

### Requirement: Direct workspace navigation activates its parent context
A direct workspace click SHALL activate its parent project and focus that workspace's existing work. It MUST NOT silently retarget another workspace's open terminal or chat, stop processes, or create duplicate sessions as a consequence of navigation.

#### Scenario: Select a workspace under another project
- **WHEN** a user clicks a workspace belonging to a different project from the active one
- **THEN** Kumiko activates that parent project and focuses the selected workspace's existing work.

#### Scenario: Another workspace has a running terminal
- **WHEN** a user selects a different workspace while an existing terminal is running in the current workspace
- **THEN** the terminal retains its original workspace and process rather than being retargeted, stopped, or duplicated.

### Requirement: Personal work does not require a project
Kumiko SHALL provide a local Personal working set alongside project working sets for projectless chat, terminals, and local development. Starting such work MUST NOT require a project, repository, team account, or fabricated scratch project.

#### Scenario: Start projectless daily work
- **WHEN** a user without a team account or project opens Kumiko to start a local terminal or supported private chat
- **THEN** the user can work in Personal without first creating a project or repository.

#### Scenario: Personal work has no repository
- **WHEN** a Personal working set has no repository or project association
- **THEN** its applicable local views remain usable without inventing a scratch project or requiring team sign-in.

### Requirement: Personal working layouts stay on the user's PC
Kumiko MUST keep personal tabs, split arrangements, selected tools, and project or Personal working-set restoration state on the user's PC. These records MUST NOT be uploaded, synchronized, indexed, or exposed through the team server, including to administrators.

#### Scenario: Restore an owner's local layout
- **WHEN** the owner returns to a project or Personal working set on their PC
- **THEN** Kumiko can restore the owner-local layout without publishing that layout to the team server.

#### Scenario: Administrator requests another user's layout
- **WHEN** a team administrator requests another user's open tabs, splits, or personal working-set state through the team service
- **THEN** that personal state is not available from the team server.

### Requirement: App reopening restores the open layout and saved session identities
Kumiko SHALL preserve all open windows, tabs, panes, splits, and agent-session associations across app exit and reopening. Idle, saved work SHALL exit without unnecessary prompts. Reopening SHALL restore saved histories through supported original-session resume, not the same OS processes or task re-execution. Manually closed tabs MUST NOT return as open layout; unavailable history or resume MUST NOT be reported as successful.

#### Scenario: Return to the saved workbench tomorrow
- **WHEN** a user exits with saved files and idle agents, then reopens Kumiko
- **THEN** the same open windows, tabs, panes, splits, and original agent-session associations return without unnecessary exit prompts, live-process restoration, new conversations, or replay of the agents' original tasks.

#### Scenario: A manually closed tab is absent on reopening
- **WHEN** a user manually closes a tab before exiting and later reopens Kumiko
- **THEN** that tab is not automatically resurrected into the open layout, without treating its closure as deletion of saved agent history.

#### Scenario: An original agent session cannot resume
- **WHEN** a restored chat's saved history or original runtime/session resume is unavailable
- **THEN** Kumiko reports the limitation rather than claiming successful restoration or substituting a new conversation or rerunning its original task.

### Requirement: App exit resolves affected work per item
Kumiko SHALL offer per-item decisions for this user's affected active agents, terminal processes, and unsaved files before app exit. Cancel SHALL keep unresolved work intact, not undo completed saves or confirmed stops. Ordinary exit MUST wait for unresolved items, including failed Saves unless explicitly discarded, and MUST NOT stop the team server or other users' sessions.

#### Scenario: Resolve active work individually
- **WHEN** a user exits with a working agent, running terminal applications, and an unsaved file
- **THEN** Kumiko identifies each affected item, lets the user confirm stopping affected processes or cancel exit to keep them running, and offers Save, Don't Save, or Cancel for each unsaved file; exit completes only after all affected items are resolved.

#### Scenario: Cancel after resolving another item
- **WHEN** a user saves one file or confirms stopping one process, then cancels exit while other work remains unresolved
- **THEN** unresolved editors and running work remain intact and the app remains open, without claiming that the completed save or confirmed stop was rolled back.

#### Scenario: A Save fails during ordinary exit
- **WHEN** a requested file Save fails while resolving app exit
- **THEN** the app keeps the unsaved editor and content open, reports the failure, and does not complete ordinary exit unless the user later saves successfully or explicitly discards those edits.

#### Scenario: Other users have active work
- **WHEN** this user exits while a shared team server or another user's sessions are active
- **THEN** exit decisions affect only this user's affected sessions and do not terminate that server or the other user's work.

### Requirement: Bulk exit states process and file-discard consequences
Kumiko SHALL offer an explicit bulk "Stop processes, discard unsaved file edits, and close" action identifying the affected processes and file edits before confirmation. Confirmation SHALL stop those processes and discard those edits without deleting saved history or local unsent chat drafts. Cancellation MUST NOT apply unresolved bulk actions or imply rollback of prior explicit decisions.

#### Scenario: Confirm bulk exit
- **WHEN** a user confirms the bulk action after seeing that affected processes will stop and unsaved workspace file edits will be discarded
- **THEN** Kumiko stops those processes, discards those file edits, and closes while preserving saved histories, local unsent chat drafts, and the open layout for reopening without restoring discarded edits or live processes.

#### Scenario: Cancel bulk exit
- **WHEN** a user cancels the bulk action before its confirmation
- **THEN** the app remains open and the unresolved processes and file edits remain intact, while any earlier explicitly completed saves or stops remain completed.

### Requirement: Sidebars collapse independently without changing work
Kumiko SHALL allow the left and right sidebars to collapse completely and independently, expanding the central area without changing its splits or session state. Both sidebars SHALL remain optional to hide; terminal-first use MUST NOT require hidden sidebars or a separate application mode.

#### Scenario: Expand a terminal while keeping navigation
- **WHEN** a user collapses only the right sidebar while working in a terminal
- **THEN** the center gains that space, left navigation remains visible, and the existing split arrangement and terminal session remain intact.

#### Scenario: Restore both sidebars during running work
- **WHEN** a user hides both sidebars and later reopens them while chats or terminals are running
- **THEN** the same central splits and sessions remain active without a mode transition, restart, or retargeting.

### Requirement: First release excludes browser and mobile emulator views
Kumiko's first functional release SHALL exclude embedded browser and mobile emulator views from the workbench and launcher, including disabled or coming-soon launch choices. Neither surface SHALL be required for supported working views or terminal-native development tools.

#### Scenario: Use the release launcher for supported work
- **WHEN** a user opens the first release's tab-strip launcher
- **THEN** its supported view choices provide workbench access without requiring a browser or mobile emulator surface.

#### Scenario: Look for an excluded view type
- **WHEN** a user inspects the first release's available workbench view types
- **THEN** embedded browser and mobile emulator views are not offered as available features.
