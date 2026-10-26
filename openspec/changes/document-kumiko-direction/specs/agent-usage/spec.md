# Spec Delta

## Purpose

Provide observational agent token and cost statistics while preserving runtime-specific accounting, source coverage, and the distinction between estimates and provider billing.

## ADDED Requirements

### Requirement: Supported usage is visible with source coverage
Kumiko SHALL provide detailed token statistics from available runtime usage records, identifying the runtime, model, and supported session/time breakdowns. It SHALL distinguish input, output, cache reads/writes, and reasoning where reported. Missing fields or incomplete history MUST be identified as unavailable or partial rather than presented as measured zeroes or complete usage.

#### Scenario: Runtime provides token categories
- **WHEN** an accessible runtime record provides input, output, and cache token counts for an identified session and model
- **THEN** statistics expose those categories and their source/session/model associations for the supported reporting period.

#### Scenario: Runtime history or a field is unavailable
- **WHEN** a source lacks reasoning counts or only part of the selected period's history is available
- **THEN** statistics identify the missing field or partial coverage rather than displaying measured zero reasoning or claiming complete period totals.

### Requirement: Private session accounting remains local
Kumiko SHALL keep observational accounting from private coding sessions local to the user's PC. Private session-derived token/cost statistics, model/session history, and aggregates MUST NOT be uploaded, indexed, or exposed through the team server as a workaround to conversation privacy. Team administrator status and task association MUST NOT grant visibility into those records. This accounting MUST NOT introduce a team telemetry or reporting subsystem.

#### Scenario: Owner inspects private usage locally
- **WHEN** the user opens supported token/cost statistics for their private coding sessions
- **THEN** Kumiko presents the locally available accounting with its source coverage and cost provenance without uploading it to the team server.

#### Scenario: Team requests associated private usage
- **WHEN** a team administrator or shared task view requests statistics or aggregates derived from a member's private sessions
- **THEN** Kumiko does not upload or expose those private usage records, even if the sessions are associated with shared tasks.

### Requirement: Cost provenance is explicit
Kumiko SHALL distinguish native reported cost from rate-based API-equivalent estimates and unpriced usage. A reported cost or estimate MUST NOT be presented as a subscription invoice, subscription quota, or authoritative account spend. Missing prices MUST remain explicitly unpriced rather than imply free usage.

#### Scenario: Token counts have an applicable rate
- **WHEN** a usage record is priced from an applicable model rate rather than an authoritative billing record
- **THEN** the value is labeled as an API-equivalent estimate with its pricing provenance, separately from any native reported cost.

#### Scenario: Model has no usable price
- **WHEN** tokens are reported but neither usable pricing nor a native cost value is available
- **THEN** token counts remain visible and cost is marked unavailable or unpriced rather than represented as a known zero charge.

### Requirement: Aggregation counts usage once
Kumiko MUST avoid double-counting the same usage across repeated records, resumed or copied history, cumulative snapshots, and overlapping live/history sources. Token categories that a runtime reports as subsets of other categories MUST NOT be added again to token totals or cost. Changes in context-window occupancy MUST NOT be treated as new historical usage.

#### Scenario: Runtime includes cache and reasoning subsets
- **WHEN** a runtime reports 100 input tokens including 30 cached tokens and 20 output tokens including 5 reasoning tokens
- **THEN** the input breakdown is 70 uncached plus 30 cached, output remains 20 with reasoning shown as its subset, and combined input/output usage is 120 rather than 155.

#### Scenario: Repeated or backfilled usage is encountered
- **WHEN** an already-counted usage record is re-emitted or encountered again in resumed, copied, or backfilled history
- **THEN** its contribution is counted once rather than increasing the aggregate a second time.
