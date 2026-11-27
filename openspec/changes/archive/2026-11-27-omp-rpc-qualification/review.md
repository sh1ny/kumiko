# Review

## Metadata

- **Round:** 3, Windows title-bar Close amendment.
- **Prior round:** APPROVE_WITH_CHANGES; all four required changes were applied and rechecked. This review retains those decisions.
- **Reviewer:** read-only cross-model Claude CLI, `claude-opus-5-5`, in an isolated Windows job.
- **Reviewed:** the amended proposal, design, tasks, OMP delta, and Windows observation; the existing `app-exit` spec, the Windows runner, the Dart exit coordinator, and its integration harness.
- **Limits:** the reviewer could not read the installed Flutter SDK outside the worktree. The last-window predicate is a reproduction hypothesis, not proof of the observed fault. No commands, edits or network access.

## Findings

### Critical (blocking)

None.

### Moderate

- **M1 — Native regression seam.** Post the system Close command to the test-owned runner HWND, located by process and window class. Do not invoke the Dart lifecycle hook. The red proof must show no warning, desktop exit 0 and no coordinated host quit. If an auxiliary window is needed, show why it matches the release failure and cover both configurations.
- **M2 — Order-based proof.** Each native Close needs a positive receipt before asserting the absence of a second dialog or exit. After Cancel, another native Close must open a fresh dialog while the original agent unit remains.
- **M3 — Verified confirmed exit.** Isolate the test app so its expected exit does not end the test runner. Check the coordinated host quit before native window destruction, desktop exit 0 and an empty agent ledger afterward.
- **M4 — Runner ownership.** One path into the coordinator, no default teardown while a decision is pending, and no second prompt after an approved response. Specify startup and disposal, and leave auxiliary windows, OS-required exits and other platforms unchanged.
- **M5 — Build gate.** Obtain separate owner approval before building the fixed release. Bind that revision and binary hashes to the fresh paid plan.
- **M6 — Focused rerun.** Use native title-bar Close while a permission is pending and have the owner observe warning, Cancel and confirmation. Restore the inert child pane as part of ordinary-quit evidence.

### Suggestions

Name the existing app-exit requirements in the test map, keep test Win32 support scoped to integration tests, and exercise direct `WM_CLOSE` through the same runner path. Clarify stop criteria if the regression does not reproduce.

## Verdict

The amendment restores the existing Windows contract. It does not change runtime admission or permit combining attempts. No Critical findings.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. M1: D5 and task 4.1 now specify the posted native command, owned window, exact negative signature and conditional auxiliary-window proof.
2. M2: D5 and tasks 4.1–4.2 require warning and repeated-focus receipts, then a fresh dialog after Cancel with the unit still present.
3. M3: D5 and task 4.2 require an owned child process and parent verification of host quit, native destruction and settled ledger without changing production order.
4. M4: D5 specifies interception before Flutter, repeat behavior, startup, disposal and window destruction only on a successful coordinator result.
5. M5: D5 and task 5.1 require explicit build approval and record the fixed release identity before the exact paid plan.
6. M6: D5 and task 5.1 name native title-bar Close, owner-observed decisions and a minimal child to prove inert restore.

CHANGES_APPLIED: yes

## Rebuttals

None.