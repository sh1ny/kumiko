# Review

## Metadata

- **Round:** 1 (re-check 3)
- **Prior round:** 1 (re-check 2) — APPROVE_WITH_CHANGES
- **Reviewer:** Codex
- **Reviewed:** Only remaining M4 against design.md D5, D9, Flow & State Gaps, and specs/execution-workspaces/spec.md. M1, M2, M3 and M5 carry over as accepted. Proposed mechanisms need not already exist in source.

## Findings

### Critical (blocking)

None.

### Moderate

None. D5 now gates identity and availability by `seq` independently of cleanup fields. Cleanup data applies by `cleanupRevision`, permitting an unchanged resolution sequence after confirmation or successful retry. D9’s list refresh and Flow & State Gaps’ rejection of older cleanup revisions remain consistent with this rule and the “Cleanup confirmed” scenario. No concrete defect introduced by this fix was identified.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **M1 — Applied correctly and completely.** Carried over as accepted: maximum dirty age, successful-save loss bound and failed-save qualification.
2. **M2 — Applied correctly and completely.** Carried over as accepted: transactional context clearing and workspace removal, including live and restored contexts.
3. **M3 — Applied correctly and completely.** Carried over as accepted: cleanup group count and workspace-filtered paging across all matching groups.
4. **M4 — Applied correctly and completely.** D5 separates resolution ordering from cleanup ordering. A `workspace/list` response with unchanged `seq` can update cleanup fields using `cleanupRevision`, clearing the displayed state after confirmation or successful retry while rejecting older cleanup data.
5. **M5 — Applied correctly and completely.** Carried over as accepted: save deadline, visible failure, slot release, increasing revisions and late-response handling.

CHANGES_APPLIED: yes

## Rebuttals

- M4 (re-check 2): fixed. D5 now gates only identity and availability by `seq`. Workspace-record responses carry `cleanupRevision`, and the desktop applies `cleanup` fields by that revision, so a confirm or retry clears the sidebar state through `workspace/list` without a new resolution.

  **Accepted by reviewer: yes.** The independent cleanup revision removes the cleanup-only update blockage.

- M1: fixed. design D6 adds a 2 s maximum dirty age beside the 500 ms debounce, and restates the accepted-loss bound for succeeding vs failing or stalled saves; the save state diagram, Failure & Visibility and Resource Bounds are updated; spec `workbench-layout` adds scenario "Desktop killed during continuous changes".

  **Accepted by reviewer: yes.**

- M2: fixed. design D11 removes the workspace in one host transaction that refuses on bound tabs, clears matching group contexts (`clearContext`), stores the layout at `stored + 1` and deletes the row; the desktop applies the same operation, and load repairs dangling contexts; Flow & State Gaps is updated; spec `execution-workspaces` adds "Removed workspace was a group's context".

  **Accepted by reviewer: yes.**

- M3: fixed. design D9 adds `Ledger.unresolvedGroupsFor(identity:, path:)`, and each workspace record carries `cleanup: {count, identities}` (≤ 8 listed) for the filtered cleanup list; Resource Bounds is updated; spec adds "Unresolved units from a replaced directory".

  Author, after re-check: fixed. D9 drops the identity list; the record carries a group count, and `cleanup/list` takes an optional `workspace` filter that pages over all matching groups with the existing cursor. Resource Bounds row is updated.

  **Accepted by reviewer: yes.** The workspace filter covers all matching groups across pages.

- M4: fixed. design D5 adds per-workspace generations: only the latest unexpired generation of an existing workspace is applied or published, a late completion only frees its slot, removal invalidates, and the desktop applies by generation; specs add "Older check finishes after a newer one", "Check finishes after its timeout" and "Removal during a check".

  Author, after re-check: fixed. D5 replaces per-workspace generations with one host-wide sequence taken at request arrival. A result applies to its matched workspace only when its sequence is above that workspace's `appliedSeq`. An open that loses the ordering returns the current record as existing and writes nothing. Every workspace record, including `workspace/open` results, carries `seq`, and the desktop applies by `seq`.

  **Accepted by reviewer: yes.** Resolution and open ordering remain accepted; the re-check 2 amendment now independently orders cleanup fields.

- M5: fixed. design D6 adds a 10 s desktop save deadline leading to *Failed*, revisions above the highest ever sent, and rules for late ok and late error; Failure & Visibility, Resource Bounds and the Mechanism Ledger are updated; spec adds "Host does not answer a save".

  **Accepted by reviewer: yes.**