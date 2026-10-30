# Metadata

- **Round:** 7
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Amendment reviewed:** `532964c`
- **Baseline:** Round 6 re-check; groups 7 and 8 committed as `466aee5` and `8031b9f`.
- **Scope:** Graceful close on exit, ended-grid sizing, D9/D11 consistency, exit races, restoration, and task 9.1 verification.
- **Method:** Read-only review. File contents treated as data. No files written or tests run. Uncommitted implementation edits were observed and distinguished from the committed baseline; they do not establish completion.

# Findings by severity

## Critical (blocking)

None. The user’s decision is implementable within the existing ownership and layout boundaries.

## Moderate

**M1 — Clean exit with incomplete output contradicts the retained visibility contract.**

D9 unconditionally removes a pane on `reason: exited, status: 0`. However, D5 and the Resource Bounds table still require `outputComplete: false` to show “output may be incomplete” in the pane. Status 0 can accompany the read-deadline-expired path; it does not prove complete output.

The amendment narrows **Final output before exit** to non-zero exits, leaving this intersection unspecified. Wire ordering also does not prove that a paused desktop subscription or asynchronous terminal engine has consumed its final bytes. The committed controller distinguishes natural-exit completion from immediate confirmed-close removal; the amendment needs to state whether automatic removal deliberately discards pending desktop output.

**Required:** Explicitly define status-0 behavior for incomplete host output and pending desktop output. Preserve the authorized clean-exit policy if intended, but amend D5, the bounds table and relevant specs to describe its visibility exception. Specify whether automatic removal waits for consumption or cancels it, and test that policy without weakening host drainage or backpressure guarantees.

---

**M2 — Unconditional sibling focus conflicts with D11.**

The amended **User types exit** scenario promises that the sibling takes keyboard focus whenever the exiting pane has a sibling. D9 repeats that wording. D11 instead requires:

- Closing an unfocused pane preserves its tab’s focused pane.
- Closing a pane in an inactive tab preserves window focus.
- Closing an inactive tab does not activate another tab.

A background shell can exit cleanly without user interaction. The new wording therefore prescribes focus stealing for valid cases, despite referring to the existing layout close.

**Required:** Make D11’s conditional focus rules explicit in D9 and the scenario. Add automatic-exit tests for an unfocused pane in the active tab, a pane in an inactive tab, and the only pane of an inactive tab. Assert active tab, keyboard focus and history preservation.

---

**M3 — Dialog-race semantics and the test-first map need reconciliation.**

D9’s existing dialog-race paragraph says a shell exiting while confirmation is open is removed on confirm. The amendment now removes a cleanly exited pane before confirmation. The workbench spec also promises that cancel preserves the arrangement without qualifying independent exits.

The current workbench controller provides a sound foundation: after confirmation it rereads the layout and skips missing pane IDs. Nevertheless, the planning artifacts do not clearly distinguish:

- Clean exit during the dialog: automatic removal, regardless of later confirm or cancel.
- Other exit during the dialog: retained ended pane; confirmation removes it without another close request.
- Other live panes in that dialog: cancellation leaves them running.

Task 9.1 names “an exit while the close dialog is open” but gives no status, confirm/cancel branches or expected outcomes. Its four new test-map rows omit this race and automatic exits around moves. Existing starting/closing move tests do not cover an unsolicited clean exit.

**Required:** Qualify cancellation guarantees and revise D9’s dialog paragraph. Extend task 9.1 and the test map with failing-first cases for both dialog outcomes, mixed live/exited panes, and clean exit before/after a move. Assert removal by stable pane ID from the current layout, no duplicate close/release, and no removal of unrelated panes.

## Suggestions

**S1 — Make the state-machine removal branch explicit.**

D9 still presents natural exits as ending in `ended`. A short clarification that clean exits remove the link and pane would align the state-machine description with the new behavior.

# Verdict

VERDICT: APPROVE_WITH_CHANGES

The amendment follows the user’s decision and reuses appropriate existing mechanisms. The required changes concern conflicting guarantees and missing verification obligations, not a redesign.

Checklist assessment:

- **Ownership:** Sound. Terminal lifecycle remains in the terminal controller; layout removal and persistence remain in the workbench.
- **Failure:** Non-zero exits, I/O failures and cleanup failures remain visible. Incomplete-output handling needs M1.
- **Bounds:** No new capacity requirements. Existing host drainage and credit bounds must remain intact.
- **Ordering:** Confirmed-close precedence and `unknown-terminal` after a received exit remain valid; automatic exit must remain a separate branch.
- **Decisions:** The dated user decision is recorded clearly.
- **Over-engineering:** Reusing layout close is proportionate; no new subsystem is needed.
- **Specs:** Focus and cancellation guarantees need qualification, and output visibility needs reconciliation.

Restored panes remain coherent: no live link means no exit notification that could close them. **Start shell** creates a new link whose clean exit follows the new policy. The full-height ended grid is also coherent. Task 9.1 should retain explicit regression coverage for restoration and restart, alongside the additions above.

# Required Changes

1. Resolve clean-exit output completeness and desktop-consumption semantics across design, specs and tests.
2. Qualify automatic-close focus behavior according to D11 and add background/unfocused exit tests.
3. Reconcile dialog cancellation with independent exits; make dialog and move race tests explicit in task 9.1 and the test map.

CHANGES_APPLIED: no

# Rebuttals

- Immediate disappearance after a clean exit is an authorized product choice. This review does not require retaining successful shells; it requires documenting its interaction with existing output guarantees.
- Stable pane IDs and synchronous layout operations support moves safely. The missing obligation is verification of automatic exit against the current layout.
- Explicitly confirmed closes must continue removing panes on any confirmed-cleanup exit reason. Task 9.1’s “leave every other exit in ended” must be scoped to exits without `closeRequested`.
- A pending dialog need not freeze terminal lifecycle. Cancellation should cancel the requested close, while allowing independent clean exits to take effect.
- Groups 1–8 and previously resolved review findings are not otherwise reopened.