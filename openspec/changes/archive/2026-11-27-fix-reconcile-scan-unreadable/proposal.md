# Proposal

## Why

Two macOS runs of PR #51 left crash-recovery rows unresolved with `scan-unreadable` after all reported fixtures passed their liveness check. The second run also failed the OMP close test for the same reason. Both tests require an empty ledger even though PRs #41 and #43 deliberately leave cleanup unresolved when the scan cannot account for a PID. This bugfix is off the roadmap.

## What Changes

- Keep the real host crash, restart and fixture-exit checks. Require either both rows to be removed or, on POSIX, both rows to carry the same `scan-unreadable:<pid>` reason and block launches against their workspaces.
- Reproduce the two ledger outcomes with controlled process-table evidence, independent of the runner's process churn.
- Replace the fixed wait in the affected integration tests with a hold released by the test after it observes the launch refusal. This follows Windows CI rules 1 and 2: assert order and wait for events, not time to pass.
- In the OMP close test, keep the EOF and manual grace expiry, prove that the fixture stopped, and require the same unconfirmed history warning whether containment is cleaned or remains unresolved for an unreadable scan.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. No requirements change, so this change sets `skip_specs: true`.

## Impact

`packages/host/test/it/reconcile_test.dart`, `packages/host/test/it/omp_test.dart` and the separately built test host. Production cleanup, the shipped protocol, and other test files stay unchanged.

## Decision Making

DECISION_MAKING: autonomous

- **Source:** setting. This dispatch requires owner approval for scope and implementation.

### S1: Change the tests only

- **Choice:** Keep native process coverage in both tests, reproduce both scan outcomes with controlled evidence and replace the startup wait with an explicit release.
- **Rejected:** Change how production interprets an unreadable process, or accept unspecified unresolved rows without a deterministic check.
- **Reversal cost:** Low. Test code and a test host hook only.
- **Important:** Yes. It preserves the cleanup contract.
- **Chosen by:** user. The owner answered "Yes, tests only" and approved this scope and its implementation through Orca. The coordinator extended the approved scope to the second macOS failure if the OMP test made the same assumption. That test requires cleanup success where the OMP spec requires it to report the actual outcome.
