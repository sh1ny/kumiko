# Spec Delta

## Purpose

Define invitation-based access to team project records, bounded administrator and project-lead responsibilities, and separation from personal execution authority.

## ADDED Requirements

### Requirement: Account roles remain distinct from project responsibility
Kumiko SHALL initially provide exactly two account roles: normal user and administrator. Project lead SHALL be a project-specific responsibility, not a third account role or a fine-grained permission framework.

#### Scenario: Normal user leads a project
- **WHEN** a normal user has project-lead responsibility for a project
- **THEN** the account remains a normal user with that project's lead responsibility.

#### Scenario: Lead responsibility does not promote an account
- **WHEN** a project lead attempts an administrator-only operation based solely on being a lead
- **THEN** Kumiko denies the operation without treating the lead as an administrator.

### Requirement: Normal users can create projects as initial member and lead
Kumiko SHALL allow a normal team user to create a project and become its initial member and project lead without a self-invitation or acceptance step. Creation MUST NOT promote the account to administrator, grant administrator-only permanent-deletion authority, or grant additional lead powers beyond the project's defined responsibility.

#### Scenario: Normal user creates a project
- **WHEN** a normal team user creates a project
- **THEN** the creator is immediately its initial member and project lead while retaining the normal-user account role.

#### Scenario: Creator has no accepted invitation
- **WHEN** the creator opens their newly created project without having sent or accepted a self-invitation
- **THEN** the creator can access and participate in the project through initial membership without an invitation gate.

### Requirement: Normal users join team projects through accepted invitations
Apart from initial membership granted at project creation, Kumiko SHALL require a project invitation and acceptance before a normal user becomes a member who can see shared records and participate. Team membership, sign-in, or a pending invitation MUST NOT grant that access. An administrator sending the invitation SHALL NOT waive acceptance for a normal recipient.

#### Scenario: Invited user accepts
- **WHEN** an invited normal user accepts the invitation to a team project
- **THEN** the user becomes a project member who can see its shared records and participate.

#### Scenario: Signed-in team member has not accepted
- **WHEN** a signed-in normal team member who is not the project's creator has no invitation or has not accepted a pending invitation to a project
- **THEN** the account is not a project member and cannot browse its shared records or participate.

#### Scenario: Administrator sends invitation to normal user
- **WHEN** an administrator invites an account whose role remains normal user
- **THEN** the recipient still needs to accept before gaining project membership and participation.

### Requirement: Invitations target an existing internal account
Kumiko MUST bind each invitation to a specific existing internal Kumiko account on the server, not an email address or bearer link. A person without an account MUST first establish one under the deployment's registration or SSO rules. A different provider SHALL preserve invitation eligibility only through established account linkage; email matching MUST NOT transfer invitations.

#### Scenario: Existing intended account accepts
- **WHEN** the existing internal account targeted by a valid pending invitation explicitly accepts it
- **THEN** Kumiko grants membership to that account rather than to the holder of an email address or link.

#### Scenario: Wrong account opens an invitation link
- **WHEN** another signed-in account opens or attempts to accept the intended recipient's invitation link
- **THEN** it gains no membership or access to the project's shared records, even if it holds the link.

#### Scenario: Intended recipient has no account
- **WHEN** an inviter wants to invite someone who has no internal account on that server
- **THEN** that person must establish an account under the deployment's registration or SSO rules before an invitation can target it.

#### Scenario: Recipient uses a linked provider
- **WHEN** the recipient signs in through a different provider already linked to the targeted internal account
- **THEN** the invitation remains associated with that same internal account.

#### Scenario: Matching email belongs to a different account
- **WHEN** another provider signs a person into a different internal account with a matching email address
- **THEN** the invitation is not transferred and that account cannot accept it.

### Requirement: Pending invitations expose a bounded explicit decision
Kumiko SHALL show pending invitations in-app separately from joined projects, with server/team, project name, inviter, visible expiry, and explicit Accept and Decline actions, without task, chat, or document disclosure. Invitations SHALL have copyable links for manual delivery without a required email service. Opening a link MUST NOT accept an invitation or grant project access.

#### Scenario: Recipient inspects a pending invitation
- **WHEN** the intended recipient views their pending invitations
- **THEN** the invitation appears separately from joined projects with its server/team, project name, inviter, expiry, and Accept and Decline actions, without exposing tasks, chats, or documents.

#### Scenario: Inviter delivers a link manually
- **WHEN** an authorized inviter copies a pending invitation's link for manual delivery
- **THEN** Kumiko provides the link without requiring an email service.

#### Scenario: Recipient opens a link without accepting
- **WHEN** the intended recipient opens a valid invitation link but does not choose Accept
- **THEN** membership and shared-record access remain unchanged.

#### Scenario: Recipient declines
- **WHEN** the intended recipient explicitly chooses Decline on a pending invitation
- **THEN** the invitation becomes declined without adding the project to joined projects or granting access.

### Requirement: Invitation validity cannot restore revoked membership
Kumiko MUST make invitations time-limited and deny membership through expired, declined, revoked, or otherwise invalid invitations. Administrators SHALL be able to revoke pending invitations within their team. Accepting the same invitation again MUST NOT duplicate membership or restore later-revoked membership. Replacements SHALL require separate explicit acceptance; prior sessions or invitations MUST NOT authorize rejoining.

#### Scenario: Valid invitation accepted more than once
- **WHEN** the intended recipient repeats acceptance of an invitation that already granted their current membership
- **THEN** the project retains one membership for that account rather than creating duplicates.

#### Scenario: Invalid invitation is used
- **WHEN** a user opens or attempts to accept an expired, declined, revoked, or otherwise invalid invitation
- **THEN** Kumiko indicates it cannot be used and grants no membership or shared-record access.

#### Scenario: Administrator revokes a pending invitation
- **WHEN** an administrator revokes a pending invitation for a project within their team
- **THEN** the invitation is no longer usable to grant membership.

#### Scenario: Replacement invitation is issued
- **WHEN** a replacement invitation targets the intended account after an earlier invitation expired, was declined, or was revoked
- **THEN** the replacement grants no membership until the recipient separately accepts it.

#### Scenario: Accepted invitation is reused after membership revocation
- **WHEN** a former normal member tries to rejoin using their previously accepted invitation or existing session after an administrator revoked membership
- **THEN** Kumiko does not restore membership and requires fresh authorization through a new valid invitation and acceptance.

### Requirement: Administrators participate throughout their own team
Kumiko SHALL let an administrator see and participate in every project's shared tasks, chats, and documents within their team without a personal project invitation, acceptance, or lead responsibility. Administrator authority MUST NOT extend into another team or unrelated solo or personal resources.

#### Scenario: Administrator opens an unjoined project
- **WHEN** an administrator opens a project within their team without having accepted an invitation to it
- **THEN** the administrator can see and participate in its shared tasks, chats, and documents.

#### Scenario: Administrator receives a pending invitation
- **WHEN** a recipient already has the administrator role for the project's team and has not accepted a project invitation
- **THEN** the pending invitation does not prevent participation through the account's existing administrator authority.

#### Scenario: Administrator targets another team
- **WHEN** an administrator supplies a project identifier belonging to a different team without separate access there
- **THEN** Kumiko denies project access rather than applying the first team's administrator role.

### Requirement: The project sidebar lists membership rather than administrator reach
Kumiko SHALL list only projects the current user belongs to in the project sidebar, including for administrators. Administrators SHALL still be able to reach every project within their team through access administration; administrator-wide participation MUST NOT automatically populate the sidebar with unjoined projects.

#### Scenario: Member sees joined projects
- **WHEN** a user opens the project sidebar
- **THEN** it lists their member projects rather than all projects discoverable through other authority.

#### Scenario: Administrator has unjoined team projects
- **WHEN** an administrator belongs to some projects but has authority to participate in additional team projects
- **THEN** the sidebar contains only member projects, while access administration provides access to the other team projects.

### Requirement: A separate project browser and join requests are deferred
Kumiko MUST exclude a separate project-browser and request-to-join workflow from the first functional release. First-release project entry SHALL use creator membership, accepted invitations, or administrator access administration as applicable; deferred discovery MUST NOT replace invitation acceptance.

#### Scenario: First-release user enters a project
- **WHEN** a normal user creates a project or accepts a project invitation in the first functional release
- **THEN** the project becomes available through membership without requiring a separate project browser.

#### Scenario: Nonmember seeks a join-request workflow
- **WHEN** a normal nonmember looks for a project-browser or request-to-join workflow in the first functional release
- **THEN** no such workflow is offered, and project access still requires the applicable membership path.

### Requirement: Administrators explicitly reassign a project's single lead
A project SHALL have at most one designated lead. Only an administrator within its team SHALL explicitly reassign the lead to a current member of that project in the same team. A pending invitation or administrator-wide visibility without membership MUST NOT qualify the target or bypass invitation acceptance. Lead responsibility alone MUST NOT authorize reassignment; creator status MUST NOT confer permanent lead ownership or require a handover workflow.

#### Scenario: Administrator reassigns to a current member
- **WHEN** an administrator explicitly selects a current member of a project within their team as its replacement lead
- **THEN** the selected member becomes the project's sole designated lead without changing their account role.

#### Scenario: Proposed target has not joined
- **WHEN** an administrator attempts to designate a nonmember, including a recipient with a pending invitation or an administrator with only team-wide visibility
- **THEN** Kumiko denies the reassignment, leaves the existing lead and memberships unchanged, and does not accept an invitation on the target's behalf.

#### Scenario: Proposed target belongs to another team
- **WHEN** an administrator attempts to designate a person who is not a current member of that project in the administrator's own team
- **THEN** Kumiko denies the reassignment without changing the project's designation or memberships.

#### Scenario: Normal-user lead attempts reassignment
- **WHEN** a normal-user project lead attempts to appoint another lead, including the project's creator acting only through lead responsibility
- **THEN** Kumiko denies reassignment and preserves the current designation.

### Requirement: Lead reassignment preserves membership and work ownership
Reassigning a lead SHALL leave the former lead a project member unless membership is separately revoked, while removing their lead-specific invitation and archival authority. Reassignment MUST NOT automatically move tasks, change assignees, transfer private agents or conversations, or change checkouts or local work. The former lead's separate administrator authority, if any, SHALL remain independent of the designation.

#### Scenario: Former normal-user lead remains a member
- **WHEN** an administrator reassigns a project from a normal-user lead to another current member without revoking the former lead's membership
- **THEN** the former lead retains ordinary member participation but cannot issue invitations or archive the project through the former lead responsibility.

#### Scenario: Reassignment occurs with existing work
- **WHEN** a project's lead changes while tasks have assignees and either person has private agents, conversations, checkouts, or local changes
- **THEN** tasks, assignees, and owner-local work remain unchanged rather than transferring to the new lead.

#### Scenario: Former lead is also an administrator
- **WHEN** a lead who retains the team's administrator role is replaced
- **THEN** the former lead loses lead-specific authority but retains the independent project access, invitation, archival, and permanent-deletion authority provided by that administrator role.

### Requirement: Removing lead membership leaves a visible vacancy
Removing the designated lead's project membership MUST clear the designation without requiring a replacement first or blocking urgent revocation. Kumiko SHALL show that the lead position is vacant while keeping the project usable under current access rules. An administrator within the team SHALL be able to fill the vacancy by explicitly selecting a current project member; no member SHALL automatically inherit the responsibility.

#### Scenario: Administrator removes the current lead's membership
- **WHEN** an administrator revokes the designated lead's project membership without selecting a replacement
- **THEN** membership removal takes effect, the project has a visible lead vacancy, and authorized participants can continue using it without an automatic successor.

#### Scenario: Administrator fills an existing vacancy
- **WHEN** an administrator explicitly designates a current project member within their team for a project with a lead vacancy
- **THEN** that member becomes the sole lead without requiring the former lead's approval or a handover.

#### Scenario: Removed lead retains administrator authority
- **WHEN** the designated lead's membership is removed but their team administrator role remains
- **THEN** the lead designation is cleared despite their continuing administrator-wide project access.

### Requirement: Project leads can invite within their project
Kumiko SHALL allow a project lead to invite normal users to the project they lead. Lead responsibility alone MUST NOT authorize invitations to other projects, revocation of member access, or account-role changes.

#### Scenario: Lead invites to own project
- **WHEN** a project lead invites a normal user to the project they lead
- **THEN** Kumiko creates a pending project invitation whose acceptance is still required.

#### Scenario: Lead exceeds invitation authority
- **WHEN** a normal-user project lead attempts to invite to a different project, revoke another member's access, or promote an account
- **THEN** Kumiko denies the operation based on lead responsibility alone.

### Requirement: Administrators have simple project access administration
Kumiko SHALL include a simple membership and invitation administration UI in the first finished release. Administrators SHALL be able to see members and pending invitations, issue invitations, revoke pending invitations, and revoke normal-member project access within their team without being project leads.

#### Scenario: Administrator inspects project access
- **WHEN** an administrator opens access administration for a project within their team that they do not lead
- **THEN** the UI shows members and pending invitations and allows issuing an invitation.

#### Scenario: Administrator revokes normal-member access
- **WHEN** an administrator revokes a normal member's project access within their team
- **THEN** that account no longer has membership-based access to the project.

#### Scenario: Normal member attempts administration
- **WHEN** a normal member without lead responsibility attempts to use project access administration
- **THEN** Kumiko denies membership administration and invitation issuance rather than granting administrator authority.

### Requirement: Administrator membership removal does not remove the account role
Kumiko MUST distinguish removing an administrator's project membership from removing their team-wide administrator role. Project membership removal SHALL remove membership-based sidebar inclusion but MUST NOT revoke the account's existing team-wide administrator access. Project membership administration MUST NOT imply an administrator-role change.

#### Scenario: Administrator project membership is removed
- **WHEN** an administrator's membership in a project within their team is removed while their administrator role remains
- **THEN** the project leaves their membership sidebar, but they can still access and participate through team-wide administrator authority.

#### Scenario: Membership removal is treated as an access revocation
- **WHEN** an administrator without membership accesses the same team's project through access administration
- **THEN** membership removal alone does not produce a Project access removed state or deny access based on the still-current administrator role.

### Requirement: Administrator demotion preserves current project memberships
Removing an administrator role SHALL preserve existing project memberships and any lead designation whose membership remains current. The resulting normal user SHALL retain participation only in projects where they are currently a member; previously unjoined projects MUST NOT gain membership or remain accessible through former administrator authority. Administrator-role change and project-membership removal SHALL remain distinct operations.

#### Scenario: Demoted administrator belongs to a project
- **WHEN** an administrator becomes a normal user while remaining a current project member
- **THEN** ordinary project participation and membership sidebar inclusion remain, and an existing lead designation remains valid.

#### Scenario: Demoted administrator had only team-wide access
- **WHEN** an administrator becomes a normal user without membership in a previously accessible team project
- **THEN** the account loses access to that project's shared records without automatically joining it.

#### Scenario: Membership is separately removed after demotion
- **WHEN** a former administrator's current project membership is separately revoked
- **THEN** membership-based project access ends under the ordinary revocation rules rather than having been removed implicitly by demotion.

### Requirement: Administrator demotion updates existing access paths without disturbing private work
Administrator demotion MUST immediately remove administrator authority from further operations through sessions, subscriptions, live updates, APIs, and authenticated tools. Once known, shared views, search, and attention SHALL reflect remaining access; inaccessible project views SHALL show "Project access removed". Private agents, terminals, files, checkouts, conversations, and unsent local drafts MUST remain intact without automatic sending.

#### Scenario: Existing session retains joined-project access only
- **WHEN** a demoted administrator's existing session or authenticated tool next reads or writes a project where the account remains a member
- **THEN** Kumiko uses current member and any retained lead authority, denies administrator-only operations, and does not rely on the session's former administrator role.

#### Scenario: Unjoined subscription and tool lose access
- **WHEN** an administrator is demoted while subscribed to an unjoined project's updates and an existing authenticated tool requests further records from it
- **THEN** the stream stops disclosing further project updates and the tool request is denied despite their earlier authorization.

#### Scenario: Shared views learn of demotion while local work continues
- **WHEN** Kumiko learns of demotion while an unjoined project is open and private agents or terminals are running with files, conversations, or unsent drafts
- **THEN** inaccessible shared views show "Project access removed", shared search and attention no longer expose that project, and private processes and owner-local work remain intact with drafts unsent.

### Requirement: Project authorization is enforced across read and action paths
Kumiko MUST enforce the initiating owner's current project access and operation-specific authority in backend APIs and authenticated agent tools, including MCP, rather than relying on hidden UI. Project lists, search, tasks, chats, documents, and attention results MUST NOT disclose unauthorized records. Supplied identifiers, agent instructions, prompts, or confirmation MUST NOT confer missing authority.

#### Scenario: Authorized member reads project records
- **WHEN** an accepted project member requests its shared records through a backend API or authenticated agent tool
- **THEN** the request can return records within that account's current project access.

#### Scenario: Cross-project discovery excludes inaccessible records
- **WHEN** a normal user requests project lists, search, tasks, chats, documents, or attention results spanning accessible and inaccessible projects
- **THEN** results exclude records from projects that the user cannot access.

#### Scenario: Direct API request supplies unauthorized identifier
- **WHEN** an authenticated normal user requests a project record by identifier through a backend API without project access
- **THEN** the API denies the read without returning the unauthorized record.

#### Scenario: Direct MCP request supplies unauthorized identifier
- **WHEN** an authenticated agent tool request supplies a project identifier that its owner cannot access
- **THEN** the tool denies the read or action without disclosing the project's records.

#### Scenario: Authorized lead archives through an authenticated tool
- **WHEN** an authenticated agent tool requests archival for its initiating owner who is the project's current lead with current access and an available team server
- **THEN** Kumiko permits the request under the same archival authority as the ordinary project action.

#### Scenario: Prompt and confirmation attempt to bypass deletion authority
- **WHEN** a normal-user creator or project lead submits a confirmed permanent-deletion request through a backend API or authenticated agent tool, including instructions claiming administrator authority
- **THEN** Kumiko denies deletion because prompts and confirmation do not grant the initiating owner the missing administrator authority.

### Requirement: Subsequent requests use current project access
Kumiko MUST enforce current project access on further shared reads and writes through backend APIs and authenticated agent tools, and on existing subscriptions and live updates. Prior acceptance, an existing session, subscription, or earlier success MUST NOT preserve access after normal membership is revoked. Revocation MUST NOT be presented as undoing committed operations or retracting content already read or sent to a model.

#### Scenario: Membership remains current
- **WHEN** a normal member with current accepted membership makes a subsequent project request
- **THEN** Kumiko evaluates the request using that current membership.

#### Scenario: Access is revoked during an existing session
- **WHEN** a normal member's project access is revoked and the existing session or authenticated agent makes a subsequent project request
- **THEN** Kumiko denies project access despite the session's earlier authorized requests.

#### Scenario: Initial creator membership is revoked
- **WHEN** an administrator revokes a normal-user creator's project membership and that user requests the project again
- **THEN** having originally created the project does not bypass the revoked membership or grant renewed access.

#### Scenario: Existing subscription loses authorization
- **WHEN** a normal member's project access is revoked while an existing subscription or live-update stream is open
- **THEN** the subscription or stream no longer discloses further restricted project updates despite having been opened while authorized.

#### Scenario: Revoked member attempts a shared write
- **WHEN** a normal member's access is revoked and their existing session or authenticated agent tool attempts another shared project write
- **THEN** Kumiko denies the write rather than relying on the session's earlier authorization.

#### Scenario: Completed operation predates revocation
- **WHEN** a shared operation committed or content was read or sent to a model before access was revoked
- **THEN** Kumiko does not claim revocation undoes the committed operation or retracts that previously consumed content.

### Requirement: Known access removal clears restricted shared views
Once normal-membership revocation is known, Kumiko MUST remove restricted active shared content and replace affected views with "Project access removed". It MUST remove the project from membership navigation and remove its shared search and attention entries. Stale tabs, results, and navigation MUST NOT remain routes to restricted shared content.

#### Scenario: Active project views lose access
- **WHEN** Kumiko learns that a normal user's membership was revoked while the project has active shared task, chat, or document views
- **THEN** restricted content is removed from those views and replaced with "Project access removed", and the project disappears from membership navigation and shared search and attention entries.

#### Scenario: User follows a stale shared entry
- **WHEN** a former member follows a previously opened tab, search result, or attention entry after revocation is known
- **THEN** restricted shared content is not shown and the affected view reports "Project access removed" rather than restoring access.

### Requirement: Access removal preserves owner-local work without resending drafts
Project-access revocation MUST NOT stop local agents or terminals, delete checkouts, files, or private histories, or revert local work. Unsent drafts SHALL remain owner-local but MUST NOT be sent to an inaccessible project. Restored access MUST NOT automatically resend them or restore membership through an old invitation or session.

#### Scenario: Revocation occurs during local running work
- **WHEN** a normal member loses project access while a local agent or terminal is running against their checkout
- **THEN** local processes continue and local files, checkout changes, and private history remain intact, while further shared project operations require current authorization.

#### Scenario: Revoked user retains an unsent draft
- **WHEN** a normal member has an owner-local unsent draft for a project whose access is revoked
- **THEN** the draft is preserved locally but sending it to that inaccessible project is denied.

#### Scenario: Access is restored with a retained draft
- **WHEN** fresh authorization restores project access while an unsent owner-local draft remains
- **THEN** the draft remains unsent until the owner explicitly sends it under current access, rather than being automatically resent.

### Requirement: Shared repositories do not merge project access
Kumiko MUST keep project access scopes independent when projects refer to the same repository. Membership or lead responsibility in one project MUST NOT grant access to another project's shared records through their common repository.

#### Scenario: Member works in one repository-linked project
- **WHEN** an accepted member opens shared records for their project linked to a repository
- **THEN** Kumiko grants access according to that project's membership.

#### Scenario: Another project shares the repository
- **WHEN** the same repository is linked to another project that the normal user has not joined
- **THEN** the shared repository does not reveal that project's records or grant participation.

### Requirement: Project access does not grant personal execution authority
Kumiko MUST keep project membership and administrator authority separate from personal workspaces, checkouts, terminals, credentials, private agent histories, and agent control. These personal resources MUST NOT be stored or exposed through the team server. Host operations SHALL require separate explicit host grants rather than project authority, without turning personal data into shared project records.

#### Scenario: Separately granted host operation
- **WHEN** a project participant has a separate applicable host grant and requests an operation within that grant
- **THEN** host access is evaluated against the separate grant rather than derived from project membership.

#### Scenario: Administrator attempts personal execution access
- **WHEN** a team administrator attempts to access another person's workspace, checkout, terminal, credentials, private agent history, or agent control without separate authority
- **THEN** administrator status does not authorize that access or operation.

#### Scenario: Administrator searches personal work through the team server
- **WHEN** an administrator searches for a member's private coding conversation, terminal output, local files, edits, or branches through the team service
- **THEN** those personal resources are unavailable there rather than merely hidden by project permissions.

#### Scenario: Member attempts personal execution access
- **WHEN** an accepted normal project member attempts to control another person's agent or terminal without the required host grant
- **THEN** project membership does not authorize the operation.

### Requirement: Solo projects have no team invitation gate
Kumiko SHALL allow solo project use without a team account, team membership, or project invitation. This exemption MUST NOT grant access to team projects or another person's execution environment.

#### Scenario: Solo owner works without account
- **WHEN** a solo user opens their local solo project without a team account or invitation
- **THEN** the project remains usable without a team membership or invitation gate.

#### Scenario: Solo user requests team project access
- **WHEN** a solo user attempts to access a team project without the required team project access
- **THEN** the solo exemption does not authorize access to that team project's records.
