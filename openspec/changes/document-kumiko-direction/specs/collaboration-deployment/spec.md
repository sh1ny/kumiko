# Spec Delta

## Purpose

Separate solo work from server-backed collaboration, preserve negotiated mixed-version functionality, expose disconnection boundaries, and require consent for desktop updates.

## ADDED Requirements

### Requirement: Solo operation is independent
Kumiko SHALL support local solo storage, agents, files, and terminals without a Kumiko account, team server, Docker, or network backend. External agent providers and integrations retain their own connectivity requirements.

#### Scenario: Standalone local work
- **WHEN** a user opens a solo project without a team deployment
- **THEN** local project data, files, and terminals are usable without team sign-in or a backend service.

#### Scenario: No network connection
- **WHEN** a solo user loses network access
- **THEN** local work remains available without claiming that network-dependent providers or integrations are available.

### Requirement: First launch is ready for Personal work
On first desktop launch, Kumiko SHALL open the local Personal working set, ready for a local terminal or an already configured agent, without requiring an account, project creation, setup wizard, or team connection. Create project and Connect to team server SHALL be available without blocking local use. Agent availability MUST reflect the runtime's own configuration and authentication requirements.

#### Scenario: First launch with a configured agent
- **WHEN** a user launches Kumiko for the first time with an available configured agent runtime
- **THEN** Personal opens with local terminal and configured-agent entry points, alongside Create project and Connect to team server, without requiring setup or team sign-in.

#### Scenario: No agent is configured or authenticated
- **WHEN** a user first launches Kumiko without a configured agent or its required authentication
- **THEN** Personal and local terminal use remain available, and Kumiko identifies the agent's unmet requirements without claiming it is ready or making agent setup a prerequisite for local use.

### Requirement: Team connection identifies its destination
Kumiko SHALL let users enter a team server address, clearly identify the destination server/team before proceeding, and use that deployment's configured sign-in. Successful sign-in MUST NOT itself grant project membership; accepted projects and pending invitations SHALL remain distinct under project-access rules. A connection or sign-in failure, including missing configured authentication, MUST leave independent local work usable.

#### Scenario: User connects to an identified team
- **WHEN** a user enters a reachable team server address and proceeds with that identified destination
- **THEN** Kumiko uses the server's configured sign-in and, after success, distinguishes accepted projects from pending invitations without treating authentication as project membership.

#### Scenario: Team connection or authentication fails
- **WHEN** the server cannot be reached, has no usable configured authentication, or sign-in fails or is canceled
- **THEN** Kumiko reports why team access was not established while Personal, local files, terminals, and locally available agents remain usable.

### Requirement: Team association does not migrate solo data
Connecting to or signing in to a team server SHALL NOT upload, synchronize, or make team-visible prior solo projects or private sessions. Establishing a team association MUST preserve independent local work and the personal-development storage boundary rather than implicitly converting local records into shared team records.

#### Scenario: Existing solo user connects to a team
- **WHEN** a user with existing solo projects and private sessions successfully connects and signs in to a team server
- **THEN** those projects and sessions remain local and are not uploaded or exposed to the team.

#### Scenario: Team association is mistaken for publication authority
- **WHEN** a team administrator or shared feature requests existing solo projects or private sessions solely because their owner connected to the team
- **THEN** Kumiko does not provide or synchronize that local content through the team association.

### Requirement: Team collaboration uses an optional coordination server
Kumiko SHALL support an optional self-hosted team server for accounts, membership, permissions, shared projects, tasks, milestones, roadmaps, project documents, shared human project chats, shared project activity, and integration operations. Team coordination MUST remain distinct from local execution hosts and personal development state. Shared or project-owned discussion agents SHALL be outside initial scope.

#### Scenario: Authorized shared collaboration
- **WHEN** an authenticated team member accesses shared project content
- **THEN** the team server supplies that content according to the member's permissions.

#### Scenario: Team server is not an execution grant
- **WHEN** a member gains access to a shared project
- **THEN** that access alone does not grant execution authority on another member's host.

#### Scenario: Shared human chat remains available
- **WHEN** authorized project members use shared project chat in the initial release
- **THEN** their human conversation remains team-server collaboration without requiring a shared discussion agent.

#### Scenario: Personal chat agent is not a shared participant
- **WHEN** a team member opens their personal read-only chat agent alongside shared project chat
- **THEN** that agent runs locally with a private conversation rather than becoming a project-owned agent or shared chat transcript.

### Requirement: Personal development is outside team storage
Kumiko MUST keep private coding and read-only chat-agent sessions, terminals/output, local checkouts, branches, files/edits, and personal tabs/layouts on the user's PC, outside team upload, synchronization, indexing, and visibility. Team administration MUST NOT bypass this boundary or grant host access. Explicit user-authorized Git/integration publication and selected AI-provider requests SHALL remain separate operations, not automatic team mirroring.

#### Scenario: Shared project work does not copy personal state
- **WHEN** a member uses shared project planning and chat alongside personal development
- **THEN** the server stores the authorized shared project records without receiving the member's personal development state.

#### Scenario: Administrator requests personal environment access
- **WHEN** an administrator requests a member's personal environment through team administration or a bulk export
- **THEN** Kumiko does not provide the private sessions, terminal output, checkouts, files, or layouts, and does not grant execution-host authority.

#### Scenario: Local code analysis is not team publication
- **WHEN** a personal read-only chat agent inspects local code and reports findings to its owner
- **THEN** its code context, findings, and conversation stay outside team-server storage, search, and administrator access; selected AI-provider requests remain separate from team synchronization.

### Requirement: Task associations do not publish private work
Kumiko SHALL allow task context to accompany private work without replicating that work to the team server. Associating a task with a private session or workspace MUST NOT publish transcripts, prompts/tool output, terminal streams, working-copy bytes/diffs, private usage/history, or implicit access. Shared project activity MUST respect the same boundary.

#### Scenario: Private work is associated with a task
- **WHEN** a user associates a private coding session or local workspace with a shared task
- **THEN** the task association supplies planning context without uploading the private content or granting others access to the session or workspace.

#### Scenario: Shared activity attempts to expand an association
- **WHEN** a team activity view or task reader requests private output, diffs, or usage history through a task association
- **THEN** that association does not supply those records or authorize their upload to the team server.

### Requirement: Shared state is unavailable while disconnected
Kumiko MUST require the team server for shared chats, tasks, projects, milestones, roadmaps, documents, shared edits, assignments, and publication through team connections. When it is unreachable, these operations MUST report unavailable rather than succeed locally or enter a hidden edit queue.

#### Scenario: Connected shared edit
- **WHEN** an authorized member edits shared planning while the server is reachable
- **THEN** the operation uses the server-backed shared state.

#### Scenario: Server becomes unreachable
- **WHEN** a member attempts a shared read, edit, assignment, or team-connection publication while the server is unreachable
- **THEN** Kumiko reports the shared operation unavailable and does not report success or queue it for automatic replay.

### Requirement: Disconnection preserves independent local work
Kumiko SHALL keep local code, agents, terminals, and unrelated solo projects usable when the team server is unreachable. A disconnected execution host MUST be represented as having unknown current execution status, not completed work.

#### Scenario: Continue local development
- **WHEN** the team connection fails while a local checkout is open
- **THEN** local file work and locally available agents and terminals remain usable independently of shared features.

#### Scenario: Host status cannot be observed
- **WHEN** an execution host disconnects during task work
- **THEN** Kumiko shows current execution status as unknown rather than inferring task completion.

### Requirement: Reconnection refreshes authority and shared state
Kumiko SHALL validate the current session and permissions and fetch current shared state before re-enabling shared features after reconnection. It MUST NOT replay old task edits or local conversations against changed team records as offline synchronization.

#### Scenario: Authorized reconnection
- **WHEN** a member reconnects with a valid session and current permissions
- **THEN** shared features resume using freshly fetched shared state.

#### Scenario: Access changed during disconnection
- **WHEN** a reconnecting member no longer has access to a project
- **THEN** shared access remains unavailable for that project and old local actions are not replayed into it.

### Requirement: Client and server negotiate shared capabilities
Kumiko clients and team servers SHALL negotiate mutually supported protocol, client-facing schema, and capabilities when connecting or reconnecting. Shared functionality SHALL use that negotiated contract rather than assume matching release versions. A capability MUST NOT be enabled unless both peers support it and the initiating user has the required authority.

#### Scenario: Peers support different capability sets
- **WHEN** a client and server connect with overlapping protocol/schema support and different capability sets
- **THEN** the connection enables their mutually supported authorized capabilities rather than requiring equal release versions or enabling one-sided capabilities.

#### Scenario: Reconnection follows a peer upgrade
- **WHEN** a client reconnects after either peer has been upgraded
- **THEN** the peers negotiate current mutual support instead of using the previous connection's capability assumptions.

#### Scenario: Capability is supported but unauthorized
- **WHEN** both peers support a capability but the user lacks permission for its operation
- **THEN** negotiation does not grant that permission and the operation remains denied.

### Requirement: Client-first upgrades preserve existing functionality
A newer Kumiko client SHALL continue existing supported functionality against an older team server through their mutually compatible protocol and client-facing schema. New server-dependent features MUST remain unavailable until the server also supports them; a client update alone MUST NOT change existing supported behavior or require a server update to retain it.

#### Scenario: Client is upgraded before the server
- **WHEN** the client is upgraded while its server remains on the prior compatible version
- **THEN** existing shared functionality continues through the compatible contract without requiring the server to be upgraded first.

#### Scenario: New client feature lacks server support
- **WHEN** an upgraded client includes a feature requiring a capability absent from the connected server
- **THEN** that feature remains unavailable without disabling existing mutually supported functionality or sending the unsupported operation as though it were available.

### Requirement: Server-first upgrades preserve older client contracts
A newer Kumiko team server SHALL continue serving compatible older clients using backward-compatible protocol and client-facing schema contracts that preserve existing operation meanings. Server data/schema evolution MUST preserve those older client contracts rather than require all clients to upgrade simultaneously.

#### Scenario: Server is upgraded before clients
- **WHEN** the team server is upgraded while clients remain on their prior compatible version
- **THEN** those clients retain their existing supported operations and receive responses in a protocol and schema representation they support.

#### Scenario: New schema introduces fields older clients do not send
- **WHEN** an older compatible client sends a previously valid operation without fields introduced by the server upgrade
- **THEN** the operation retains its previous meaning rather than failing solely because the older client omitted newly introduced fields.

#### Scenario: Older client edits a record with newer fields
- **WHEN** an older compatible client edits fields it supports on a record that also contains server-side fields it cannot represent
- **THEN** the edit updates its supported fields without silently erasing the newer fields merely because the client did not send them.

### Requirement: Desktop update installation requires user consent
Kumiko SHALL notify the desktop user when an update is available and install it only after the user explicitly consents to installation. Update availability, opening or dismissing the notification, and absence of a response MUST NOT themselves authorize installation.

#### Scenario: User consents to install an available update
- **WHEN** a desktop update is available, the user explicitly consents to installation, and any required interruption of running work has also been explicitly authorized
- **THEN** Kumiko initiates installation of that update through the supported platform mechanism.

#### Scenario: User has not consented
- **WHEN** an update is available but the user has not responded to its notification
- **THEN** Kumiko presents the update notification without installing the update automatically.

#### Scenario: User opens or dismisses the notification
- **WHEN** the user opens or dismisses the update notification without explicitly consenting to installation
- **THEN** Kumiko does not install the update as a consequence of that interaction.

### Requirement: Update-related work interruption requires explicit consent
For an update requiring interruption of running agents or terminals, Kumiko SHALL identify the affected work and wait for explicit user consent to stop it before proceeding with the interrupting update. Installation consent alone MUST NOT authorize interruption. Declined or unanswered interruption requests SHALL leave the affected work running and allow postponement.

#### Scenario: User authorizes the identified interruption
- **WHEN** the user consents to installation and explicitly agrees to stop the identified agents or terminals required by the update
- **THEN** update-related interruption targets only that authorized work before the update proceeds.

#### Scenario: Installation is approved without interruption consent
- **WHEN** the user approves installation but has not consented to stop work that the update requires interrupting
- **THEN** the interrupting update waits and Kumiko does not stop the affected agents or terminals.

#### Scenario: User declines or leaves the interruption request unanswered
- **WHEN** the user declines or does not answer a request to stop affected work for an update
- **THEN** Kumiko leaves that work running and permits postponing the update rather than interrupting it automatically.
