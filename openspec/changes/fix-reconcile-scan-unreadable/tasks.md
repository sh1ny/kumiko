# Tasks

## Test map

No delta requirements. The change sets `skip_specs: true`. The tests cover the existing `host-process-cleanup` and `omp-sessions` requirements.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| The next lock holder reconciles before launching | Host killed with units running | `packages/host/test/it/reconcile_test.dart` | `killed host's units cleaned or unresolved; no launch before reconcile`; `settlement with an unreadable scan keeps both rows unresolved`; `settlement with a clean scan removes both rows` | Red under the old ledger expectation and controlled unreadability |
| Closing an OMP session ends its input before cleanup | OMP does not exit | `packages/host/test/it/omp_test.dart` | `OMP: OMP does not exit`; `OMP: OMP does not exit and containment cleanup fails` | Red under the old assumption that close cannot fail |

## 1. Fix reconciliation and OMP close tests

- [ ] 1.1 Reproduce the invalid empty-ledger expectation with a denied synthetic PID through `Settler(table:)`, and an empty table as the clean control. Verify the focused regression observes both rows unresolved for the exact unreadable PID rather than deleting them.
- [ ] 1.2 Replace the fixed startup delay with the release in the test executable. Add the event-order checks and the exact clean and unreadable ledger outcomes to the crash test. Verify both restart cases and both controlled table cases in `reconcile_test.dart`. Record C1 and C3 beside the crash case and C2 beside the held timer.
- [ ] 1.3 Keep the OMP EOF barrier and manual grace expiry. Check process exit and the exact cleanup outcome independently of the warning, and force the failure notification with `killFails` in a second case. Verify both `OMP: OMP does not exit` cases and record C4 beside them.
- [ ] 1.4 Run the affected host test files and project gates after the final edits. Record whether heavy checks ran locally or will run on the PR's three CI platforms under the gaming rule. Validate the OpenSpec change strictly.

## Workflow follow-up

- Pass pre-ship review, open the PR and watch CI and review.
- Archive on the PR branch and watch its archive commit. The owner merges.
