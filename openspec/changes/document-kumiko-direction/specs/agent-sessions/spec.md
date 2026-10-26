# Spec Delta

## Purpose

Provide local private conversations with existing agent runtimes while keeping shared project chats, saved history, running work, and desktop visibility distinct.

## ADDED Requirements

### Requirement: Existing runtimes share a capability-aware interface
Kumiko SHALL provide its agentic development interface on Windows, Linux, and macOS using existing Claude Code, Codex, and OMP runtimes. Common conversation concepts SHALL be normalized without promising identical adapter features or substituting a terminal connection for an agent protocol.

#### Scenario: Supported runtime conversation
- **WHEN** a user opens a session with a supported configured runtime
- **THEN** Kumiko presents its conversation through the common interface with that adapter's supported controls.

#### Scenario: Adapter lacks a feature
- **WHEN** an adapter does not support a richer control available in another adapter
- **THEN** Kumiko does not present that control as supported for the session.

### Requirement: Private coding conversations remain local
Kumiko MUST keep private coding-agent conversations and history on the user's PC. Their transcripts, prompts, tool output, and session-derived indexes MUST NOT be uploaded, synchronized, indexed, or exposed through the team server, including to administrators. This SHALL be a storage and transport boundary, not a permission setting or optional private-transcript sync mode.

#### Scenario: Private conversation remains available locally
- **WHEN** a user continues a private coding conversation while connected to a team project
- **THEN** its saved history remains locally available without being copied into team storage or team search.

#### Scenario: Administrator requests a private session
- **WHEN** a team administrator requests or searches for another user's private session, transcript, or tool output
- **THEN** the team server supplies none of that personal content or its private search index, regardless of project authority.

#### Scenario: Private transcript synchronization is requested
- **WHEN** a user or administrator requests team synchronization of a private coding conversation
- **THEN** Kumiko does not offer a private-transcript upload or team-sharing option.

### Requirement: Provider requests are separate from team synchronization
Kumiko SHALL keep user-authorized requests to selected AI providers separate from team-server transport. Local-only conversation storage MUST NOT imply network-silent model execution or replace the runtime's existing provider authentication and connectivity constraints. Sending an authorized provider request MUST NOT authorize copying the private session to the team server.

#### Scenario: Selected provider serves a private conversation
- **WHEN** the user authorizes a private coding session to use a configured network-dependent provider
- **THEN** the runtime can send its authorized model request without publishing the session to the team server.

#### Scenario: Team connection exists without provider connectivity
- **WHEN** the team server is reachable but the selected provider is unavailable
- **THEN** Kumiko does not claim that the private model request succeeded or treat the team server as a replacement destination for its conversation.

### Requirement: Agent tab close depends on running work
Kumiko SHALL close idle agent tabs and their processes without confirmation, preserving saved history. Closing a working agent SHALL warn "Are you sure you want to stop the running agent?" Cancellation MUST keep work running; confirmation SHALL stop and close the agent without deleting history or reverting written files. Tab close MUST NOT merely hide running work; whole-app exit SHALL follow the workbench exit policy.

#### Scenario: Close an idle conversation
- **WHEN** a user closes an idle agent tab
- **THEN** the tab and its agent process close without a confirmation prompt while its saved conversation history remains available.

#### Scenario: Cancel closing a working agent
- **WHEN** a user closes a working agent tab and cancels the running-agent warning
- **THEN** the tab remains open and its work continues.

#### Scenario: Confirm closing a working agent
- **WHEN** a user confirms the warning "Are you sure you want to stop the running agent?"
- **THEN** Kumiko stops and closes that agent without deleting saved history or reverting files already written.

### Requirement: Live session ownership is independent of layout
Kumiko SHALL retain execution-host ownership of live agent processes while the app is running. Navigation, tab rearrangement, and sidebar collapse MUST NOT close or restart sessions. This separation of process ownership from views MUST NOT promise process survival after app quit, host failure, or reboot.

#### Scenario: Rearrange or navigate without closing
- **WHEN** a user navigates away from a conversation, rearranges tabs, or collapses the sidebar while Kumiko remains open
- **THEN** the existing session continues without being closed or restarted.

#### Scenario: Explicit close is not a layout change
- **WHEN** a user explicitly closes a working agent tab rather than changing its placement or visibility
- **THEN** Kumiko applies the working-agent close warning and decision instead of preserving hidden running work.

### Requirement: Sessions history resumes the original conversation
Kumiko SHALL list local prior agent chats in the right-side Sessions history within their project/workspace or Personal context. Reopening SHALL use the original runtime and saved session identity through supported resume, not create a new conversation or rerun the original task. Missing history or unsupported or unavailable resume MUST be visible and MUST NOT be reported as successful continuation.

#### Scenario: Reopen a saved conversation
- **WHEN** a user selects a prior chat in the right-side Sessions history and its original runtime supports resume for that saved session
- **THEN** Kumiko reopens that conversation in its original project/workspace or Personal context using the original runtime and session identity without resubmitting the original task.

#### Scenario: Saved conversation cannot resume
- **WHEN** the selected history is missing or its runtime or adapter version cannot support or complete resume
- **THEN** Kumiko visibly reports the unavailable history or resume, does not claim continuation succeeded, and does not substitute a new conversation or replay the task.

### Requirement: Unsent conversation drafts remain local and scoped
Kumiko SHALL retain unsent private and shared-project chat drafts locally for their original conversation across switching, tab closure, and restart without a retention prompt. Drafts MUST NOT reach team storage, search, or administrators, be sent automatically, or move to another conversation. Retention MUST NOT grant offline shared-history access or create an offline send queue; shared sends SHALL require server availability and access.

#### Scenario: Return to a draft after closing or restarting
- **WHEN** a user writes an unsent private or shared-project message, switches conversations, closes its tab, or restarts Kumiko, then reopens the original conversation
- **THEN** its draft remains locally associated with that conversation without requiring a prompt merely to retain it.

#### Scenario: Another conversation or team service requests a draft
- **WHEN** a user opens a different conversation or the team server, search, or an administrator requests unsent draft content
- **THEN** the original draft is not retargeted or supplied to that conversation or team service.

#### Scenario: Shared conversation is unavailable offline
- **WHEN** a shared-project draft exists locally but the server is unavailable or access to its conversation is absent
- **THEN** retaining the draft does not grant access to shared history, send the message, or queue it for automatic sending.

#### Scenario: Exit discards file edits but not chat drafts
- **WHEN** a user explicitly discards unsaved file edits while closing Kumiko
- **THEN** the separate unsent chat drafts remain locally retained for their original conversations and are not sent or deleted by the file-discard decision.

### Requirement: Ask agent prepares a destination-bound draft
Ask agent about this SHALL prepare a draft without sending it. The receiving session and project/workspace or Personal context SHALL be explicit, never silently chosen from the last-active agent. Switching tabs, projects, or workspaces MUST NOT move the draft or attachments to another conversation. Sending SHALL require explicit Send.

#### Scenario: Prepare context for an identified session
- **WHEN** a user invokes Ask agent about this for selected text, files, tasks, or project documents and identifies the receiving session
- **THEN** Kumiko prepares an unsent draft showing that session and its project/workspace or Personal context.

#### Scenario: No receiving session has been identified
- **WHEN** a user invokes Ask agent about this without an explicit destination
- **THEN** Kumiko does not silently address or send the draft to the last-active agent.

#### Scenario: Navigate away from a prepared draft
- **WHEN** a user switches tabs, projects, or workspaces after preparing a draft with attachments
- **THEN** the draft and attachments remain associated with their original conversation rather than following the active view.

### Requirement: Draft attachments are visible and removable
Selected text, files, tasks, and project documents attached to a draft SHALL have visible readable labels and preview and remove controls. Kumiko MUST NOT add hidden prompt context through these attachments. Removing an attachment SHALL exclude it from the context submitted by that draft.

#### Scenario: Review attached context before sending
- **WHEN** a user attaches selected text, a file, a task, or a project document
- **THEN** the draft exposes a readable attachment label and controls to preview or remove that attachment before Send.

#### Scenario: Remove an attachment
- **WHEN** a user removes an attachment and then explicitly sends the draft
- **THEN** the removed attachment is not included as submitted context or silently reintroduced as hidden prompt content.

### Requirement: Selected text attachments preserve inspectable snapshots
Selected text SHALL be attached as a snapshot identifying its source, available revision, and range. Unsaved text SHALL be labeled as unsaved; attaching it MUST NOT save the file. Source changes before Send SHALL be flagged while retaining the original snapshot until explicit refresh; Kumiko MUST NOT silently replace it.

#### Scenario: Attach unsaved selected text
- **WHEN** a user attaches selected text from an unsaved editor buffer
- **THEN** the attachment preserves that text as a labeled unsaved snapshot with its source, range, and available revision information without saving the file.

#### Scenario: Source changes before sending
- **WHEN** the source of an attached text snapshot changes before Send
- **THEN** Kumiko flags the change and preserves the original snapshot rather than silently substituting the changed text.

#### Scenario: Refresh a changed snapshot explicitly
- **WHEN** the user explicitly refreshes an attachment after inspecting a source-change indication
- **THEN** Kumiko updates the snapshot and its visible source information to reflect the refreshed selection.

### Requirement: Draft context preserves existing authority and privacy
Attachments SHALL be conversation context, not project guidance or additional grants. Drafts and attachments SHALL retain the existing owner-local persistence and privacy boundary, with no automatic team publication or private-upload option. Explicit Send SHALL respect current access, session authority, and applicable server requirements; retention MUST NOT create an offline send queue.

#### Scenario: Explicitly send authorized context
- **WHEN** a user selects Send for a draft whose destination and attached context are authorized under the existing session and access rules
- **THEN** Kumiko submits the draft to that destination without adopting attachments as project guidance, granting permissions, or publishing private coding context through the team server.

#### Scenario: Shared destination is unavailable or access is lost
- **WHEN** a user selects Send for a shared-project draft while the server is unavailable or current access is absent
- **THEN** Kumiko does not send or queue it automatically, and the unsent draft and attachments remain owner-local under the existing draft persistence rules.

#### Scenario: Retain attachments across reopening
- **WHEN** a user closes and reopens the conversation or restarts Kumiko with an attached unsent draft
- **THEN** the draft and attachments remain locally associated with that original conversation without team storage, team search, administrator exposure, or automatic sending.

### Requirement: Stop interrupts current work without deleting the session
Kumiko SHALL make Stop in chat interrupt the current turn and active tool work where the runtime supports interruption. Stop MUST preserve the conversation and existing changes; terminating the session or process SHALL be a separate action.

#### Scenario: Interrupt supported active work
- **WHEN** a user selects Stop during interruptible agent or tool work
- **THEN** Kumiko requests interruption of that current work without deleting the conversation or undoing existing changes.

#### Scenario: Interruption is unsupported
- **WHEN** active work cannot be interrupted through the runtime's supported controls
- **THEN** Kumiko does not claim that the work was interrupted or silently substitute session termination.

### Requirement: Recovery preserves saved history without replay guarantees
Kumiko SHALL preserve saved conversation history across desktop UI failure and use supported runtime behavior for recovery or continuation. It MUST NOT silently replay side effects or promise that the same process survives host failure or reboot. This normal same-machine saved-session recovery SHALL remain distinct from Kumiko data backup restoration, which excludes agent conversation histories.

#### Scenario: Recover after desktop UI failure
- **WHEN** a user reopens Kumiko after a desktop UI crash
- **THEN** saved conversation history remains available for reopening and supported continuation.

#### Scenario: Execution host restarts
- **WHEN** the host crashes or reboots during agent work
- **THEN** saved history is not treated as proof that the original process survived, and side-effecting work is not silently replayed.

#### Scenario: Restore records without the prior conversation history
- **WHEN** Kumiko-owned records are restored from backup and the referenced agent conversation history is absent
- **THEN** Kumiko does not present that history as restored or recreate it automatically; normal same-machine saved-history recovery does not imply backup inclusion.
