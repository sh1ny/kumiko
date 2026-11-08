# M1 close record - 2026-11-08

## Scope and decision

The user chose Windows-only delivery for now, with Linux/macOS ports later, then explicitly instructed: "Defer the latency finding to a tracked follow-up and close M1." M1 closes with that exception. No missing observation or timing failure is converted to a pass. Accepted ADRs, runtime qualification data, tests and historical walk results remain unchanged.

## Evidence

- Refreshed main: `03e9ca4f43cc6ba078f6e1c2405dcbc55118fd8d`. All six M1 change archives are on main: scaffold-desktop-and-host, local-store-and-workbench-shell, host-terminals, claude-acp-chat-session, kumiko-tool-delivery, app-exit-and-reopen.
- [Main CI run 42509660689](https://github.com/sh1ny/kumiko/actions/runs/42509660689) succeeded at that merged commit.
- The [archived M1 walk](../../openspec/changes/archive/2026-11-08-app-exit-and-reopen/m1-walk.md) records Windows user passes for launch, shells, terminal interaction, Claude ACP, target stability, close decisions, reopen and recovery. Linux/macOS observations remain unverified and move to the future port milestone.
- Local `mise run audit` passed: 125 dependency packages checked, no denied analytics/crash-report/remote-logging package. The qualification checker reports ACCEPTED with Linux/macOS real-adapter observations unproven; this status is preserved.
- Local `mise exec -- dart test test/it/terminal_qualification_test.dart` in packages/host finished with two passing tests and one skipped. The control test passed (worst printed resize acknowledgement 4 ms). The input-queue test was skipped because the OS absorbed the input and the host bound was not observable. This run does not explain the earlier close-acknowledgement breach.

## M1-F1: Windows terminal close latency

**State:** Open; explicitly deferred by the user at M1 close. **Owner:** Future host reliability change. **Scope:** Windows terminal resize/close control acknowledgements under saturated output and a stalled consumer (ADR 0002).

The archived walk records a 359.3 ms close acknowledgement in [CI run 42474936125](https://github.com/sh1ny/kumiko/actions/runs/42474936125), above the unchanged 250 ms bound; it also records a reported local 2.02 s observation under load. Neither the recorded later green CI run nor the current local pass establishes the cause. The existing diagnostic prints resize timing before close and does not distinguish which close caused the historical breach.

**Follow-up:** Reproduce under measured load, distinguish each close acknowledgement from cleanup settlement, trace the delaying work, and fix the cause with regression coverage. Close this item only with evidence that explains the breach and validates the unchanged contract, or an explicit reviewed contract decision by the user. Do not loosen or skip the assertion merely to obtain a green result.

## Deferred platform work

Linux/macOS ports must complete real-shell and real-adapter qualification, tool delivery, the interactive terminal bar, first launch, close/cancel, target stability, reopen and recovery observations before support is claimed. Existing cross-platform CI is retained. Historical unverified rows stay intact.
