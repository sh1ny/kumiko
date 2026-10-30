# Metadata

- **Round:** 6 re-check
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Original review:** `68e34ad`
- **Amendments reviewed:** `188671b`, `ce51def`
- **Scope:** Original round 6 findings; amended proposal, design, tasks and all capability delta specs; direction workbench-layout spec; consistency of the two user decisions dated 2026-10-30.
- **Method:** Read-only design review. File contents treated as data. No files written or tests run. Resolution means the planning artifacts address the finding; implementation remains pending.

# Findings by severity

## Critical (blocking)

None. No new blocking contradiction identified.

The ownership boundaries remain coherent: the desktop authors layouts and owns terminal surfaces; the host validates and persists snapshots and owns processes. Stable pane identities preserve terminal links across moves.

The authorized v4 discard remains narrow and transactional, retaining the working-set revision and other records. The store-version gate prevents older builds from overwriting the new layout.

## Moderate

**M1 — Focus selection is undefined for valid layouts with incomplete history — RESOLVED.**

Design D11 now makes focus selection total without requiring complete history:

- `activeTab` is null exactly when there are no tabs; otherwise it must name an existing tab.
- Closing a tab’s focused pane selects the sibling subtree’s first pane in tree order. Closing an unfocused pane preserves that tab’s focus.
- Closing the active tab selects its right neighbour, otherwise its left neighbour, preserving the selected tab’s own focused pane; closing the last tab leaves no active tab.
- Closing an inactive tab or one of its panes preserves window focus.
- Moving a focused pane into a new tab applies the same source-tree fallback.
- Workspace selection uses sparse `recent`, with strip-order and tree-order fallback when history contains no matching pane.
- Removals prune history, and changes to window focus record the newly focused pane. Changes confined to an inactive tab do not fabricate window-focus history.

The workbench spec, tasks 7.2–7.4 and 7.6, and corresponding test-map rows support these rules, including dangling active-tab rejection.

---

**M2 — Split refusal and partial tab-close behavior are not fully represented in the specs — RESOLVED.**

The split requirement now distinguishes refusal before pane creation from host launch refusal afterwards. The explicit **Host refuses the new terminal** scenario retains the new pane, focused, with the refusal reason and **Start shell**.

The close requirement and **Part of a tab close fails** scenario now preserve successful closes, retain failed panes with their identities and errors, and keep the tab while any pane remains. The unchanged-arrangement guarantee explicitly concerns a failed single-pane close.

These requirements agree with D9, D11, Failure & Visibility, tasks 8.5–8.6 and the test map. Successful-close scenarios can be read consistently with the explicit failure branches.

---

**M3 — The planned ADR amendment preserves a decision that v4 deliberately overrides — RESOLVED.**

Task 7.1, D11 and the design’s ADR section now require ADR 0011 to amend both:

- ADR 0009 decision 2: the authorized v4 exception discards format 1 layouts instead of converting them.
- ADR 0009 decision 3: the former tab shape becomes a pane inside the new tab structure.

The schema-version bump, transactional migration and newer-store refusal remain required. The ADR itself is appropriately scheduled for implementation.

---

**M4 — Groups 7–9 and the test map do not yet cover all promised behavior — RESOLVED.**

The amendments add explicit obligations for every identified gap:

- Mixed success/failure during tab close.
- Moving terminals while starting or closing.
- Sparse-history fallback, inactive closes, focus invariants and history maintenance.
- Re-running all three preserved **A failed layout save is visible** scenarios after the controller port.
- Injected failure inside migration v4, rollback to unchanged v3 content, and successful retry.
- Split failure tests and close-controller tests written and observed failing before implementation.

Tasks 7.2–7.6 and 8.1–8.6 supply the obligations; the test map names the principal scenarios and expected outcomes. Group 9 retains final CI and test-map verification. Planned tests remain marked pending rather than being represented as completed evidence.

## Suggestions

**S1 — Clean up residual group terminology — RESOLVED.**

The execution-workspaces scenarios now read **Removed workspace was the sidebar selection** and **Workspace still has bound panes**. The old removal requirement is explicitly removed and replaced with the pane-based requirement.

The direction spec’s first-release launcher scenario now uses **tab-strip launcher**. Historical group references remain useful in explanations of the superseded model and migration.

**Additional consistency check — Both new user decisions are coherent.**

The amended artifacts consistently specify sibling-tree focus, right-then-left tab selection, and no active tab after the final close. The detailed design distinguishes tab-local focus from window focus.

The zero-tab state consistently provides a short message, a prominent **New terminal** button displaying its shortcut, and the tab strip’s available + menu. The shortcut is **Ctrl+Shift+T** on Windows/Linux and **Cmd+T** on macOS, works with or without open tabs, and is consumed before terminal input handling. Capability refusal, workspace binding and default-profile behavior agree across the specs, design, tasks and test map.

The direction spec describes the same empty-state behavior at a broader level. Residual references to the first-launch “launcher” do not prescribe a competing empty-state layout.

# Verdict

VERDICT: APPROVE_WITH_CHANGES

All four required changes and S1 are resolved in the amended planning artifacts. The two additional user decisions introduce no new blocking contradiction. Implementation and execution of the planned verification remain outstanding.

# Required Changes

1. **Resolved:** Define complete focus/history invariants and deterministic fallbacks, including dangling active-tab rejection.
2. **Resolved:** Specify post-split host refusal and partial tab-close failure explicitly.
3. **Resolved:** Record the authorized exception to ADR 0009 decision 2 alongside the decision 3 amendment.
4. **Resolved:** Complete the test map and failing-test-first obligations identified in M4.

No further required amendments arise from this re-check.

CHANGES_APPLIED: yes

# Rebuttals

- The destructive migration remains accepted as an explicit user decision; conversion and an upgrade notice are not required.
- Groups 1–6 are not reopened by this amendment re-check.
- Round 5’s pending-feed accounting and conformance-fixture corrections are not reopened.
- Sparse history remains valid because close/move focus no longer depends on it and workspace selection has a deterministic fallback.
- M2 required normative failure branches; those branches are now present.
- M3 required documenting the authorized architectural exception; the amended design and ADR task now do so.
- Approval of these amendments does not claim that pending implementation tasks or tests have passed.