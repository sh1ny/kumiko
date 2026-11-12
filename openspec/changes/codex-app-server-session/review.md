# Review

## Metadata

- **Round:** 9.
- **Prior round:** Round 8 returned APPROVE_WITH_CHANGES; its focused recheck recorded the required corrections as applied.
- **Reviewer:** Codex, fresh-context, read-only adversarial design reviewer.
- **Files reviewed:** `AGENTS.md`; change `design.md`, `specs/agent-tool-access/spec.md`, `tasks.md`, `proposal.md`, and `review.md`; qualification document’s tenth-attempt section and attempt-10 JSON receipt; `native_home_audit.dart`; qualification helper’s approved-request matcher and refusal diagnostic. Supporting inventory I/O and socket tests were inspected.
- **Method:** Repository reads only. No files modified, builds, tests, native Codex execution, provider calls, or native Codex-home access.

## Findings

### Critical (blocking)

None.

The proposed removal exception is sound within the expressly bounded, observation-time detector. Inventory failures remain independently incomplete; removal accounting must not subtract or replace those errors (`design.md:181`; `native_home_audit.dart:723`). A removed directory containing protected descendants still produces protected-removal errors for those baseline descendants. Renaming a protected file likewise leaves its original protected entry absent and therefore incomplete.

A destination that is new or metadata-changed remains selected. Persistence through metadata-preserving writes or outside the audited roots remains subject to the existing disclosed limits; removal accounting does not establish coverage beyond them.

### Moderate

**M1. The compatibility test instruction contradicts v3’s existing removed-socket semantics.**

- **Evidence:** `openspec/changes/codex-app-server-session/tasks.md:505` says “v3, v2, v1 and legacy keep `removedEntry` errors,” without limiting entry kinds. However, `design.md:173` and `specs/agent-tool-access/spec.md:121` explicitly account for removed non-protected sockets without error under v3.
- **Grounding:** `packages/host/lib/src/agent/codex/native_home_audit.dart:745` counts such removals in `socketsChanged`. The existing regression test explicitly expects zero `removedEntry` errors (`packages/host/test/agent/native_home_audit_test.dart:1525`).
- **Consequence:** Following the new test instruction literally would change v3’s recorded meaning or create contradictory acceptance tests.
- **Required correction:** State compatibility expectations by selection and entry kind. Preserve v3’s removed-socket exception and counter, while retaining its ordinary file/directory/link removal errors. Under v2/v1/legacy, preserve their existing unsupported-socket behavior rather than requiring a socket-specific `removedEntry` result.

### Suggestions

**S1. Include v4 in the resource-bound summary.**

`openspec/changes/codex-app-server-session/design.md:462` assigns the larger metadata and retained-string bounds only to v2 and v3. D5 and the governing spec already assign those inherited bounds to v4 (`design.md:181`; `specs/agent-tool-access/spec.md:108`). Update the summary to match.

**S2. Make the diagnostic’s guard coverage explicit.**

The enumerated diagnostic checks at `design.md:182` omit some existing matcher guards: valid operation, configured command type and absence of CR/LF (`tool/qualify_codex_app_server.dart:294`, `:326`). Title and truncation already have diagnostic fields (`:384`).

Retain those fields and add content-free results for the remaining guards, or explicitly distinguish them from preview checks. Extend `tasks.md:509` accordingly. This makes “one boolean per match check” testable without leaving another unexplained refusal.

The proposed booleans and bounded counts disclose predicates and shape, but no command, path, option name, decision value, or secret bytes. Contains/starts-with flags compare against the fixed approved command; they are suitable for this content-free diagnostic. They must remain observational and never participate in approval selection. The explicit unchanged-rule requirement and isolated failing-check tests provide an appropriate implementation constraint (`design.md:182`; `tasks.md:512`).

Attempt 10 remains correctly recorded as INCOMPLETE. Its zero matches do not establish a clean audit, and v4 must not reinterpret its consumed v3 manifest (`docs/qualification/codex-app-server.md:1125`; `design.md:181`).

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Correct `tasks.md:505` to preserve each earlier selection’s actual removal behavior, explicitly retaining v3’s non-protected removed-socket exception and `socketsChanged` accounting.

## Focused Recheck (Round 9 Required Changes)

### Required Change 1 — Applied

`openspec/changes/codex-app-server-session/tasks.md:505–509` now distinguishes earlier selections and entry kinds: v3 retains `removedEntry` errors for removed files, directories and links, while removed non-protected sockets remain counted in `socketsChanged`. v2, v1 and legacy retain removal errors for inventoried entries and their existing unsupported-socket behavior.

This agrees with v3’s socket exception at `openspec/changes/codex-app-server-session/design.md:173–174` and `openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:121–122`. The v4 amendment preserves earlier meanings at `design.md:181` and `specs/agent-tool-access/spec.md:128`. The required planning correction is fully applied.

### S1 — Applied

`openspec/changes/codex-app-server-session/design.md:462` now explicitly includes changed-artifacts-v4 alongside v2 and v3 for the 65,536-entry ceiling, 16 MiB per-inventory retained-string budget and 32 MiB combined budget. This matches the inherited bounds at `design.md:181` and the explicit selection list at `openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:108`.

### S2 — Applied

`openspec/changes/codex-app-server-session/design.md:182` now explicitly includes valid operation, configured-command string type and absence of CR/LF, while retaining the existing title and truncation fields. It preserves the content-free, observational diagnostic and unchanged approval rule.

`openspec/changes/codex-app-server-session/tasks.md:513–519` requires those guards, existing fields and isolated failing-check coverage. These correspond to the matcher guards at `tool/qualify_codex_app_server.dart:294–297` and `tool/qualify_codex_app_server.dart:326–328`. The suggestion is fully applied to the planning artifacts; implementation was not requested or verified.

### New inconsistency — Scenario-map status

The amended protected-entry/bounds scenario explicitly includes v4’s metadata bounds and baseline-abort behavior at `openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:108–110`, but its map row remains green at `openspec/changes/codex-app-server-session/tasks.md:87`. The v4 removal row is red at `tasks.md:90`, and v4 baseline-preflight implementation/testing is still instructed at `tasks.md:495–496` and `tasks.md:511–512`.

The protected-entry/bounds row should remain red until its amended v4 coverage is verified, or explicitly distinguish verified earlier-selection coverage from pending v4 coverage. This status inconsistency does not undo Required Change 1.

CHANGES_APPLIED: yes

## Rebuttals