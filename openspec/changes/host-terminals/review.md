# Metadata

- **Round:** 6
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Scope:** Whole amended design, including commits `d5f2325` and `476ab02`, affected main specs, ADRs, architecture, tasks and current code evidence.
- **Method:** Read-only design review. File contents treated as data. Uncommitted desktop work treated as evidence, not the intended implementation. No files written or tests run.

# Findings by severity

## Critical (blocking)

None.

The ownership boundaries remain sound: the desktop authors layout and owns surfaces; the host validates and persists snapshots and owns processes. Stable pane ids preserve terminal links through moves. The stated bounds constrain both view count and tree size.

The destructive v4 migration is authorized and appropriately narrow: clear only Personal’s layout fields, retain its revision and other records, and commit the change with the schema version in one transaction. The existing store opens newer versions read-only before refusing them. Migration precedes layout decoding, so removing the format 1 decoder is coherent.

## Moderate

**M1 — Focus selection is undefined for valid layouts with incomplete history.**

[D11](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:200) permits `recent` to omit existing panes; task 7.2 rejects unknown and duplicate entries but does not require complete history.

However, closing a pane chooses the tab’s next focus solely from `recent`. Consider a valid two-pane tab with `focusedPane: B` and `recent: [B]`: closing B leaves A, but no specified next focus. Moving B into a new tab creates the same gap in the source tab. Workspace selection likewise has no fallback when bound panes exist but none appears in history.

The active-tab-close rule supplies a neighbouring-tab fallback, but the rules do not specify updating history after fallback focus. They also do not explicitly require a non-null `activeTab` to name an existing tab.

**Required correction:** Define complete focus invariants and deterministic fallback behavior. Either require complete history or retain sparse history and specify fallbacks for close, move and workspace selection. State how operations prune removed ids and record newly focused panes.

---

**M2 — Split refusal and partial tab-close behavior are not fully represented in the specs.**

The [split requirement](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/specs/workbench-layout/spec.md:36) says a refused split leaves layout unchanged. The design correctly distinguishes:

- Local refusal before mutation: limits, missing default or missing capability.
- Host launch refusal after mutation: retain the new terminal pane with the error and **Start shell**.

That distinction appears in the design and task 8.5, but has no corresponding spec scenario.

Partial tab close is similarly defined in the design and task 8.6, while the spec scenarios describe confirmation as closing the entire tab. The single-pane failure scenario promises an unchanged split and sibling; its scope needs clarification when other panes in the same confirmed tab close succeed and disappear.

**Required correction:** Add explicit scenarios for host refusal after splitting and partial tab-close failure. State that successful closes remain completed, failed panes retain their identities and errors, and the tab remains while any pane remains. Scope the unchanged-arrangement guarantee to an isolated failed pane close.

---

**M3 — The planned ADR amendment preserves a decision that v4 deliberately overrides.**

[Task 7.1](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:206) says ADR 0011 amends ADR 0009 decision 3 while its other decisions remain in force.

But [ADR 0009 decision 2](F:/Dev/Orca/Workspace/kumiko/docs/adr/0009-workbench-layout-document.md:18) requires a format migration that **converts** stored documents. D11 explicitly rejects conversion and discards format 1 layouts. The design’s closing ADR section repeats the incomplete amendment scope.

The user decision resolves the product choice; the architectural record must acknowledge the exception.

**Required correction:** Make ADR 0011 explicitly amend decision 2 for this authorized discard as well as decision 3 for the pane shape. Preserve the schema-version gate and transactional migration requirements.

---

**M4 — Groups 7–9 and the test map do not yet cover all promised behavior.**

The domain and migration work generally has clear failing-test-first sequencing, and porting the desktop after the shared model is sensible. Nevertheless:

- Task 8.6 promises partial tab-close failure, but neither its explicit added tests nor the test map requires a mixed success/failure case.
- The map covers moves of live terminals, but not the design’s explicit moves while **starting** or **closing**.
- Task 7.4 delegates to domain map rows, which omit sparse-history fallbacks, closing an inactive tab and history maintenance.
- The preserved main-spec requirement **A failed layout save is visible** has three scenarios absent from this map. They remain applicable after the controller port.
- Migration rollback is promised in Failure & Visibility, but task 7.5 does not explicitly test failure during v4 and successful retry.
- Task 8.5 does not explicitly require its desktop failure-path tests to fail before implementation.

**Required correction:** Add explicit test obligations and map entries for these cases. Existing save-failure tests can be marked for re-run; they need not be rewritten unnecessarily. Make the new controller and split failure tests precede implementation.

## Suggestions

**S1 — Clean up residual group terminology.** The execution-workspaces delta retains scenario names “Removed workspace was a group’s context” and “Workspace still has tabs”; the amended direction spec still mentions the first release’s “tab-group launcher.” Their bodies mostly express the new behavior, but the names obscure traceability.

No additional conversion layer, process reattachment mechanism or host-owned layout operation API is warranted.

# Verdict

VERDICT: APPROVE_WITH_CHANGES

D11 implements the user’s decisions coherently. The remaining changes concern total focus behavior, specification completeness, the ADR exception and verification obligations. The ADDED, MODIFIED, RENAMED and REMOVED requirement structure otherwise accounts for the main-spec group-model replacement and agrees with the amended direction.

# Required Changes

1. Define focus/history invariants and fallbacks for every valid format 2 layout, including dangling active-tab rejection.
2. Specify post-split host refusal and partial tab-close failure explicitly.
3. Record the authorized exception to ADR 0009 decision 2 alongside the decision 3 amendment.
4. Complete the test map and failing-test-first obligations identified in M4.

CHANGES_APPLIED: no

# Rebuttals

- The destructive migration is accepted as an explicit user decision; conversion and an upgrade notice are not requested.
- Groups 1–6 are not reopened because the pane model supersedes the unfinished desktop work.
- Round 5’s pending-feed accounting and conformance-fixture corrections remain present; those findings are not reopened.
- M1 concerns documents permitted by the current validation contract, even if ordinary UI operations usually populate history.
- M2 does not dispute the design’s failure policy; it requires the normative specs to express that policy.
- M3 requires documenting the authorized exception, not reconsidering it.