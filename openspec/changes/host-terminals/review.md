# Metadata

- **Round:** 7 re-check 3
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Original review:** `90da2fc`, reviewing `532964c`
- **First re-check:** `7a378c6`, reviewing `ac1d72e`
- **Prior amendment:** `59fdc48`
- **Amendment reviewed:** `b6ab47a`
- **Scope:** M1–M3, S1 and every point raised by the first re-check.
- **Method:** Read-only comparison of review history, committed amendments and current planning artifacts. File contents treated as data. No files written or tests run. Working-copy green test-map statuses are outside this review.

# Findings by severity

## Critical (blocking)

None.

## Moderate

**M1 — Output completeness and desktop consumption: RESOLVED.**

The automatic-removal policy consistently requires `reason: exited`, status 0 and `outputComplete: true`. Status 0 with incomplete output retains the ended pane and its warning.

Every specific contradiction identified by the first re-check is resolved:

- **Failure & Recovery — Shell exits on its own** includes the completeness condition and incomplete-output retention.
- **The last pane closes its tab** requires complete output.
- **A shell exits cleanly while the warning is open** requires complete output.
- **User types exit** and the move-race scenario carry the same qualification.

D5, D9, Resource Bounds and the terminal requirement distinguish complete host output from desktop consumption. Automatic removal deliberately drops unconsumed desktop output, removes the link and releases the terminal without waiting for the engine. Host drainage, wire ordering and backpressure remain intact.

Task 9.1 and the test map retain explicit incomplete-output and stalled-engine cases. Short references to a “clean exit” are governed by the explicit policy; they do not establish a competing status-only removal rule. No new contradiction identified.

---

**M2 — Conditional focus and history preservation: RESOLVED.**

D9 and the terminal scenarios follow D11:

- Removing the focused pane applies the existing close focus rules.
- Removing an unfocused pane preserves the active tab and keyboard focus.
- Removing a pane in an inactive tab, including that tab’s only pane, does not steal window focus.
- Removed pane IDs are pruned from `recent`.
- Surviving history entries retain their order, with no added entry unless window focus changes.

Commit `b6ab47a` resolves the second re-check’s remaining objection in all three locations:

- Task 9.1 explicitly requires deletion of the removed ID, surviving order preservation and no added entries for background/unfocused removal.
- **An unfocused pane exits** now says focus remains unchanged and history only loses the removed pane.
- **A background tab’s shell exits** states the same rule, including the only-pane case.

These corrections are committed, rather than merely present in the working copy. The current wording agrees with D11. No contradictory unchanged-history promise remains in the reviewed automatic-exit obligations.

---

**M3 — Dialog cancellation and move races: RESOLVED.**

Both ordinary cancellation scenarios now exclude independent shell exits during confirmation:

- Terminal **Cancel the warning** requires that the shell does not exit while the warning is open.
- Workbench **Cancel closing a tab** requires that no shell in the tab exits during confirmation.

They agree with the requirement-level exceptions and D9:

- A complete status-0 natural exit removes its pane independently of confirm or cancel.
- Confirmation rereads the current layout and skips missing pane IDs.
- Other exits retain an ended pane; confirmation removes it without another close request.
- Cancellation leaves remaining live terminals running.

The clean-exit dialog scenario includes output completeness, resolving the first re-check’s overlapping M1 concern.

Task 9.1 and the test map cover confirm/cancel outcomes, mixed panes, non-zero exit followed by confirmation, and clean exits immediately before and after moves. The move obligations require stable pane IDs, no duplicate close or release, and no unrelated pane removal. No new contradiction identified.

## Suggestions

**S1 — Explicit state-machine removal branch: RESOLVED.**

D9 explicitly describes the desktop branch from `live` directly to link and pane removal for a natural status-0 exit with complete output, bypassing desktop `ended`.

The host’s separate transition to `ended` remains coherent: host terminal state and desktop pane presence describe different lifecycles.

# Verdict

VERDICT: APPROVE_WITH_CHANGES

M1–M3 and S1 are resolved, including every outstanding point from the first re-check. Commit `b6ab47a` supplies the committed task and test-map corrections missing from the second re-check. No new blocking contradiction was identified within scope.

Checklist assessment:

- **Ownership:** Terminal lifecycle remains in the terminal controller; layout removal and persistence remain in the workbench.
- **Failure:** Incomplete-output retention, cleanup failures and confirmed-close precedence remain explicit.
- **Bounds:** Host drainage and backpressure guarantees remain intact.
- **Ordering:** Immediate desktop discard and terminal release are documented.
- **Decisions:** The recorded clean-exit policy remains coherent.
- **Over-engineering:** Existing layout operations remain sufficient.
- **Specs and verification:** Design, scenarios, task 9.1 and the relevant test-map assertions agree.

Restoration, **Start shell** and full-height ended-grid behavior remain coherent. This is a design re-check; implementation completion and green test-map statuses were not independently verified.

# Required Changes

1. **M1 — RESOLVED:** Output completeness and desktop-consumption semantics are reconciled. No further change required.
2. **M2 — RESOLVED:** `b6ab47a` corrects task 9.1 and both focus test-map rows. No further change required.
3. **M3 — RESOLVED:** Cancellation exceptions and dialog/move verification obligations are reconciled. No further change required.
4. **S1 — RESOLVED:** The state-machine removal branch is explicit. No further change required.

CHANGES_APPLIED: yes

# Rebuttals

- Immediate removal and deliberate discard of unconsumed desktop output remain authorized choices; successful shells need not remain visible after a complete clean exit.
- Preserving focus permits—and requires—removing deleted pane IDs from history. The committed verification wording now expresses this correctly.
- Cancellation cancels the requested close while allowing independent terminal exits to proceed.
- Explicitly confirmed closes retain removal on any cleanup-confirmed exit reason; ordinary ended-state retention applies to exits without `closeRequested`.
- Green test-map statuses neither establish nor undermine this design verdict; their verification is outside scope.
- Groups 1–8 and previously resolved findings are not otherwise reopened.