# Spec Delta

## Purpose

Help users find actionable work across projects and navigate to its source context without confusing ordinary activity with requests for intervention.

## ADDED Requirements

### Requirement: Actionable attention is collected across projects
Kumiko SHALL provide one cross-project Needs attention view for agent questions, operation approval requests, actual failures or blockers, and explicit review requests within the user's existing access.

#### Scenario: Actionable items originate in different projects
- **WHEN** accessible projects contain an agent question, an approval request, a failure or blocker, and an explicit review request
- **THEN** the user can find those actionable items in the same cross-project Needs attention view.

#### Scenario: A project is outside the user's access
- **WHEN** an actionable item belongs to a project the user cannot access
- **THEN** the attention view does not expose that project's restricted item content.

### Requirement: Attention items navigate without granting authority
Kumiko SHALL let an attention item open its exact source conversation, approval, failure details, or reviewed changes with the associated project or Personal context, workspace, and owner clear. Opening SHALL mark the user's notification seen, but MUST NOT answer, approve, deny, complete review, otherwise handle the source, or grant control of another person's agent.

#### Scenario: Open a review request in context
- **WHEN** a user opens an accessible explicit review request from Needs attention
- **THEN** Kumiko navigates to the requested reviewed changes with their associated project, workspace, and owner identified.

#### Scenario: Open a shared operation approval request
- **WHEN** a user can view a project-shared operation approval request but lacks authority to approve it or control an agent
- **THEN** opening the item neither approves the operation nor grants that missing authority.

### Requirement: Private session attention remains owner-local
Kumiko MUST keep private local session attention content, state, and notification history owner-local. The team server MUST NOT receive or expose private questions, approvals, failures, review prompts, output, or their notification history through project activity, notifications, or administrator access. Shared project attention SHALL remain distinct.

#### Scenario: Owner opens private attention
- **WHEN** the owner's private local agent asks a question while associated with a team project
- **THEN** the owner can open it locally without uploading that question or conversation to the team server.

#### Scenario: Administrator requests another owner's private prompt
- **WHEN** a project administrator or member queries team attention for another person's private agent approval or failure details
- **THEN** no private prompt, output, or conversation content is returned or uploaded.

### Requirement: Attention supports in-app and minimal desktop notifications without email
Kumiko SHALL provide in-app Needs attention and focus-gated minimal desktop notifications without email notifications. Attention and project activity MUST NOT generate email notifications or require an email delivery workflow. This exclusion MUST NOT suppress actionable in-app attention, forbid the specified desktop alerts, or change owner-local treatment of private session prompts.

#### Scenario: An actionable request is available in-app
- **WHEN** an accessible agent question or explicit review request occurs
- **THEN** it is available through the applicable in-app Needs attention view without sending an email notification.

#### Scenario: Private attention occurs with planning disabled
- **WHEN** a private local session requires approval while its associated project's Tasks or optional planning features are disabled
- **THEN** its owner can still find the approval locally in Needs attention without an email notification or disclosure to the team server.

### Requirement: Notification state is separate from source state
Kumiko SHALL distinguish the user's seen/unseen and dismissed notification state from the source's pending/handled state. A dismissed notification MAY have a pending source. Reading or dismissing a notification MUST NOT handle its source or implicitly change another person's notification, request, or attention.

#### Scenario: Open a pending question
- **WHEN** a user opens an unseen notification for an unanswered question
- **THEN** that user's notification becomes seen, while the question remains pending and no answer is sent.

#### Scenario: Another user has the same shared request
- **WHEN** one user reads or dismisses their notification for a shared request
- **THEN** other users' notification states remain unchanged and the source request remains pending unless actually handled.

### Requirement: Handling follows the actual source outcome
Kumiko SHALL mark a question handled only on answer or withdrawal, an approval request only on explicit approve/deny or actual source cancellation/expiry, and a review request only on explicit completion, decline, or withdrawal. Actual source handling SHALL update the source status on existing displayed notifications rather than create a replacement alert.

#### Scenario: An approval request is actually decided
- **WHEN** an authorized user explicitly denies a pending approval request at its source
- **THEN** its existing displayed notification shows the handled source status without a replacement alert.

#### Scenario: Merely inspect requested changes
- **WHEN** a user opens an explicit review request and inspects the changes without completing, declining, or withdrawing the review
- **THEN** the source remains pending rather than being marked reviewed or handled.

#### Scenario: A question is withdrawn or an approval expires
- **WHEN** a question is withdrawn or a source approval request actually expires
- **THEN** its existing displayed source status becomes handled without implying an answer or approval was sent.

### Requirement: Failure acknowledgment does not report recovery
Kumiko SHALL allow acknowledgment of a failure alert to clear that alert's active attention. Acknowledgment MUST NOT report the failed operation fixed or successful, change its recorded failure, or imply that the underlying blocker is resolved.

#### Scenario: Acknowledge a reported failure
- **WHEN** a user acknowledges a failure alert
- **THEN** its active attention clears while the source still identifies the failed operation and its actual outcome.

#### Scenario: The failed operation has not recovered
- **WHEN** the user returns to an acknowledged alert whose operation has not recovered
- **THEN** its source still shows the failure rather than a fabricated fix or success.

### Requirement: Dismissal clears only the user's notification
Kumiko SHALL label the action "Dismiss notification" and explain that a pending source is still waiting and no answer, approval, or review response is sent. Dismissal SHALL remove only that user's notification from active Needs attention, retaining it in Notifications and leaving the pending request accessible in its conversation or session.

#### Scenario: Dismiss a pending approval notification
- **WHEN** a user chooses Dismiss notification for a pending approval
- **THEN** it is dismissed but pending in Notifications, absent from that user's active Needs attention, and still awaiting an explicit decision in its source session; no approval or denial is sent.

#### Scenario: Return to a dismissed question
- **WHEN** a user returns to the conversation containing a dismissed unanswered question
- **THEN** the question remains accessible and awaiting an answer rather than being withdrawn or handled by dismissal.

### Requirement: An unchanged request does not generate repeat notifications
Kumiko SHALL notify at most once for the same unchanged source request. Dismissal, refresh, reconnect, refocus, and continued pending state MUST NOT generate repeat notifications or reminders. A genuinely distinct new request MAY notify once. Actual source handling SHALL update existing notification status without a replacement alert.

#### Scenario: A dismissed request remains pending after reconnect
- **WHEN** a user dismisses a pending request and later refreshes, reconnects, or refocuses Kumiko while that request is unchanged
- **THEN** it remains dismissed and pending without reappearing in active Needs attention or producing another in-app or desktop alert.

#### Scenario: The same session issues a distinct request
- **WHEN** a session issues a genuinely distinct new approval request after an earlier request was dismissed
- **THEN** the new request can notify once without reviving the earlier notification or repeating either request's alert.

### Requirement: Desktop alerts are minimal and focus-gated
Kumiko SHALL issue desktop attention alerts only while unfocused or minimized, using only the app name and a generic message such as "Kumiko: An agent needs your attention." Alerts MUST NOT contain prompts, commands, task titles, project names, paths, or conversation previews, steal focus, or require a notifier surviving app quit. Clicking SHALL open only the source, subject to current access, without responding or authorizing.

#### Scenario: A private agent requests approval while minimized
- **WHEN** a private agent issues a new approval request while Kumiko is minimized
- **THEN** the desktop alert exposes only the app name and generic attention message, without private context or focus theft, and clicking opens its source without approving or denying.

#### Scenario: Attention occurs while the app is focused
- **WHEN** an actionable request occurs while Kumiko is focused
- **THEN** in-app attention and applicable agent states identify it without a desktop alert, and later refocusing or minimizing does not replay that request's alert.

### Requirement: Notification history does not bypass shared access
Kumiko SHALL enforce current permissions and required server connectivity when displaying or opening shared attention records, including dismissed or handled history. A retained notification MUST NOT disclose restricted source content or permit stale-access reads; source unavailability SHALL be explained without granting access.

#### Scenario: Open authorized shared notification history
- **WHEN** an authorized user opens a handled shared notification with required server connectivity available
- **THEN** Kumiko opens its source subject to the same current permissions as direct navigation.

#### Scenario: Access or server connectivity is unavailable
- **WHEN** a user inspects or opens retained shared notification history after access is revoked or required server connectivity is lost
- **THEN** Kumiko explains the unavailable source without exposing restricted content or using notification history as a stale-access bypass.

### Requirement: Routine activity does not imply actionable attention
Kumiko SHALL keep routine agent activity separate from the actionable attention view. A routine tool call or ordinary turn completion alone MUST NOT create an attention item or imply that work is ready for review.

#### Scenario: Agent explicitly requests review
- **WHEN** an agent explicitly requests review of its work
- **THEN** the review request can appear as an actionable attention item linked to that work.

#### Scenario: Ordinary agent work completes without a request
- **WHEN** an agent performs a routine tool call or finishes an ordinary turn without a question, approval request, failure, blocker, or explicit review request
- **THEN** that activity alone creates no Needs attention item and is not labeled ready for review.
