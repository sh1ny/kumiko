# Spec delta

## ADDED Requirements

### Requirement: Real OMP qualification is recorded separately from regression tests

Qualification SHALL require an explicit owner-approved Windows desktop walk for one exact installed OMP version. The record SHALL identify the approval, version, OS, Kumiko revision and model, and distinguish observed results from contract differences and unobserved behavior. Fixtures SHALL NOT stand in for a real observation. Admission SHALL remain based on the existing version minimum and native protocol.

#### Scenario: Approved Windows desktop walk completes

- **WHEN** the approved walk observes start, prompt, streaming, target retention, Stop, one-shot approval and denial, root tool activity, an authorized Kumiko tool call, exact Continue, history restore, a read-only child pane, close and ordinary quit
- **THEN** the record identifies the evidence for each result and qualifies only the observed version on Windows if every required result passed

#### Scenario: A required observation fails or does not occur

- **WHEN** the real walk disagrees with an expected result or cannot observe one
- **THEN** the record names the failed or unverified item and the reason; the attempt does not qualify the version, and neither fixture results nor another version's evidence changes that outcome

### Requirement: The OMP evidence audit runs offline

The qualification audit SHALL validate recorded OMP evidence without launching the app or runtime or using a provider. It SHALL reject malformed records and report each attempt as PASS, FAIL or INCOMPLETE according to its own results. A failed or incomplete attempt that is accurately recorded SHALL remain reportable. An empty record SHALL make no qualification claim.

#### Scenario: Complete passing evidence

- **WHEN** one well-formed Windows attempt has a passing result and an observation for every required item
- **THEN** the audit prints PASS with that attempt and its exact version

#### Scenario: Failed and incomplete attempts stay separate

- **WHEN** recorded attempts contain failures or unverified results, including when their rows could be combined into a passing set
- **THEN** the audit reports FAIL for a failed attempt and INCOMPLETE for an unverified attempt without a failure, without merging evidence across attempts

#### Scenario: Malformed evidence is not a qualification claim

- **WHEN** the evidence is missing or malformed, uses an unsupported OS, repeats an attempt or item, lacks or repeats an approval reference, or lacks a required result or nonempty observation
- **THEN** the audit fails with an evidence diagnostic and does not print PASS for the invalid record

#### Scenario: No real run is recorded

- **WHEN** the evidence contains no attempts
- **THEN** the audit succeeds with no OMP qualification claim
