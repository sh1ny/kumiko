# Spec Delta

## Purpose

Add permissioned Kumiko context and tools to existing agent setups without replacing native configuration or assuming universal MCP discovery.

## ADDED Requirements

### Requirement: Native agent setup is preserved
Kumiko MUST preserve native credentials, model settings, personal and repository instructions, skills, MCP entries, extensions, and hooks. Kumiko session, project, workspace, and task context and explicit optional project guidance SHALL be additive rather than silently replacing native setup or requiring a universal skill or plugin manager.

#### Scenario: Launch with existing native configuration
- **WHEN** a user starts an agent with existing native settings and optional Kumiko project guidance
- **THEN** the agent retains its native setup while receiving the selected Kumiko context and guidance additively.

#### Scenario: Existing registration occupies configuration
- **WHEN** native configuration already contains unrelated MCP entries or instructions
- **THEN** Kumiko does not silently overwrite or remove them to add its own connection.

### Requirement: Project agent instructions are optional versioned guidance
Kumiko SHALL offer optional explicit Project settings > Agent instructions separately from the reference document library. Guidance SHALL be versioned and MAY link project documents instead of copying them. Library membership MUST NOT automatically select a document as guidance, and instruction links MUST NOT grant access.

#### Scenario: Configure linked project guidance
- **WHEN** an authorized user chooses optional Agent instructions in Project settings and links an accessible project document
- **THEN** Kumiko records versioned project guidance without requiring a separate copy of that document.

#### Scenario: Reference document is not selected as guidance
- **WHEN** a document exists in the project reference library but has not been selected as Agent instructions
- **THEN** Kumiko does not automatically treat it as project guidance or grant an agent access to it.

### Requirement: Project instruction text saves prevent silent overwrites
Kumiko SHALL save project-instruction text only by explicit Save. Human and authenticated API/agent saves MUST reject stale text at the authoritative write, not rely on a separate prior check. Conflicts MUST preserve current text and the attempted draft without reporting Saved. Users SHALL inspect current text alongside their draft, reconcile manually, and explicitly Save again with an intervening-change recheck; live coediting, automatic merges, and force-overwrite bypasses are excluded.

#### Scenario: Save current project instruction text
- **WHEN** an authorized user explicitly saves project-instruction text based on its current saved value
- **THEN** the authoritative store accepts the new revision and Kumiko reports Saved only after its acknowledgement, without changing any existing session's adopted guidance.

#### Scenario: Instruction text changes before save
- **WHEN** a human or authenticated API/agent attempts to save project-instruction text that another writer has already changed
- **THEN** the stale write is rejected without changing the saved revision, and the attempted draft and current text remain available for side-by-side inspection only within current access.

#### Scenario: A second change races with reconciliation
- **WHEN** a user manually reconciles current instruction text with their draft and another write intervenes before their explicit Save commits
- **THEN** the authoritative write rejects the newly stale attempt, preserves the attempted text, and requires another inspection and explicit Save rather than merging or bypassing the conflict.

### Requirement: Instruction text refresh preserves unfinished edits
Kumiko SHALL refresh clean project-instruction text views from authorized saved changes without adopting guidance into active sessions. Remote refresh MUST NOT replace unfinished local instruction text. A dirty view SHALL retain its draft and make newer saved text inspectable subject to current access, without silently applying or merging it.

#### Scenario: Clean instruction view refreshes
- **WHEN** project-instruction text changes while an authorized user's open instruction editor has no unfinished edits
- **THEN** the editor refreshes to the saved text without applying that revision to an existing session.

#### Scenario: Remote instruction change arrives during editing
- **WHEN** project-instruction text changes while another user has unfinished edits
- **THEN** the local draft remains intact, the newer saved text can be inspected within current access, and a stale save cannot overwrite it.

### Requirement: Failed instruction drafts recover owner-locally
Kumiko SHALL retain failed or conflicting project-instruction text drafts owner-locally across restart, without upload, automatic retry, or publication. Explicitly discarded drafts MUST NOT return through recovery. Recovery MUST NOT grant offline shared reads/writes or expose current inaccessible guidance. Shared reads and saves still require current access and server availability; recovered saves remain stale-write protected and do not adopt guidance into sessions.

#### Scenario: Instruction save failure survives restart
- **WHEN** a project-instruction text save fails or conflicts and its owner restarts Kumiko without discarding the draft
- **THEN** the attempted text is recoverable owner-locally without automatic save, upload, retry, or session delivery.

#### Scenario: Recovered instruction text is stale
- **WHEN** an owner explicitly saves recovered instruction text after the saved guidance has changed
- **THEN** the authoritative write rejects the stale attempt, retains the draft, and requires authorized inspection and manual reconciliation before another explicit Save.

#### Scenario: Discarded instruction draft stays discarded
- **WHEN** an owner explicitly discards a failed or conflicting instruction draft and later restarts Kumiko
- **THEN** recovery does not restore the discarded text.

#### Scenario: Recovery cannot bypass lost access
- **WHEN** an instruction draft is recovered while its team server is unavailable or its owner lacks current project access
- **THEN** the retained owner-local draft does not expose current inaccessible guidance, enable shared reads or writes, or trigger automatic resend after access returns.

### Requirement: Launch identifies selected project guidance
Kumiko SHALL show the selected project guidance and revision and the receiving project/workspace at agent launch. Guidance SHALL be additive to authoritative native configuration and MUST NOT confer permissions or imply that all available guidance has been selected or delivered.

#### Scenario: Launch with selected guidance
- **WHEN** an owner launches an agent with project guidance selected
- **THEN** Kumiko identifies that guidance, its revision, and the receiving project/workspace while preserving authoritative native setup.

#### Scenario: Guidance requests additional authority
- **WHEN** selected guidance requests access or operations beyond the session's existing authority
- **THEN** its selection does not grant that access or authorize those operations.

### Requirement: Existing sessions adopt guidance updates only by owner choice
Shared guidance edits MUST NOT silently change an existing session's adopted revision. Kumiko SHALL show a quiet Project instructions updated indicator, not blocking or actionable attention. Only the session owner SHALL inspect changes and explicitly apply a revision. Updates MUST NOT interrupt an active turn, silently queue new instructions, or steer the session in the background.

#### Scenario: Shared guidance changes after launch
- **WHEN** shared project guidance changes while an existing session uses an earlier revision
- **THEN** Kumiko retains its adopted revision and shows the quiet update indicator without creating a blocking or actionable attention item.

#### Scenario: Owner explicitly applies a revision
- **WHEN** the session owner inspects the guidance changes and explicitly chooses to apply a revision
- **THEN** only that explicit choice authorizes delivering the revision, subject to the adapter's actual capability and confirmation.

#### Scenario: Update occurs during an active turn
- **WHEN** guidance changes while the session is actively working
- **THEN** the active turn is unaffected and Kumiko neither injects nor silently queues the new instructions.

#### Scenario: Another project participant edits guidance
- **WHEN** a participant other than the session owner edits shared guidance
- **THEN** that edit does not apply the revision to the owner's session or authorize that participant to make the session adopt it.

### Requirement: Guidance delivery state is capability-honest
Kumiko SHALL distinguish guidance available to a session, selected for delivery, and delivered. Delivered state SHALL depend on actual adapter confirmation; selection or an apply request alone MUST NOT be reported as delivery or adoption when delivery is unconfirmed.

#### Scenario: Adapter confirms guidance delivery
- **WHEN** the owner selects a revision for delivery and the adapter confirms its delivery
- **THEN** Kumiko can identify that revision as delivered rather than merely available or selected.

#### Scenario: Delivery cannot be confirmed
- **WHEN** a revision is selected or explicitly applied but the adapter cannot confirm delivery
- **THEN** Kumiko shows delivery as unconfirmed and does not claim that the session received or adopted the revision.

### Requirement: AI provider accounts remain native
Kumiko SHALL use the agent runtime's existing authenticated AI-provider setup. AI-provider account provisioning, sign-in, credential management, subscription administration, and billing SHALL remain outside Kumiko's scope. Observational usage statistics MUST NOT imply account-management authority. Kumiko sign-in and GitHub/Jira integration authorization remain separate capabilities.

#### Scenario: Runtime already has an authenticated provider
- **WHEN** a user opens a session with a runtime that already has an authenticated AI-provider setup
- **THEN** the session uses that native setup without requiring a separate Kumiko-managed AI-provider account.

#### Scenario: Native provider authentication is missing
- **WHEN** the runtime reports that its AI-provider authentication is missing or expired
- **THEN** Kumiko reports the native authentication requirement rather than creating, signing into, or managing a provider account itself.

### Requirement: Supported native controls are surfaced
Kumiko SHALL expose the connected runtime's supported model and effort options and surface available commands and skills while the user types the corresponding command input. These controls MUST respect the session's authority and the actual runtime/adapter capabilities rather than imply identical options across runtimes.

#### Scenario: Runtime exposes controls and command discovery
- **WHEN** a connected runtime exposes model/effort choices and discoverable commands or skills
- **THEN** Kumiko offers those supported choices and matching command/skill suggestions.

#### Scenario: Capability is unavailable for the session
- **WHEN** a runtime/adapter does not support an effort control or command/skill discovery
- **THEN** Kumiko indicates that limitation rather than presenting fabricated choices or silently substituting another runtime's commands.

### Requirement: Kumiko tool authority is authenticated and scoped
Kumiko SHALL provide a local host-owned MCP service with project and repository enablement and authenticated session authority. Selected project, repository, workspace, or task identifiers MUST NOT themselves authorize access. A repository SHALL be able to participate in multiple Kumiko projects without merging their access scopes.

#### Scenario: Authorized session selects project context
- **WHEN** an authenticated agent session selects an enabled project and repository within its owner's access
- **THEN** Kumiko tools operate within that authorized context.

#### Scenario: Session supplies an unauthorized project identifier
- **WHEN** a session selects an identifier for a project it cannot access, including another project using the same repository
- **THEN** the service denies unauthorized access rather than treating the identifier or shared repository as authority.

### Requirement: Tool text writes share human conflict protections
Authenticated API and agent-tool writes to document bodies, note bodies, and project-instruction text MUST enforce the same authoritative stale-write rejection as human saves. A prior read or permission check MUST NOT substitute for protection at the write. A failed or conflicting tool write MUST report that outcome without claiming Saved, retrying an overwrite, merging automatically, or granting authority beyond current access.

#### Scenario: Authorized tool saves unchanged-base text
- **WHEN** an authenticated API or agent tool explicitly saves text based on its current saved value within its existing write authority
- **THEN** the authoritative store can accept that write and confirms its result without granting new permissions or applying instructions to an existing session.

#### Scenario: Competing write lands after a tool read
- **WHEN** an authenticated API or agent tool reads authorized text and another writer changes it before the tool's write commits
- **THEN** the authoritative write rejects the stale attempt and reports the conflict without overwriting the newer text or claiming Saved.

#### Scenario: Tool access is revoked after reading
- **WHEN** an authenticated API or agent tool reads shared text and loses write access before attempting its save
- **THEN** the save is denied without changing content, disclosing newly inaccessible current text, or automatically retrying if access later returns.

### Requirement: Tool operations respect the session role
Kumiko MUST enforce role-appropriate operations and local/shared privacy boundaries through its tools. A discussion session MUST NOT gain command execution, code modification, or Git mutation through indirect paths. Team-facing tools MUST NOT expose private coding history, terminals, local working-copy content, or personal layouts, including to project administrators.

#### Scenario: Discussion session reads authorized context
- **WHEN** an owner's discussion session requests content the owner can access
- **THEN** role-appropriate reads can return content within the applicable local/shared boundary without exposing private coding work to a shared conversation or granting execution authority.

#### Scenario: Administrator queries another person's local work
- **WHEN** a team administrator supplies project or workspace identifiers to a team-facing tool to request another person's private session, terminal output, local files, or layout
- **THEN** the tool neither returns nor uploads that private material, regardless of the administrator's project access.

#### Scenario: Discussion session invokes a mutation path
- **WHEN** a discussion session requests a code, execution, or Git write through Kumiko tools or an indirect tool path
- **THEN** the prohibited operation is denied rather than delegated or executed under another role.

### Requirement: Automatic connection uses supported native mechanisms
Kumiko SHALL set up its tool connection for Kumiko-launched agents using the known runtime, adapter, and version: qualified session injection when supported, otherwise additive stable repository registration in that runtime's supported native format. It MUST NOT assume universal discovery of a file named `.mcp.json` or treat host-owned tools as proof of MCP registration.

#### Scenario: Qualified launch-time injection is available
- **WHEN** Kumiko launches an agent whose runtime and adapter version support qualified connection injection
- **THEN** the launched session receives the Kumiko tool connection through that supported mechanism.

#### Scenario: Launch-time injection is unavailable
- **WHEN** injection is unavailable but the runtime supports native repository registration
- **THEN** Kumiko uses additive registration in that supported format rather than claiming injection or relying on universal `.mcp.json` discovery.

### Requirement: Repository registration is stable and secret-free
Kumiko MUST preserve existing entries and keep secrets out of repository connection files, avoiding per-session rewrites of shared registration for concurrent sessions. Prepared native repository registration SHALL be usable by manually launched agents without claiming launch-time injection outside Kumiko's launch path.

#### Scenario: Manual launch uses prepared registration
- **WHEN** an agent is launched manually in a repository with prepared runtime-supported Kumiko registration
- **THEN** it can use that registration subject to authenticated session authority without requiring Kumiko launch-time injection.

#### Scenario: Concurrent sessions use shared registration
- **WHEN** multiple sessions use the same registered repository
- **THEN** their session identities do not require overwriting shared registration or writing session secrets into repository files.
