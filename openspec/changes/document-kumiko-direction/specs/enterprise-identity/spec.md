# Spec Delta

## Purpose

Support deployment-configurable sign-in while separating account identity from membership, external API access, and host execution authority.

## ADDED Requirements

### Requirement: Sign-in follows deployment identity configuration
Kumiko SHALL support deployment-configurable standards-based identity for company SSO, including in-house identity providers, and public sign-in providers where supported. A configured provider MUST NOT be presented as compatible until its integration is qualified.

#### Scenario: Company identity provider is supported
- **WHEN** a deployment configures a supported company identity provider
- **THEN** users can authenticate to that Kumiko deployment through company SSO.

#### Scenario: Provider compatibility is unknown
- **WHEN** a deployment's internal identity-provider integration has not been qualified
- **THEN** Kumiko compatibility remains unverified rather than inferred from that provider working with another application.

### Requirement: Desktop sign-in uses the system browser
Kumiko SHALL use the system browser for desktop sign-in so the configured identity provider can apply company MFA and access policies.

#### Scenario: Company MFA challenge
- **WHEN** the configured provider requires MFA during desktop sign-in
- **THEN** the sign-in flow allows the provider to perform that challenge in the system browser.

#### Scenario: Provider denies sign-in
- **WHEN** company policy denies authentication or the user cancels sign-in
- **THEN** Kumiko does not establish an authenticated application session from that attempt.

### Requirement: Internal accounts own application authorization
Kumiko SHALL own account roles and project memberships on internal Kumiko accounts. Local/internal sign-in and external or SSO identities SHALL create or attach to those accounts through established identity linkage, not create parallel provider-specific permission systems.

#### Scenario: Local or internal sign-in creates an account
- **WHEN** a deployment permits local or internal registration and a user creates an account through it
- **THEN** the resulting internal Kumiko account owns that user's application roles and project memberships.

#### Scenario: Established external identity signs in
- **WHEN** a user signs in through an external or SSO identity already linked to an internal Kumiko account
- **THEN** application access is evaluated from that internal account's roles and project memberships.

#### Scenario: Provider authentication has no established account linkage
- **WHEN** an external or SSO identity authenticates without established linkage to an existing internal account
- **THEN** any newly created internal account has its own roles and memberships rather than inheriting another account's access or a parallel provider permission system.

### Requirement: The deployment operator designates the first administrator
For a new self-hosted deployment, the deployment operator SHALL explicitly designate the first administrator during server setup. Administrator authority SHALL belong to the designated internal Kumiko account, not arise from being the first person to sign in or winning concurrent initial sign-ins.

#### Scenario: Operator designates the initial administrator
- **WHEN** the deployment operator explicitly designates an internal Kumiko account as the first administrator during server setup
- **THEN** that account receives the administrator role independently of sign-in order.

#### Scenario: Ordinary users sign in before the designated administrator
- **WHEN** ordinary users sign in before the designated administrator or race to perform the earliest sign-in
- **THEN** none receives administrator authority merely from sign-in timing or order.

### Requirement: Later account-role changes require current same-team administrator authority
After initial server setup, only a current administrator SHALL explicitly promote or demote internal Kumiko accounts within their own team, between normal user and administrator. Project lead status SHALL confer no account-role authority. Sign-in, registration, requests, and self-appointment MUST NOT grant administrator authority. Removing project membership MUST NOT demote an administrator.

#### Scenario: Existing administrator appoints another
- **WHEN** a current administrator explicitly confirms promotion of another internal Kumiko account in their own team
- **THEN** the selected account receives the administrator role.

#### Scenario: Administrator demotes another administrator
- **WHEN** a current administrator explicitly confirms another administrator's demotion in their own team and an administrator remains
- **THEN** the selected account becomes a normal user.

#### Scenario: Unauthorized administrator appointment
- **WHEN** a normal user attempts to appoint themselves or another account as an administrator
- **THEN** Kumiko denies the appointment and leaves the target account's role unchanged.

#### Scenario: Project lead attempts account-role administration
- **WHEN** a project lead who is a normal user attempts to promote or demote an account
- **THEN** Kumiko denies the role change despite that user's project-specific authority.

#### Scenario: Administrator attempts cross-team role change
- **WHEN** an administrator attempts to promote or demote an account in a team where they are not an administrator
- **THEN** Kumiko denies the role change and leaves the target account's role unchanged.

#### Scenario: Administrator loses project membership
- **WHEN** an administrator's membership in a project is removed
- **THEN** their team administrator role remains unchanged.

### Requirement: Account-role changes require explicit informed confirmation
Promotion and demotion SHALL require explicit confirmation identifying the target account, team, and resulting role. Opening or editing a role-change control, or declining its confirmation, MUST NOT change the account's role.

#### Scenario: Administrator confirms the identified role change
- **WHEN** an authorized administrator confirms a role change displaying the target account, team, and resulting role
- **THEN** Kumiko applies only that identified change if current authority and administrator-retention requirements still permit it.

#### Scenario: Administrator opens or edits without confirming
- **WHEN** an administrator opens a role-change control or edits its proposed values without explicit confirmation
- **THEN** the account's role remains unchanged.

#### Scenario: Administrator cancels confirmation
- **WHEN** an administrator declines the displayed role-change confirmation
- **THEN** the account's role remains unchanged.

### Requirement: The server preserves at least one team administrator
The server MUST reject any role change that would leave a team with zero administrators, including concurrent changes; a client-only guard is insufficient. An administrator MAY demote themselves when another administrator remains. The last administrator MUST appoint a replacement before demotion. The concrete enforcement mechanism remains unspecified.

#### Scenario: Self-demotion leaves another administrator
- **WHEN** an administrator explicitly confirms their own demotion and another administrator remains in the team
- **THEN** the server permits the change and the former administrator becomes a normal user.

#### Scenario: Last administrator attempts demotion
- **WHEN** a role change would demote the team's only administrator
- **THEN** the server rejects it, retains that administrator's role, and requires appointment of a replacement before demotion.

#### Scenario: Concurrent changes would remove all administrators
- **WHEN** concurrent confirmed role changes would collectively leave a team with zero administrators
- **THEN** the server rejects changes as necessary so at least one administrator remains, even if each client believed another administrator would remain.

### Requirement: Demotion immediately removes administrative session authority
After demotion, an existing session MUST immediately lose administrator authority for further administrative operations. The server MUST evaluate current authority rather than accept prior cached administrator status. Remaining non-administrative access SHALL follow the account's current role and project-access rules.

#### Scenario: Session retains current administrator authority
- **WHEN** a session's account remains an administrator and confirms a permitted same-team role change
- **THEN** the server allows that operation under current authorization rules.

#### Scenario: Demoted session attempts another promotion
- **WHEN** an existing session attempts to promote an account after its own account has been demoted
- **THEN** the server rejects the promotion despite any cached administrator status.

#### Scenario: Demoted session attempts another administrative operation
- **WHEN** a demoted account's existing session attempts any further administrator-only operation
- **THEN** the server denies administrative authority without requiring logout or a new sign-in first.

### Requirement: Administrator lockout recovery requires deployment control
Administrator lockout recovery SHALL be a separate deployment-operator procedure requiring actual control of the deployment. Ordinary login, matching email addresses, or a client-side request to become administrator MUST NOT establish recovery authority. The concrete recovery procedure remains unspecified.

#### Scenario: Deployment operator has actual control
- **WHEN** an operator with actual control of the deployment needs administrator lockout recovery
- **THEN** recovery belongs to the separate deployment-operator procedure, not ordinary account-role administration.

#### Scenario: Ordinary account claims recovery authority
- **WHEN** a user signs in, presents an email matching an administrator, or invokes a client-side make-me-administrator action without actual deployment control
- **THEN** Kumiko grants neither recovery authority nor administrator status from that claim.

### Requirement: Login does not grant unrelated authority
Kumiko MUST distinguish application sign-in and registration, team membership, external API grants, and host execution grants. Authenticating through a GitHub or Jira identity MUST NOT itself authorize API operations or access to another user's execution host.

#### Scenario: Authorized integration access
- **WHEN** an authenticated member separately grants access to an external integration
- **THEN** integration operations use that external grant within the member's Kumiko permissions.

#### Scenario: Login without external or host grant
- **WHEN** a user signs in but lacks an external API grant or a host execution grant
- **THEN** the corresponding integration operation or host execution is not authorized by login alone.

### Requirement: Cross-provider identities are not inferred from email
Kumiko MUST NOT treat matching email addresses as proof that identities from separate providers represent the same authorized account.

#### Scenario: Recognized account identity
- **WHEN** a user authenticates with an identity already established for the deployment
- **THEN** access is evaluated for that established identity and its membership.

#### Scenario: Matching email on another provider
- **WHEN** another provider returns the same email address for an identity not established as the same account
- **THEN** Kumiko does not automatically merge the identities or inherit the first account's permissions.
