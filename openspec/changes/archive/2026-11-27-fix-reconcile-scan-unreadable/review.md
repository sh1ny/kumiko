# Review

## Metadata

- **Round:** 2 (re-check of Required Changes)
- **Prior round:** Round 2 returned APPROVE_WITH_CHANGES for the added OMP scope with one Moderate finding (M4) and two Required Changes.
- **Reviewer:** fresh-context Claude Code worker (Orca, model claude-opus-5-5), read-only
- **Reviewed:** `openspec/changes/fix-reconcile-scan-unreadable/design.md` (D3 and the Resource Bounds table); `packages/host/lib/src/settler.dart:167` and `:208-223` (the `killFails` path on POSIX and Windows).

This re-check covers only the two Required Changes. Editing the proposal or design for any other reason voids it.

## Findings

1. **D3 (M4): applied.** D3's "Choice continued" adds a deterministic variant with `killFails` on before `agent/close`. After the EOF report and the manual grace expiry, it requires:
   - exactly one `agent/closeFailed`, carrying `kill-failed:injected` and `nativeEofUnconfirmed`;
   - the original row unresolved;
   - the persisted `agent_session` warning;
   - a refused launch into the fixture workspace;
   - the fixture still running.

   In teardown the test turns the fault off, kills only the recorded identity and waits for it to stop before the workspace is deleted. That keeps to AGENTS.md rule 5.

   The claim that this works on all three platforms holds. With `killFails` on, a live POSIX unit whose root is still running returns `kill-failed:injected` (`settler.dart:220-222`). A Windows unit whose job still has an active process does the same (`settler.dart:210-218`).
2. **Resource Bounds (M4): applied.** The "OMP close evidence" row now reads "One recorded root identity and one terminal notification per case, with real scan or `killFails`".

M4 is fixed.

### Critical (blocking)

None.

### Moderate

None open.

### Suggestions

- D3's Reversal cost still says "One case in the OMP integration file". It now covers two cases (the real-scan case and the `killFails` variant). The wording is cosmetic and does not affect the verdict.
- Round 2 suggestions S-f and S-g remain optional.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Applied: D3 adds the deterministic `killFails` variant with the required assertions and the teardown steps.
2. Applied: the Resource Bounds row covers both cases.

CHANGES_APPLIED: yes

## Rebuttals

None needed. M4 was fixed by Required Changes 1 and 2.
