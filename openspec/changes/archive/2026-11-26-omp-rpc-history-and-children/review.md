# Review

## Metadata

- **Round:** 2
- **Prior round:** Round 1 returned APPROVE_WITH_CHANGES with five Moderate findings: M1 child classification and the optional `parentThreadId`, M2 the Start locator check, M3 the Continue header and argv assumptions plus a scenario, M4 Continue availability on `agent/records`, and M5 the source of the persisted child label. No Critical findings.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, claude-opus-5-5)
- **Reviewed:** `openspec/changes/omp-rpc-history-and-children/review.md` (round 1), revised `design.md` (D1, D4, D5, A1, Resource Bounds), `specs/omp-sessions/spec.md`, `specs/desktop-host-protocol/spec.md`, and `specs/agent-sessions/spec.md`, which I checked only for direct consistency with M4. I re-read one cited source range: `packages/desktop/lib/src/agent/agent_controller.dart:585-619`. I did not open the external links in A1. I treated them as stated public-source assumptions. This round rechecks only M1–M5 and their direct consistency.

## Findings

### Critical (blocking)

None.

### Moderate

None open. Each round 1 Moderate is resolved:

**M1: Resolved.**
- D4 **Choice** accepts an absent `parentThreadId` only in the decoder, and only for an OMP link attached over an `omp-history` connection. Codex keeps the mandatory three-id shape.
- An event counts as a child when `threadId` differs from `rootThreadId`. This applies before transcript routing, text grouping and rendering.
- Attributed OMP child content other than lifecycle rows is dropped before `AgentTranscript.add` on the parent, so it cannot use up root retention.
- The design leaves question scoping on its existing rule, and the source supports that. The `parentThreadId == null` question pruning at `agent_controller.dart:601-605` sits inside `if (link.runtimeKind == 'codex')` (`agent_controller.dart:592`), so OMP events never reach it.
- The OMP-only decoder guard therefore doesn't change Codex question scoping, and it opens no OMP gap. Round 1 asked to reclassify the question-scoping check as well. Leaving that check alone is the narrower fix and is correct.
- The desktop-host-protocol scenario "OMP does not supply the direct parent" now ends with "the parent chat shows only lifecycle rows for that child".

**M2: Resolved.**
- D1 **Choice** now accepts the `get_state` path after checking syntax and length only. The reason it gives is that OMP can allocate the path before it creates the file. An absent or invalid path leaves the locator unset.
- D1 **Continue** says "Only Continue checks existence, regularity and the header."
- This matches the omp-sessions scenario "Native identity has no usable locator". A live chat still works and no locator is invented.

**M3: Resolved.**
- **Header:** A1 now cites `splitTitleSlot` and `session-entries.ts`. It says an optional leading title slot comes before a first session record that carries `type: session`, `id` and `cwd`.
  - The 8 KiB figure is presented as Kumiko's refusal bound, not as a native upper limit ("not a promise that OMP always writes a short header").
  - D1 **Continue** agrees: "Allow one leading OMP title slot, then require a session header". So does the Resource Bounds row: "8 KiB prefix including any title slot and complete session header".
  - The slot is optional and is not the header. The design stays consistent on both points, and it neither retains nor displays the title.
- **Argv:** A1 now lists the exact argv allowlist:
  - It requires exactly one `--mode rpc` or `--mode=rpc`.
  - It lists the value options and their accepted forms, and the bare flags.
  - It refuses positionals, `--`, missing values, option-like values, and mode, target, restore or session-selection overrides.
- **Consistency:** D1 refuses rather than strips argv outside the list, and does not build a command string. That is consistent with the allowlist.
- **Scenario:** omp-sessions adds "Profile arguments could select another session". It refuses before spawn with a bounded reason and leaves the record and draft unchanged. Fixtures can assert that.

**M4: Resolved.**
- D5 **Quit** now says that on a negotiated `omp-history` connection, `agent/records` returns a bounded `continueUnavailable` reason code for OMP records with no locator, next to the unconfirmed-save reason. Neither carries a path.
- The restored parent disables Continue and shows the reason before any request, and shows an unconfirmed save separately.
- This satisfies the omp-sessions scenarios "Continue on a saved OMP session" and "Saved locator is absent", and the agent-sessions scenario "OMP continuation is unavailable for this record". When the peer itself can't continue OMP, the desktop already knows from the negotiated capabilities.

**M5: Resolved.**
- D4 **Presentation** now persists only the root id, the opaque child key and a host-assigned ordinal label such as `Subagent 3`.
- It explicitly forbids persisting a native name, description, assignment, or any other model- or user-written text.
- That is stricter than the round 1 wording, which would have allowed the agent type or name, and it fully satisfies C2 and D29.
- The "bounded labels" in the Child registry Resource Bounds row describe in-memory host state, not layout data, so they don't conflict.

### Suggestions

The round 1 suggestions were optional. I note their status for completeness only:
- **S1 (applied):** D4 **Read** now refuses an absent, inaccessible or oversized child file.
- **S2 (applied):** the desktop-host-protocol scenario "A peer lacks the OMP history capability" gains an AND clause that keeps close and quit warnings for older peers.
- **S3 (applied):** D4 **Presentation** excludes the child view kind from `launcherViews`.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

Round 1 Required Changes 1–5 are all present in `design.md` and in the omp-sessions and desktop-host-protocol deltas, as checked above. No changes remain.

CHANGES_APPLIED: yes

## Rebuttals