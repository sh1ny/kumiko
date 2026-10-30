# Metadata

- **Round:** 7 re-check 2
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Original review:** `90da2fc`, reviewing `532964c`
- **First re-check:** `7a378c6`, reviewing `ac1d72e`
- **Amendment reviewed:** `59fdc48`
- **Scope:** M1–M3, S1 and every outstanding point from the first re-check.
- **Method:** Read-only comparison of committed artifacts and current files. File contents treated as data. No files written or tests run. Uncommitted changes are distinguished from the reviewed commit.

# Findings by severity

## Critical (blocking)

None.

## Moderate

**M1 — Output completeness and desktop consumption: RESOLVED.**

The previously contradictory automatic-removal rules now require complete output:

- **Failure & Recovery**, “Shell exits on its own,” requires status 0 and `outputComplete: true`; incomplete output retains the ended pane.
- **The last pane closes its tab** requires status 0 and complete output.
- **A shell exits cleanly while the warning is open** requires status 0 and complete output.
- **User types exit** and the move-race scenario carry the same qualification.

D5, D9, Resource Bounds and the terminal requirement consistently distinguish host output completeness from desktop consumption. Automatic removal deliberately drops unconsumed desktop output and releases the terminal without waiting for the engine. Host drainage, ordered delivery and backpressure remain intact.

Task 9.1 and the test map retain coverage for incomplete-output retention and a stalled engine. No new contradiction identified within this finding.

---

**M2 — Conditional focus and history preservation: NOT RESOLVED fully in the reviewed commit.**

The design and terminal scenarios are corrected:

- Background removal preserves the active tab and keyboard focus.
- Removing a pane deletes its ID from `recent`.
- Surviving history entries preserve their order.
- History gains no focus entry unless window focus changes.
- Focused-pane removal follows D11.

However, **`59fdc48` does not include the corresponding `tasks.md` corrections**. Its committed task 9.1 still requires the active tab, keyboard focus and `recent` to remain unchanged for background/unfocused removal. Its two test-map rows likewise retain:

- **An unfocused pane exits:** “recent unchanged.”
- **A background tab’s shell exits:** “recent unchanged,” including the only-pane case.

These assertions still contradict D11 whenever the removed pane appears in history. This is the exact verification inconsistency identified by the first re-check.

The current working copy corrects all three locations: task 9.1 and both test-map rows now require pruning the removed ID while preserving surviving history. Those corrections are **uncommitted**, so they do not establish resolution in `59fdc48`.

---

**M3 — Dialog cancellation and move races: RESOLVED.**

Both outstanding ordinary cancellation scenarios now exclude independent shell exits while confirmation is open:

- Terminal **Cancel the warning** requires that the shell does not exit during the warning.
- Workbench **Cancel closing a tab** requires that no shell in the tab exits during confirmation.

These conditions agree with the requirement-level exceptions and D9:

- A complete status-0 exit removes its pane independently of confirm or cancel.
- Confirmation rereads the current layout and skips missing pane IDs.
- Other exits retain an ended pane; confirmation removes it without another close.
- Cancellation leaves remaining live terminals running.

The dialog’s clean-exit scenario now includes output completeness, resolving its overlap with M1. Task 9.1 and the committed test map retain confirm/cancel, mixed-pane and before/after-move verification obligations, including stable IDs, duplicate-close/release prevention and protection of unrelated panes.

## Suggestions

**S1 — Explicit state-machine removal branch: RESOLVED.**

D9 explicitly describes the complete status-0 natural-exit branch from `live` directly to link and pane removal, bypassing desktop `ended`. The host’s separate transition to `ended` remains coherent.

# Verdict

VERDICT: REVISE

M1, M3 and S1 are resolved. M2’s design and scenario corrections are sound, but the reviewed commit still contains contradictory task and test-map assertions. The working copy contains the missing corrections.

Checklist assessment:

- **Ownership:** Terminal lifecycle and layout ownership remain coherent.
- **Failure:** Incomplete-output retention and confirmed-close precedence remain explicit.
- **Bounds:** No weakened host drainage or backpressure guarantee identified.
- **Ordering:** Immediate desktop discard and release are documented.
- **Decisions:** The recorded clean-exit policy remains coherent.
- **Over-engineering:** Existing layout operations remain sufficient.
- **Specs and verification:** Specifications agree; committed M2 verification wording still needs reconciliation.

Restoration, **Start shell** and full-height ended-grid behavior remain coherent. Working-copy green test-map statuses were not independently verified.

# Required Changes

1. **M1 — RESOLVED:** No further change required.
2. **M2 — NOT RESOLVED in `59fdc48`:** Include the existing working-copy corrections to task 9.1 and the two focus test-map rows. Require removal of deleted pane IDs, preservation of surviving history order and no unsolicited refocusing.
3. **M3 — RESOLVED:** No further change required.
4. **S1 — RESOLVED:** No further change required.

CHANGES_APPLIED: n/a

# Rebuttals

- The remaining objection concerns committed verification wording; the amended design and scenarios already express the correct history behavior.
- The uncommitted `tasks.md` corrections address that objection, but cannot be attributed to `59fdc48`.
- Immediate removal and deliberate discard of unconsumed desktop output remain authorized choices.
- Cancellation cancels the requested close while allowing independent exits to proceed.
- Explicitly confirmed closes retain removal on any cleanup-confirmed exit reason.
- Groups 1–8 and previously resolved findings are not otherwise reopened.