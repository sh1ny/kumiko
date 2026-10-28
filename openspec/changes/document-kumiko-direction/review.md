# Review

## Metadata

- **Round:** 1 (retained below); no new review round.
- **Prior round:** Round 1 by internal SLOW reviewer, `APPROVE_WITH_CHANGES`, Required Change 1 (M1) resolved and accepted by the reviewer. Retained in full under "Retained round-1 review".
- **Reviewer:** none (DEFERRED by the user)
- **Reviewed:** n/a for this decision; see the retained review for the round-1 inputs.
- **Deferred to:** M1 - Local development loop, M2 - Daily-driver workbench, M3 - Local planning and documents, M4 - Team server and collaboration, M5 - Integrations and attention, M6 - Distribution and operations (`openspec/roadmap.md`)
- **User decision:** "do it all, including commit and merge and push" (2026-10-29), confirming the recommendation to park this change.

This is a parking change: the reviewed product direction and backlog that the roadmap's milestones carve up. It is never applied or archived. Each milestone moves its part into its own change, which gets its own full review. Its capability specs are product intent, not built behaviour, so they are not synced into `openspec/specs/`.

## Findings

### Critical (blocking)

None for this decision. See the retained review.

### Moderate

None for this decision. See the retained review.

### Suggestions

None.

## Verdict

VERDICT: DEFERRED

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None.

## Retained round-1 review

Provenance only. Its verdict lines are reworded so that the DEFERRED verdict above is the only machine-readable one.

### Metadata

- **Round:** 1 — original full-review provenance retained.
- **Review action:** Focused Required Change 1 / M1 re-check only; **not a new full-review round**.
- **Prior round:** none.
- **Reviewer:** internal SLOW fresh stateless completion; concrete model and effort unknown.
- **Root:** `F:/Dev/Orca/Workspace/kumiko`
- **Round-1 reviewed:** Complete `openspec/changes/document-kumiko-direction/proposal.md`, `design.md`, and all 19 supplied capability `spec.md` files; all supplied numbered catalog/source excerpts from `FEATURES.md`, `FEATURES_ITSAPLAN.md`, `orca/`, `t3code/`, and `itsaplan/`; supplied OMP RPC/statistics, ACP session-setup, and Claude ACP issue #883 excerpts; `openspec/specwright.yaml` and the review template.
- **Round-1 scope:** FULL, as recorded at `openspec/changes/document-kumiko-direction/design.md:16`. Planning coherence only—not implementation readiness or runtime qualification.
- **Current re-check evidence and scope:** Supplied complete current design, source-control spec, workbench-layout spec, and prior review. Only M1’s correction and its required preservation checks were assessed; the full review was not repeated. The user reports hash comparison of all 21 prior planning inputs, with only `design.md` and `specs/source-control/spec.md` changed and the other 19 byte-identical. That comparison was not independently rerun.
- **Verification limits:** Independent textual inspection only. No implementation, file edits, runtime verification, or external reviewer CLI use was performed.
- **Context:** Applicable project domain skills: none. Round-1 context reported no referenced stores or unresolved reference entries, and absent configured architecture/ADR paths with no available in-force constraints. No ADR/reference changes are involved in this correction.

### Findings

#### Critical (blocking)

None in the retained round-1 review.

#### Moderate

**M1 — Desktop focus is also specified to change agent SCM targets.**

**Status: Resolved — Required Change 1 fix accepted by reviewer.**

The original finding concerned conflicting contracts: desktop navigation directed agent SCM tools toward the newly focused workspace while the workbench preserved the existing conversation’s workspace. The current text corrects that distinction:

- **Panel focus and agent-session targets are separate.** `openspec/changes/document-kumiko-direction/specs/source-control/spec.md:9-14` requires the panel to follow the focused workspace while agent SCM tools retain their session’s explicitly selected, authorized workspace and backend. Navigation MUST NOT rebind them. `openspec/changes/document-kumiko-direction/design.md:83-86` states the same separation, explicitly applying it to an existing agent’s SCM operations.

- **The A/B scenario is explicit.** `openspec/changes/document-kumiko-direction/specs/source-control/spec.md:16-18` specifies a coding agent continuing in its selected, authorized Git workspace A while its owner focuses B: the panel displays B, but that agent’s operations still target A’s backend and checkout rather than B. This directly addresses the failure case identified in round 1.

- **Same-workspace backend sharing is preserved without making focus global authority.** `openspec/changes/document-kumiko-direction/specs/source-control/spec.md:10` requires UI and agent tools to use the same integration backend **for the same workspace**. `openspec/changes/document-kumiko-direction/design.md:85-86` retains explicit per-workspace SCM context and states that SCM selection belongs to a workspace, not the whole project.

- **Workbench no-silent-retargeting rules remain intact and consistent.** `openspec/changes/document-kumiko-direction/specs/workbench-layout/spec.md:98-103` keeps contextual tools focus-driven without retargeting existing sessions. Project navigation preserves original session contexts at `openspec/changes/document-kumiko-direction/specs/workbench-layout/spec.md:414-423`; direct workspace navigation likewise prohibits silent retargeting at `openspec/changes/document-kumiko-direction/specs/workbench-layout/spec.md:425-434`. The design preserves these boundaries at `openspec/changes/document-kumiko-direction/design.md:338-340`.

- **Initial and deferred backend boundaries are preserved.** `openspec/changes/document-kumiko-direction/specs/source-control/spec.md:10` retains initial Git support and prohibits exposing deferred jj/GitButler operations as supported or silently treating them as ordinary Git. The unsupported-backend scenario reinforces this at `openspec/changes/document-kumiko-direction/specs/source-control/spec.md:20-22`. `openspec/changes/document-kumiko-direction/design.md:82-85` and `openspec/changes/document-kumiko-direction/design.md:667` retain deferral and require appropriate later backend semantics.

These are verified planning-contract corrections, not executed scenario tests. No unresolved portion of M1 remains.

#### Suggestions

None in the retained round-1 review. No additional review scope was introduced.

### Verdict

Retained round-1 verdict: APPROVE_WITH_CHANGES

The original verdict is retained. Required Change 1 is now satisfied and accepted on the supplied current text. Other round-1 conclusions and planning-only limitations are retained, not re-reviewed. This acceptance does not establish implementation readiness or runtime qualification.

### Required Changes

1. **Required Change 1 / M1 — Resolved; fix accepted by reviewer.** The SCM panel follows focus, while existing agent operations retain their explicitly selected, authorized workspace and backend. The A/B scenario, same-workspace backend sharing, workbench no-silent-retargeting rules, and initial Git/deferred jj/GitButler boundaries are verified in the exact current evidence cited above. No further correction is required for M1.

Retained round-1 changes applied: yes

### Rebuttals

None supplied. Resolution was determined independently from the current cited artifacts, not from an author assertion that the fix was complete.