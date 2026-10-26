# Spec Delta

## Purpose

Connect native work to external GitHub and Jira items while preserving independent lifecycles and explicitly authorized publication destinations.

## ADDED Requirements

### Requirement: Linked work retains independent ownership
Kumiko SHALL associate native tasks with GitHub issues and Jira stories or bugs while native tasks own the internal work record and external items retain their own lifecycle. It MUST NOT automatically replicate status, assignee, description, or priority between systems or close one item because another closes.

#### Scenario: Associate external work
- **WHEN** a user links an external item to a native task
- **THEN** the task exposes the association without transferring ownership of either system's work record.

#### Scenario: One linked item closes
- **WHEN** a native task or linked external item is closed or changes its fields
- **THEN** the other item's lifecycle and fields are not automatically changed.

### Requirement: Linked activity is fetched without comment mirroring
Kumiko SHALL display fetched current details, comments, and updates from authorized linked external items. Internal notes MUST remain internal by default, and fetched activity MUST NOT trigger automatic comment mirroring.

#### Scenario: Read linked activity
- **WHEN** a user fetches a linked item through an authorized connection
- **THEN** Kumiko displays the fetched details and activity as external source content.

#### Scenario: External content requests republication
- **WHEN** an external comment requests that restricted content be reposted or commands an agent to act
- **THEN** reading that comment does not authorize republication or execution, and internal notes are not mirrored.

### Requirement: Integration targets and identities are explicit
Kumiko SHALL support GitHub.com, GitHub Enterprise Server, Jira Cloud, and self-hosted Jira targets using the configured instance URL and account or installation identity. Authorization for one connection MUST NOT imply authorization for another instance or identity.

#### Scenario: Read from an enterprise target
- **WHEN** a user opens a linked item on a configured enterprise GitHub or self-hosted Jira connection
- **THEN** Kumiko uses that connection's instance and authorized account or installation identity.

#### Scenario: Same item identifier on another instance
- **WHEN** another configured instance has an item with the same local identifier
- **THEN** Kumiko does not substitute that instance's item or credentials for the linked target.

### Requirement: Publication requires explicit owner authority
Kumiko MUST require explicit owner-authorized agent publication to selected, authorized linked destinations, expose the posting identity, and report each destination's outcome. A request to reply everywhere SHALL resolve actual configured authorized destinations rather than every loosely related link. Old publication actions MUST NOT be automatically replayed.

#### Scenario: Publish to selected destinations
- **WHEN** an owner authorizes an agent to publish to specified linked destinations
- **THEN** publication uses the identified posting identity and reports the outcome for each selected destination.

#### Scenario: Partial publication fails
- **WHEN** publication succeeds at one selected destination but fails at another
- **THEN** Kumiko distinguishes those outcomes without claiming universal success or automatically replaying the old action.

### Requirement: Publication preserves destination and thread types
Kumiko MUST distinguish issue comments, general pull-request comments, and line-anchored review threads when publishing or replying. It MUST NOT flatten these destinations into a generic comment channel.

#### Scenario: Reply to a review thread
- **WHEN** an owner authorizes a reply to a specific line-anchored review thread
- **THEN** the reply targets that thread rather than a general pull-request or issue comment.

#### Scenario: Requested thread is unavailable
- **WHEN** a selected review-thread destination cannot be addressed
- **THEN** Kumiko reports that destination's failure instead of silently posting the reply as a general comment.
