# Spec Delta

## Purpose

Protect Kumiko-owned project records through scoped backup, restore, retention, archival, and deletion without taking ownership of external development resources, and bound diagnostic-log accumulation independently of retained records and saved conversations.

## ADDED Requirements

### Requirement: Database backup and restore follow deployment ownership
Kumiko SHALL let a solo local owner back up and restore only their own local data, never team-server data through local restore. Team-server database backup and restore SHALL belong to the deployment operator through server administration, not ordinary project controls. A Kumiko administrator account alone MUST NOT confer operator authority; the same person MAY hold both responsibilities separately.

#### Scenario: Solo owner backs up and restores local data
- **WHEN** a solo local owner backs up or restores their own local Kumiko data
- **THEN** Kumiko permits the operation within that owner's local data scope.

#### Scenario: Local restore targets team-server data
- **WHEN** a solo owner attempts to use local restore to change team-server records
- **THEN** Kumiko denies that shared mutation and leaves team-server data unchanged.

#### Scenario: Deployment operator backs up or restores the server database
- **WHEN** a deployment operator performs a team-server database backup or restore through server administration
- **THEN** the operation is authorized through deployment-operator responsibility rather than project membership or lead designation.

#### Scenario: Application administrator lacks operator authority
- **WHEN** a Kumiko team administrator without deployment-operator authority attempts a team-server database backup or restore
- **THEN** administrator status does not authorize the operation and the database action is denied.

#### Scenario: Project participant seeks database administration
- **WHEN** an ordinary team member or project lead accesses ordinary project controls
- **THEN** those controls do not offer team-server database backup or restore through project responsibility.

#### Scenario: One person holds both responsibilities
- **WHEN** a Kumiko administrator who separately holds deployment-operator authority performs a team-server database backup or restore through server administration
- **THEN** the operation uses their operator authority without treating the administrator account role as sufficient.

### Requirement: Backup and restore exclude external resources and sensitive data
Kumiko SHALL support backup and restore of Kumiko-owned data while excluding all repositories, checkouts, worktrees, agent setups, agent conversation histories, and credentials. These exclusions SHALL apply regardless of whether excluded data is stored beside Kumiko-owned records.

#### Scenario: Back up and restore owned project records
- **WHEN** Kumiko-owned project records are backed up and restored
- **THEN** the restored data contains the backed-up owned records without repository contents, agent setups, conversation histories, or credentials.

#### Scenario: Excluded data is colocated with owned records
- **WHEN** an agent conversation cache or credential is stored beside Kumiko-owned records selected for backup
- **THEN** that cache or credential is excluded from the backup and cannot be restored from it.

### Requirement: Backup uses a ZIP database dump with eligible owned attachments
Kumiko SHALL produce a ZIP archive containing a database dump of eligible Kumiko-owned records and any eligible owned attachments stored outside the database. Attachments already contained in the dump SHALL need no separate payload. Existing backup exclusions MUST apply to both the dump and attachment payload.

#### Scenario: Owned attachments are stored outside the database
- **WHEN** eligible Kumiko-owned records and externally stored owned attachments are backed up
- **THEN** the ZIP contains their database dump and the owned attachment payload.

#### Scenario: Owned attachments are stored in the database
- **WHEN** all eligible owned attachments are contained in the database dump
- **THEN** the ZIP requires no separate attachment payload for those attachments.

#### Scenario: Excluded data is stored alongside owned attachments
- **WHEN** repositories, checkouts, worktrees, native agent setups, private agent conversations, or credentials are colocated with eligible owned attachments
- **THEN** neither the database dump nor the attachment payload includes that excluded data.

### Requirement: Backup has no custom archive or built-in password protection
Kumiko SHALL use ZIP rather than a custom archive format and MUST NOT provide built-in backup password or encryption features.

#### Scenario: Create an ordinary backup
- **WHEN** a user creates a Kumiko backup
- **THEN** Kumiko produces a ZIP archive without applying built-in password protection or encryption.

#### Scenario: A user seeks built-in backup protection
- **WHEN** a user accesses Kumiko's backup controls
- **THEN** those controls do not offer a backup password, built-in encryption, or a custom archive-format option.

### Requirement: Restore rejects corrupt or unsupported backups before changing data
Kumiko SHALL perform basic backup integrity and version checks before restore modifies current data. Corrupt backups and unsupported backup versions MUST be rejected without changing current data.

#### Scenario: Backup passes basic restore checks
- **WHEN** a backup has valid basic integrity and a supported backup version
- **THEN** these checks permit restore to proceed without treating the archive as corrupt or version-incompatible.

#### Scenario: Backup is corrupt
- **WHEN** a user attempts to restore a backup that fails the basic integrity check
- **THEN** Kumiko rejects the restore before changing current data and reports that the backup is corrupt.

#### Scenario: Backup version is unsupported
- **WHEN** a user attempts to restore a backup with an unsupported version
- **THEN** Kumiko rejects the restore before changing current data and reports the unsupported backup version.

### Requirement: Restore replaces eligible destination records rather than merging
Kumiko SHALL restore a selected local or team datastore by replacing its eligible records with the chosen backup's data, not by automatically merging backed-up and current records. Successful restore SHALL retain the backup's record versions rather than newer destination changes, including tasks, memberships, and document revisions, within the existing eligible-data scope.

#### Scenario: Solo owner restores an older local backup
- **WHEN** an authorized solo owner completes a confirmed restore of a valid supported backup to their selected local datastore
- **THEN** its eligible records reflect the backup's data and versions, without retaining newer local tasks, edits, or document revisions as a merge.

#### Scenario: Deployment operator restores an older server backup
- **WHEN** a deployment operator completes a confirmed restore of a valid supported backup to the selected team-server datastore through server administration
- **THEN** its eligible records reflect the backup's data and versions, without retaining newer server tasks, memberships, or document revisions as a merge.

### Requirement: Restore requires confirmation of the identified backup and destination
Before modifying a restore destination, Kumiko SHALL identify the chosen backup and destination, warn that current changes since that backup will be lost, and require explicit confirmation for that pair. Cancellation, absent confirmation, or missing or mismatched destination identity MUST leave destination data unchanged; Kumiko MUST NOT silently select a destination. Confirmation MUST NOT confer restore authority or bypass backup integrity and version checks.

#### Scenario: Confirm the identified backup and destination
- **WHEN** an authorized actor prepares to restore a valid supported backup to a selected datastore
- **THEN** Kumiko identifies that backup and destination and warns that current changes since the backup will be lost, requiring explicit confirmation for that pair before modifying the destination.

#### Scenario: Cancel restore confirmation
- **WHEN** an actor cancels the restore confirmation after reviewing the identified backup and destination
- **THEN** the destination remains unchanged.

#### Scenario: Restore lacks explicit confirmation
- **WHEN** a restore has an identified backup and destination but no explicit confirmation for that pair
- **THEN** Kumiko does not modify the destination.

#### Scenario: Restore destination identity is missing
- **WHEN** a restore request lacks an identified destination, even if an actor submits a confirmation
- **THEN** Kumiko leaves data unchanged and does not silently choose a local or team datastore.

#### Scenario: Restore destination differs from the confirmed destination
- **WHEN** a restore request targets a datastore different from the destination identified in the confirmation
- **THEN** Kumiko does not modify either datastore or silently retarget the confirmation.

#### Scenario: Confirmation lacks restore authority
- **WHEN** an actor explicitly confirms the backup and destination without the required local-owner or deployment-operator authority for that destination
- **THEN** Kumiko denies the restore and leaves destination data unchanged.

#### Scenario: Confirmed backup fails restore checks
- **WHEN** an actor confirms a backup and destination but the backup fails basic integrity or supported-version checks
- **THEN** Kumiko rejects the restore before changing destination data rather than treating confirmation as a waiver.

### Requirement: Restoring records does not recreate the working environment
Kumiko SHALL distinguish restored records from the availability of referenced external resources and MUST NOT promise a one-to-one restoration of the prior environment. Restoring records MUST NOT automatically recreate repositories, checkouts, worktrees, agent setups, credentials, conversation histories, or running processes.

#### Scenario: Restore owned records without an environment guarantee
- **WHEN** a user restores Kumiko-owned project records
- **THEN** Kumiko restores those records without representing the prior working environment or running processes as recreated by the restore.

#### Scenario: Referenced checkout or conversation history is absent
- **WHEN** restored records refer to a checkout or agent conversation history that is absent from the current environment
- **THEN** Kumiko does not report the referenced resource as restored or available and does not recreate it, agent setup, credentials, or processes automatically.

### Requirement: Project records have no automatic expiry initially
Kumiko SHALL retain Kumiko-owned project records until explicit deletion, without automatic expiry in the initial scope. Archival SHALL preserve those records rather than start an expiry period. This project-record policy MUST NOT be presented as a retention policy for diagnostic logs, caches, or backup generations.

#### Scenario: Retain an active project's records
- **WHEN** a project's records remain without an explicit deletion request
- **THEN** those records remain retained rather than expiring with age.

#### Scenario: Archived records remain inactive for an extended period
- **WHEN** an archived project remains unused and no explicit deletion occurs
- **THEN** its records remain retained without automatic expiry because of age, inactivity, or archival.

### Requirement: Diagnostic logs rotate automatically within bounds
Kumiko SHALL automatically rotate diagnostic logs under a bounded retention policy that prevents unlimited accumulation on desktops and servers. Diagnostic-log rotation SHALL be independent of project-record retention and saved-conversation history; it MUST NOT expire project records or saved conversations as diagnostic logs.

#### Scenario: Diagnostics accumulate during ordinary operation
- **WHEN** desktop or server diagnostic logs accumulate through continued operation
- **THEN** automatic rotation keeps retained diagnostics bounded without requiring manual cleanup.

#### Scenario: Project records remain retained while logs rotate
- **WHEN** diagnostic logs reach their retention bounds for an active or archived project
- **THEN** rotation bounds those logs without deleting project records or changing their no-automatic-expiry policy.

#### Scenario: Saved conversations coexist with diagnostic logs
- **WHEN** a user retains saved conversation history while diagnostic logs rotate
- **THEN** rotation does not treat the saved conversations as logs or expire them under the diagnostic retention policy.

### Requirement: Project removal defaults to archive
Kumiko SHALL make archive the default project-removal action, hiding the project from active views while preserving its records. A solo local owner SHALL be able to archive their own project. Team archival SHALL require the project's current lead or an administrator within its team, current project access, and an available team server.

#### Scenario: Remove a project through the default action
- **WHEN** an authorized user removes a project using the default project-removal action
- **THEN** the project is archived, disappears from active project views, and retains its Kumiko-owned records.

#### Scenario: Solo owner archives their project
- **WHEN** a solo local owner archives their own project
- **THEN** Kumiko archives it without requiring a team account or invitation.

#### Scenario: Current team lead archives the project
- **WHEN** the project's current lead with current project access archives it while the team server is available
- **THEN** Kumiko permits archival without requiring the lead to be an administrator.

#### Scenario: Team administrator archives an unjoined project
- **WHEN** an administrator archives a project within their team while the team server is available without personal membership or lead responsibility
- **THEN** Kumiko permits archival through current team administrator authority.

#### Scenario: Archived project still has records
- **WHEN** a project has been archived rather than permanently deleted
- **THEN** its project records remain preserved even though it no longer appears in active project views.

#### Scenario: Ordinary member attempts archival
- **WHEN** a team member who is neither the project's current lead nor an administrator within its team requests archival
- **THEN** Kumiko denies archival and preserves the project's existing state and records.

#### Scenario: Administrator from another team attempts archival
- **WHEN** an administrator of another team requests archival without current lead or administrator authority in the project's team
- **THEN** Kumiko denies archival and preserves the project's existing state and records.

#### Scenario: Team server is unreachable during archival
- **WHEN** a user requests archival of a team project while the team server is unreachable
- **THEN** Kumiko reports the operation unavailable without reporting success, changing shared state locally, or queuing archival for automatic replay.

### Requirement: Permanent deletion is separate and limited to owned records
Kumiko SHALL require a separate, explicitly confirmed action for permanent project deletion and remove only that project's Kumiko-owned records. A solo local owner SHALL be able to delete their own project; team deletion SHALL require a current administrator within that project's team and an available team server. Deletion MUST NOT remove repositories, checkouts, worktrees, native agent histories, agent setups, or credentials.

#### Scenario: Confirm permanent deletion
- **WHEN** an authorized user explicitly confirms the separate permanent-deletion action for a project
- **THEN** Kumiko permanently removes that project's Kumiko-owned records rather than merely hiding the project from active views.

#### Scenario: Solo owner permanently deletes their project
- **WHEN** a solo local owner explicitly confirms the separate permanent-deletion action for their own project
- **THEN** Kumiko removes its owned records without requiring a team account or invitation.

#### Scenario: Team administrator permanently deletes a project
- **WHEN** a current administrator explicitly confirms permanent deletion of a project within their team while the team server is available
- **THEN** Kumiko removes that project's owned records without requiring personal project membership or lead responsibility.

#### Scenario: Cancel deletion confirmation
- **WHEN** a user cancels the permanent-deletion confirmation
- **THEN** the project and its records remain in their previous state without deletion.

#### Scenario: Project has linked external development resources
- **WHEN** an authorized user confirms permanent deletion for a project with repositories, checkouts, worktrees, native agent histories, agent setups, or credentials
- **THEN** deletion leaves all of those external resources untouched while removing only the project's Kumiko-owned records.

#### Scenario: Normal member attempts permanent deletion
- **WHEN** a normal team member attempts permanent deletion, including submitting a confirmation
- **THEN** Kumiko denies deletion and preserves the project's records.

#### Scenario: Normal-user creator or lead attempts permanent deletion
- **WHEN** a normal-user project creator or current lead explicitly confirms permanent deletion of that team project
- **THEN** Kumiko denies deletion because creation and lead responsibility do not grant administrator-only destruction authority.

#### Scenario: Administrator from another team attempts deletion
- **WHEN** an administrator of another team confirms permanent deletion without administrator authority in the project's team
- **THEN** Kumiko denies deletion and preserves the project's records.

#### Scenario: Team server is unreachable during deletion
- **WHEN** a user attempts permanent deletion of a team project while the team server is unreachable
- **THEN** Kumiko reports deletion unavailable without reporting success, deleting shared records locally, or queuing deletion for automatic replay.

### Requirement: Deleted project references preserve other projects' records
Kumiko MUST NOT delete or rewrite records in other projects merely because they reference a permanently deleted project or its records. Such references SHALL display "Deleted or unavailable" without retaining a readable copy of deleted target content. This MUST NOT authorize wholesale redaction of separately authored records or history.

#### Scenario: Another project references a permanently deleted target
- **WHEN** a project is permanently deleted and a record in another project references it or one of its records
- **THEN** the referencing record remains unchanged, and the reference displays "Deleted or unavailable" without a readable copy of the deleted target's content.

#### Scenario: Referencing record has separately authored content and history
- **WHEN** an otherwise retained record contains independently authored prose or history as well as a reference to a permanently deleted target
- **THEN** Kumiko preserves that prose and history rather than deleting or redacting them merely because of the reference, while the reference itself does not expose a retained copy of the deleted target.

### Requirement: Project deletion leaves running private sessions untouched
Permanent project deletion MUST NOT stop, restart, or otherwise alter already-running private agents or terminals. Deletion MUST NOT claim to retract context already read or sent to a model.

#### Scenario: Private work is running during project deletion
- **WHEN** a project is permanently deleted while private agents or terminals associated with it are running
- **THEN** those agents and terminals continue untouched rather than being stopped, restarted, or retargeted by deletion.

#### Scenario: A private agent already received deleted content
- **WHEN** project deletion occurs after a private agent has read project content or sent it to a model
- **THEN** Kumiko leaves the running private agent untouched and does not claim that deletion retracts the previously read or model-sent context.

### Requirement: Writes to deleted tasks fail without recreating them
Kumiko SHALL clearly fail attempts to write to a deleted task and MUST NOT recreate that task as a consequence of the attempted write.

#### Scenario: A user submits an edit after task deletion
- **WHEN** a user submits a task edit after that task has been deleted
- **THEN** Kumiko clearly reports the failed write and does not recreate the task.

#### Scenario: A running private agent writes after project deletion
- **WHEN** an already-running private agent attempts to update a task removed by permanent project deletion
- **THEN** Kumiko clearly reports the failed task write without recreating the task or stopping the private agent.
