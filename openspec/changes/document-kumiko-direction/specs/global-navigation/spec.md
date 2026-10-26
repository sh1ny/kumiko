# Spec Delta

## Purpose

Provide direct navigation among work objects across accessible projects while keeping file lookup tied to the selected execution workspace.

## ADDED Requirements

### Requirement: Quick-open spans work objects
Kumiko SHALL provide a single quick-open/search surface combining the current user's owner-local personal records with authorized shared projects, tasks, project documents, and project conversations. Private conversation, agent-session, and execution-workspace lookup SHALL use owner-local records, not a central team index of personal work.

#### Scenario: Find different kinds of work
- **WHEN** a query matches authorized shared projects, tasks, documents, or conversations and the current user's owner-local sessions or workspaces
- **THEN** those object types can be found through the same quick-open/search surface without traversing each project's hierarchy or uploading personal records to enable discovery.

#### Scenario: Query has no matching accessible object
- **WHEN** a query has no matching accessible work objects
- **THEN** the surface reports no matching results rather than substituting unrelated or inaccessible objects.

### Requirement: Private lookup remains owner-local rather than team-indexed
Kumiko MUST keep private session, conversation, workspace, and file lookup owner-local on the user's PC. The team server MUST NOT receive, synchronize, index, or expose private histories or working-copy contents to enable quick-open. A signed-in user's personal results MUST be their own local records, never other members' personal sessions, including for administrators.

#### Scenario: Find an owner's private session
- **WHEN** the current user searches for their private coding session or local workspace on their PC
- **THEN** quick-open can find it from owner-local records without sending its private history, prompts, tool output, or working-copy content to the team server.

#### Scenario: Administrator searches another member's private history
- **WHEN** a team administrator searches for another member's private session, local workspace, file, or edit
- **THEN** team search provides no such personal record or content, regardless of administrator participation in shared projects.

#### Scenario: Current identity does not own a personal result
- **WHEN** a signed-in user's query matches a personal session belonging to another user rather than their own local records
- **THEN** quick-open does not return that other user's personal session as an authorized shared result.

### Requirement: Results preserve their target context
Kumiko SHALL identify a navigation result's project, repository or workspace, and host where relevant, and open the actual target represented by that result.

#### Scenario: Open a conversation in context
- **WHEN** a user selects their owner-local private conversation result associated with a project and execution workspace
- **THEN** Kumiko opens that actual conversation with its project, workspace, and host identifiable without treating the association as team publication.

#### Scenario: Different targets have the same name
- **WHEN** similarly named results belong to different projects, workspaces, or hosts
- **THEN** their relevant context distinguishes them and selection does not silently open the other target.

### Requirement: File search stays within the selected workspace
Kumiko SHALL scope file search to the selected execution workspace rather than silently searching all checkouts or machines.

#### Scenario: Find a file in the selected workspace
- **WHEN** a user searches files with an execution workspace selected
- **THEN** file results identify matching files in that workspace and their relevant host context.

#### Scenario: Matching filename exists only elsewhere
- **WHEN** the same search matches a file only in a different checkout or host
- **THEN** that file is not silently included as a result from the selected workspace.

### Requirement: Search respects access and shared-state availability
Kumiko MUST apply existing access permissions to search and navigation. Shared team content MUST remain server-required; quick-open MUST NOT bypass that boundary through an offline copy.

#### Scenario: Search authorized shared content while connected
- **WHEN** an authorized user searches a reachable team's shared work objects
- **THEN** matching objects within their access can be found and opened.

#### Scenario: Team server becomes unavailable
- **WHEN** the team server is unreachable during search
- **THEN** shared-content search reports unavailable rather than serving an offline shared copy, while independently available owner-local session and workspace lookup and selected-workspace file search remain usable.
