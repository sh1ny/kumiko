# Proposal

## Why

M2 needs Windows evidence that Kumiko can drive the installed OMP runtime, not just a scripted peer. Changes 2–4 built the path; this change checks the runtime exit criterion in an owner-approved desktop walk. The owner will observe the live controls and restored panes. The evidence does not close M2 or establish daily use.

## What changes

- Walk start, prompt, streamed replies, Stop, approve and deny, tool cards, a real `kumiko_session_info` call, exact Continue, history restore, read-only subagent panes, close and ordinary quit. Check that changing the selected workspace does not move the run.
- Record observations for one exact installed OMP version on Windows. Name the model, Kumiko revision and test conditions. Record OMP's differences from the shared contracts separately from observations that fail or never occur.
- Add an offline check for the recorded evidence. Neither this check nor the default test or CI runs launch installed OMP. Leave runtime admission and provider setup unchanged.
- Fix the Windows title-bar Close path found during the second walk: a pending permission must reach the existing quit dialog instead of losing the host connection. Prove it with a Windows regression that uses a scripted agent. After separate owner approval, rerun only pane close, app quit, reopen, exact Continue and root history restore with installed OMP.

No Linux or macOS qualification, provider sign-in experiment, independent subagent control, read-only coding role, or Sessions browser. Leave the parked direction unchanged.

## Decision making

DECISION_MAKING: autonomous

Source: setting. The dispatch reserves scope, build, use of the owner's account, owner-only checks and merge for explicit owner approval.

### S1: Windows desktop walk and offline evidence check

- Choice: Walk the existing product with temporary folders. Add an offline check and preserve exact version, OS and capability outcomes without changing runtime admission.
- Rejected: Add a second runtime runner, promote fixtures to real observations, or require an exact-version admission list.
- Reversal cost: Low for the walk; medium for the evidence contract.
- Important: yes (the evidence contract binds future qualification claims).
- Chosen by: user (Ormy item 101, event `e2963`, relayed by the coordinator).

### S2: Fix the Windows quit bypass in this change

- Choice: Restore the current `app-exit` contract for Windows title-bar Close and rerun the missed live checks on the fixed release.
- Rejected: Accept the uncoordinated exit as a save, flag it as an upstream OMP defect without proof, or combine two partial attempts into a qualification pass.
- Reversal cost: Low.
- Important: yes (the old path can end work without confirmation).
- Chosen by: user (Ormy item 101, event `e3159`, relayed by the coordinator).

## Capabilities

### New capabilities

None.

### Modified capabilities

- `omp-sessions`: Require a separately recorded, explicitly approved Windows observation for an exact-version qualification claim. An incomplete or failed walk does not qualify the version, and qualification does not control launch admission.

## Impact

The change adds an OMP runbook and evidence under `docs/qualification/`, an offline audit check, and the Windows title-bar close fix and its regression. It changes no host protocol, runtime admission or migration.

Sources: M2 change 5, the archived OMP transport, permissions/tools and history/children changes, ADRs 0004, 0012, 0018 and 0019, and the Codex qualification record. Carries direction D6, D7, D15, D20, D29 and D37 without changing the parked change.

Branch gate: Specwright 0.39.1, interface 3, confirmed the clean `feat/omp-rpc-qualification` worktree at `312f55a`, equal to local and freshly fetched `origin/main`. Neither main ref held an archive for this change. The dispatch authorizes adopting this branch.
