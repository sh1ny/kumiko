# Spec Delta

## Purpose

Prevent client product-telemetry and report gathering, bound operational diagnostics to minimal non-content logs and inspected local-only export, and provide telemetry-free builds whose collection and upload capability is absent rather than merely disabled.

## ADDED Requirements

### Requirement: Operational diagnostics contain only minimal fields
Kumiko diagnostic logs SHALL contain only minimal operational fields: timestamps, component/version, operation type, duration, and structured error codes. Diagnostics MUST NOT track user activity or serve as product-usage analytics.

#### Scenario: Record an operational failure
- **WHEN** Kumiko records an operation's failure for diagnosis
- **THEN** its log entry contains only the permitted minimal operational fields, without user-activity tracking.

#### Scenario: Product usage could be inferred through activity logging
- **WHEN** a diagnostic entry would record navigation, editing, or conversation activity to track product usage
- **THEN** Kumiko does not record that activity as diagnostics.

### Requirement: Diagnostic logs exclude content and secrets
Kumiko diagnostic logs MUST NOT include prompts, replies, drafts, document or file contents, diffs, terminal output, tool arguments or results, credentials, tokens, authentication headers, connection strings, or secret-bearing URLs. Server logs MUST also omit shared message and document bodies.

#### Scenario: Diagnose a shared operation without its content
- **WHEN** a server operation handles a shared message or document and emits a diagnostic entry
- **THEN** the entry omits the message or document body and contains only permitted operational fields.

#### Scenario: Failed operation carries private content or secrets
- **WHEN** a failed operation includes a prompt, file, diff, terminal output, tool payload, credential, authentication header, connection string, or secret-bearing URL
- **THEN** that content or secret is not written to diagnostic logs.

### Requirement: Third-party failures are not presumed safe to log
Kumiko SHALL treat raw third-party failure messages and payloads as potentially sensitive and MUST NOT log them verbatim by default. Diagnostic entries for those failures SHALL remain limited to the permitted operational fields and MUST NOT substitute raw failure text when a safe structured error code is unavailable.

#### Scenario: Third-party failure has a safe structured code
- **WHEN** a third-party operation fails with a safe structured error code
- **THEN** diagnostics may record that code with permitted operational fields, without the raw failure message or payload.

#### Scenario: Third-party error embeds sensitive data
- **WHEN** a third-party failure contains content or secrets, or offers only raw failure text without a safe structured code
- **THEN** Kumiko does not log that raw text or payload as a fallback.

### Requirement: Desktop and server diagnostics respect ownership boundaries
Desktop diagnostic logs SHALL remain on the user's PC and MUST NOT be uploaded or exposed through the team server, including to administrators. Server logs SHALL describe server operations only, not private desktop activity; team membership or administrator authority MUST NOT grant access to desktop logs.

#### Scenario: Team server diagnoses its own operation
- **WHEN** a team server records an operational diagnostic
- **THEN** the entry concerns the server operation without collecting private desktop activity or desktop logs.

#### Scenario: Team administrator seeks desktop diagnostics
- **WHEN** a team administrator uses team-server access to inspect diagnostics
- **THEN** that access does not expose a user's desktop logs, even when the user participates in a team project.

### Requirement: Diagnostic export is inspected and local only
Kumiko SHALL allow deliberate diagnostic export only after the user inspects the selected diagnostic content, producing a local offline bundle. Export MUST preserve diagnostic content and ownership restrictions and MUST NOT automatically attach, send, or upload the bundle, introduce developer-report collection or upload components, or create a developer-reporting flow.

#### Scenario: User inspects and exports local diagnostics
- **WHEN** a user inspects selected permitted desktop diagnostic content and explicitly exports it
- **THEN** Kumiko produces an offline bundle on that user's PC without attaching, sending, or uploading it.

#### Scenario: Failure or export does not authorize reporting
- **WHEN** a failure occurs without an inspected export request, or a user completes a local diagnostic export
- **THEN** no automatic export follows the failure and no automatic attachment, sending, upload, or developer-reporting flow follows either event.

### Requirement: Client product telemetry and reports are not gathered
Kumiko MUST NOT gather client product telemetry or crash/error reports for its developers or third-party product-analytics/reporting services. Routine client operation and failures MUST NOT trigger that collection or upload. Local user-facing token/cost statistics SHALL remain distinct from external product telemetry.

#### Scenario: Client operates without product telemetry collection
- **WHEN** a user operates the Kumiko client
- **THEN** Kumiko does not gather product-usage telemetry or reports for developer-operated or third-party analytics/reporting services.

#### Scenario: Client encounters a failure
- **WHEN** the client encounters a crash or application error
- **THEN** the failure does not trigger product-report collection, an outgoing report queue, or automatic report upload.

### Requirement: Telemetry-free builds exclude the capability
Kumiko SHALL offer telemetry-free builds that exclude product analytics and crash/error-report collection and upload components from the shipped artifact. The capability MUST remain unavailable with no runtime option to enable it; a disabled-by-default collector or hidden activation path MUST NOT satisfy this build contract.

#### Scenario: Telemetry-free build is delivered
- **WHEN** a telemetry-free build is packaged for a customer
- **THEN** its shipped artifact omits product-telemetry/report collection and upload components and exposes no control for enabling them.

#### Scenario: Deployment attempts to enable excluded collection
- **WHEN** runtime settings, environment configuration, or remote configuration attempt to enable telemetry or reporting in a telemetry-free build
- **THEN** collection and upload remain unavailable because the build does not include that capability.

#### Scenario: Collection is disabled but still shipped
- **WHEN** a candidate build retains collection or upload components but only disables their initialization or hides their settings
- **THEN** that candidate does not qualify as the required telemetry-free build.
