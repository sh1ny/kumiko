# Spec Delta

## Purpose

Provide optional Kumiko-owned project documents and simple notes with permissioned discovery, canonical Markdown content, and clear separation from repository documents, independently of Tasks.

## ADDED Requirements

### Requirement: Documents and notes are optional independently of Tasks
Kumiko SHALL make project documents and notes optional knowledge surfaces usable without Tasks. Disabled surfaces MUST be hidden or inactive, with access through APIs and agent tools denied. Disabling MUST retain their content, ownership, privacy, revisions, and links; re-enabling MUST restore availability subject to access permissions and project deployment authority.

#### Scenario: Knowledge surfaces without Tasks
- **WHEN** project documents or notes are enabled while Tasks is disabled
- **THEN** authorized users can use the enabled knowledge surface without enabling Tasks.

#### Scenario: Tasks-only project
- **WHEN** a project enables Tasks but disables documents and notes
- **THEN** its task list and detail remain usable without those knowledge surfaces and their APIs or agent tools cannot bypass the disabled features.

#### Scenario: Disable and restore knowledge surfaces
- **WHEN** documents or notes are disabled and subsequently re-enabled
- **THEN** their prior content, ownership, privacy, revisions, and links remain available subject to current permissions and deployment authority rather than being deleted or granting new access.

### Requirement: Document storage follows project deployment
Kumiko SHALL own project documents and notes locally for solo projects and on the team server for team projects. Team document and note access MUST be unavailable when that server is disconnected rather than acting as an offline synchronized copy.

#### Scenario: Solo knowledge without a team server
- **WHEN** an authorized user opens enabled documents or notes in a solo project
- **THEN** its app-owned local content is available without a team server.

#### Scenario: Team server is unreachable
- **WHEN** a user attempts to read or edit team project documents or notes while its server is unreachable
- **THEN** Kumiko reports that knowledge surface unavailable without accepting hidden offline edits.

### Requirement: Simple project notes
Kumiko SHALL let authorized users read, create, and edit simple project notes when enabled, independently of the document library and Tasks. Notes SHALL retain canonical Markdown content and the same ownership, privacy, revision, and export protections as project documents, without requiring a canvas or rich editor.

#### Scenario: Create and revise a project note
- **WHEN** an authorized user creates a note and later edits it with notes enabled but Tasks disabled
- **THEN** the project retains the updated note and inspectable revisions under the project's deployment authority.

#### Scenario: Note writing is unavailable
- **WHEN** a user or agent attempts to create or edit a note while notes are disabled or the user lacks write access
- **THEN** the operation is denied without altering retained notes or bypassing access through another knowledge surface.

### Requirement: Pages support organization and work links
Kumiko SHALL provide nested project pages and document search when documents are enabled. Kumiko SHALL support links from documents and notes to native tasks or milestones only when the relevant features and permissions allow the action. Disabling a linked work feature MUST preserve existing content and links without allowing link creation or navigation to bypass that feature's access gate.

#### Scenario: Find a page linked to work
- **WHEN** an authorized user organizes nested pages and links a page to an accessible task or milestone with the relevant features enabled
- **THEN** the page can be found through library navigation or search and its work relationship is accessible.

#### Scenario: Search has no match
- **WHEN** a document search has no matching accessible pages
- **THEN** the library presents no matches rather than substituting unrelated or inaccessible pages.

#### Scenario: Linked work feature is disabled
- **WHEN** a document or note has a task or milestone link and the relevant work feature is disabled
- **THEN** the content and existing link are retained, but neither opening that link nor creating another work link bypasses the disabled feature through the UI, APIs, or agent tools.

### Requirement: Document ownership and privacy govern access
Kumiko SHALL represent document and note ownership and privacy and enforce permissions for content, discovery, creation, and editing. Feature availability MUST NOT grant access or override ownership and privacy.

#### Scenario: Authorized document access
- **WHEN** a user or their agent requests a document or note within the user's access with the relevant feature enabled
- **THEN** the content can be discovered and read according to its ownership and privacy settings.

#### Scenario: Private document is outside access
- **WHEN** a user or agent searches for, requests, or attempts to edit a document or note they cannot access
- **THEN** the request neither exposes restricted content through search or direct read nor changes that content.

### Requirement: Document and note body saves prevent silent overwrites
Kumiko SHALL save document and note body edits only by explicit Save. Human and authenticated API/agent saves MUST reject stale text at the authoritative write, not rely on a separate prior check. Conflicts MUST preserve current text and the attempted draft without reporting Saved. Users SHALL inspect current text alongside their draft, reconcile manually, and explicitly Save again with a fresh intervening-change check; live coediting, automatic merges, and force-overwrite bypasses are excluded.

#### Scenario: Save a current body edit
- **WHEN** an authorized user explicitly saves a document or note body based on its current saved text
- **THEN** the authoritative store accepts the edit and Kumiko reports Saved only after its acknowledgement.

#### Scenario: Another writer saves the same body first
- **WHEN** a human or authenticated API/agent attempts to save a document or note body after another writer has changed that body
- **THEN** the stale write is rejected without changing the current saved text, and the conflict retains the attempted draft and exposes current text alongside it only within current access.

#### Scenario: Text changes during manual reconciliation
- **WHEN** a user inspects current text alongside their conflicting draft, reconciles manually, and explicitly saves after another write intervenes
- **THEN** the authoritative write rejects that stale attempt again and preserves the newly attempted draft rather than merging or force-overwriting the newer text.

### Requirement: Remote body refresh preserves unfinished edits
Kumiko SHALL refresh clean document and note body views from authorized saved changes. Remote refresh MUST NOT replace unfinished local text edits. A dirty view SHALL preserve its draft and make a newer saved body inspectable subject to current access, without silently applying or merging that body into the draft.

#### Scenario: Clean body view receives a saved update
- **WHEN** a document or note body changes while an authorized user's open body view has no unfinished edits
- **THEN** the view refreshes to the saved body without requiring a save or creating a local edit.

#### Scenario: Saved update arrives during editing
- **WHEN** a document or note body changes while another user has unfinished edits to it
- **THEN** the unfinished draft remains intact, the newer saved text can be inspected within current access, and saving the stale draft remains subject to conflict rejection.

### Requirement: Failed body drafts recover locally without publication
Kumiko SHALL retain failed or conflicting document and note body drafts owner-locally across app restart, without upload, automatic retry, or publication. Explicitly discarded drafts MUST NOT return through recovery. Recovery MUST NOT grant offline shared reads/writes or expose current inaccessible content; new shared reads and saves require current access and server availability, and recovered saves retain stale-write protection.

#### Scenario: Failed body save survives restart
- **WHEN** a document or note body save fails or conflicts and the owner restarts Kumiko without discarding the draft
- **THEN** the attempted text is recoverable owner-locally without being uploaded, retried, or reported Saved.

#### Scenario: Recovered draft is stale
- **WHEN** an owner explicitly saves a recovered draft after the saved body has changed
- **THEN** the authoritative write rejects the stale attempt and retains the draft for authorized inspection and manual reconciliation.

#### Scenario: Explicit discard survives restart
- **WHEN** an owner explicitly discards a failed or conflicting body draft and later restarts Kumiko
- **THEN** recovery does not restore that discarded draft.

#### Scenario: Recovery occurs without shared access
- **WHEN** a team document or note draft is recovered while the server is unreachable or the owner no longer has access
- **THEN** the owner's retained local draft is preserved without exposing current restricted content or enabling shared reads, saves, or automatic resend after access returns.

### Requirement: Document revisions are inspectable
Kumiko SHALL provide inspectable revision history for project documents and notes when their respective features are enabled, subject to the content's access restrictions.

#### Scenario: Inspect prior document content
- **WHEN** an authorized user opens the history of a revised document or note with the respective feature enabled
- **THEN** its recorded revisions are available for inspection.

#### Scenario: Revision access is unauthorized
- **WHEN** a user cannot access a document or note, or its respective feature is disabled
- **THEN** requesting its revision history does not bypass those restrictions.

### Requirement: Markdown is canonical without repository replication
Kumiko SHALL use source-first Markdown as canonical project document and note content; a preview MUST NOT become a separately editable rich-document source of truth. Repository documents SHALL remain separate and accessible in their repository context; project documents and notes MUST NOT maintain competing writable canonical copies synchronized with them.

#### Scenario: Open library and repository documents
- **WHEN** a project contains both app-owned pages and repository documentation
- **THEN** the library pages retain canonical Markdown content while repository files remain accessible as separate repository documents.

#### Scenario: Repository document changes
- **WHEN** a repository document is edited outside the project library
- **THEN** Kumiko does not treat that edit as an automatic synchronization instruction for a competing library copy.

### Requirement: Agents discover documents on demand
Kumiko SHALL give agents a small project summary and permissioned document and note list, search, and read tools for enabled knowledge surfaces rather than automatically injecting their entire contents. All agent access MUST respect feature availability and user permissions. Document, note, and reference content MUST NOT itself become authority or agent instructions.

#### Scenario: Agent retrieves relevant context
- **WHEN** an agent needs project detail beyond the summary with the relevant knowledge surface enabled
- **THEN** it can discover relevant accessible documents or notes and request their content through permissioned tools.

#### Scenario: Document contains behavioral instructions
- **WHEN** a retrieved document or note tells the agent to change permissions or perform an unauthorized action
- **THEN** the content is treated as reference rather than authority granting that action.

### Requirement: Library documents can be exported
Kumiko SHALL provide Markdown and HTML export for accessible project documents and notes with their respective features enabled, without turning export into repository synchronization.

#### Scenario: Export accessible content
- **WHEN** an authorized user requests a Markdown or HTML export of project documents or notes with the respective features enabled
- **THEN** Kumiko produces that requested format for the authorized content.

#### Scenario: Export scope includes restricted content
- **WHEN** a requested export includes documents or notes outside the user's access or from a disabled knowledge surface
- **THEN** the export does not disclose that content or create an automatically synchronized repository copy.
