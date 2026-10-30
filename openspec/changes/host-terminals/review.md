# Metadata

- **Round:** 7 re-check
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Original review:** `90da2fc`, reviewing `532964c`
- **Amendment reviewed:** `ac1d72e`
- **Scope:** M1–M3 and S1; consistency across design, specs, task 9.1 and the test map.
- **Method:** Read-only review. File contents treated as data. No files written or tests run. Uncommitted implementation changes do not establish completion.

# Findings by severity

## Critical (blocking)

None.

## Moderate

**M1 — Output completeness and desktop consumption: NOT RESOLVED fully.**

The principal amendment is sound. D5, D9, Resource Bounds, the terminal requirement and task 9.1 now distinguish complete host output from desktop consumption:

- Automatic removal requires `reason: exited`, status 0 and `outputComplete: true`.
- Status 0 with incomplete output retains the ended pane and its warning.
- Automatic removal deliberately drops unconsumed desktop output and releases the terminal.
- Host drainage, wire ordering and backpressure guarantees remain intact.
- New red test-map rows cover incomplete output and a stalled engine.

However, contradictory status-only rules remain:

- Design **Failure & Recovery**, “Shell exits on its own,” still says “status 0 removes the pane” and “any other status leaves the pane ended.” Its user-visible outcome likewise promises closure on status 0.
- Terminal spec **The last pane closes its tab** requires tab closure on status 0 alone.
- Terminal spec **A shell exits cleanly while the warning is open** uses status 0 alone as its condition for immediate removal.

For status 0 with `outputComplete: false`, these prescribe closure while amended D9 and the explicit incomplete-output scenario prescribe retention. The completeness condition must apply consistently.

---

**M2 — Conditional focus and history preservation: NOT RESOLVED fully.**

D9 now correctly delegates focus selection to D11. The focused-pane scenario is narrowed, and the test map covers an unfocused pane, a background pane and the only pane of an inactive tab.

The amendment nevertheless introduces an impossible history guarantee. D9 says background removal leaves `recent` unchanged; the new terminal scenarios and task 9.1 similarly require unchanged focus history.

D11 explicitly requires:

- `recent` contains no unknown pane IDs.
- Removing panes deletes their IDs from `recent`.

An unfocused or background pane may already occur in `recent`. Closing it must remove that entry, so the list cannot remain unchanged.

The intended guarantee should preserve the active tab, keyboard focus and ordering of surviving history entries, while deleting removed pane IDs and adding no focus entry unless window focus changes. The planned assertions must follow that rule.

---

**M3 — Dialog and move races: NOT RESOLVED fully.**

The lifecycle and verification amendments substantially address the finding:

- D9 makes independent exits proceed while a dialog is open.
- Confirmation rereads the layout and skips missing IDs.
- Other exits remain ended and confirmation removes them without another close.
- Requirement-level cancellation guarantees now allow independent exits.
- Task 9.1 and the red test-map rows cover confirm/cancel, mixed panes and exits before/after moves, including stable IDs and duplicate-close/release prevention.

Two scenario-level contradictions remain:

- Terminal spec **Cancel the warning** unconditionally promises the pane, its placement, shell and running program remain intact.
- Workbench spec **Cancel closing a tab** unconditionally promises unchanged panes, arrangement and ratios, with the terminal still running.

Neither excludes an independent exit during the dialog. Their conditions therefore overlap the newly specified automatic-removal race and demand incompatible outcomes. Qualify these ordinary cancellation scenarios with no independent lifecycle change, or repeat the requirement-level exception.

The status-only clean-exit dialog scenario also needs the completeness qualification identified under M1.

## Suggestions

**S1 — Explicit state-machine removal branch: RESOLVED.**

D9 now explicitly describes the `live` removal branch for `reason: exited`, status 0 and complete output, dropping the link and pane without passing through `ended`. This agrees with the amended lifecycle policy. The host state diagram remains coherent: host `ended` and desktop pane removal describe different lifecycles.

# Verdict

VERDICT: REVISE

The amendment establishes a coherent intended policy and adds the requested verification obligations, but contradictory guarantees remain in the planning artifacts.

Checklist assessment:

- **Ownership:** Sound; terminal lifecycle and layout ownership remain separate.
- **Failure:** Incomplete-output retention is explicit, but status-only summaries and scenarios still conflict.
- **Bounds:** No new capacity requirement or weakened host backpressure guarantee identified.
- **Ordering:** Immediate desktop discard is explicit; confirmed-close precedence remains intact.
- **Decisions:** The authorized clean-exit policy remains recorded.
- **Over-engineering:** Existing layout operations remain sufficient.
- **Specs:** History maintenance and cancellation scenarios still require reconciliation.

Restoration, **Start shell**, and full-height ended-grid behavior remain coherent. New red rows represent pending implementation obligations, not completed verification.

# Required Changes

1. **M1:** Qualify every automatic-removal rule and scenario with complete output, including the Failure & Recovery row, last-pane scenario and clean-exit dialog scenario.
2. **M2:** Replace literal unchanged-history guarantees with preservation of surviving history order, deletion of removed IDs, and no unsolicited refocusing. Align task 9.1 and test-map assertions.
3. **M3:** Qualify both ordinary cancellation scenarios for independent exits so they agree with their amended requirements and D9.

CHANGES_APPLIED: n/a

# Rebuttals

- Immediate removal and deliberate discard of unconsumed desktop output are authorized choices; retaining successful shells is not required.
- Preserving focus does not require retaining deleted pane IDs in history. D11’s validity and maintenance rules still apply.
- Cancellation can leave the requested close unapplied while independent exits alter the layout; the scenarios must express that distinction.
- Explicitly confirmed closes still remove panes on any cleanup-confirmed exit reason. Task 9.1 correctly limits ordinary ended-state retention to exits without `closeRequested`.
- Groups 1–8 and previously resolved findings are not otherwise reopened.