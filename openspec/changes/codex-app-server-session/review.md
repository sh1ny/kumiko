# Review

## Metadata

- **Round:** 7
- **Prior round:** Round 6 returned APPROVE_WITH_CHANGES; its focused recheck recorded all five required changes applied.
- **Reviewer:** Codex, fresh-context, read-only adversarial design reviewer.
- **Files reviewed:** `AGENTS.md`; change `design.md`, `proposal.md`, `tasks.md`, `review.md`, and `specs/agent-tool-access/spec.md`; qualification record sections covering credential/configuration filenames and attempts 7–8; `native_home_audit.dart`; relevant audit preparation/result code in `agent_service.dart`; manifest selection, disclosure and binding code in `qualify_codex_app_server.dart`; supporting metadata I/O in `tool_file_audit.dart`.
- **Method:** Repository reads only. No modifications, builds, tests, native runtime, provider calls, native-home reads or tracker operations.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. The entry ceiling does not establish the claimed memory ceiling.**

- **Evidence:** `design.md:159` claims “a few hundred bytes per record” and “a few tens of MiB at most.” However, records retain paths, and v2 additionally retains variable-length link target text (`design.md:160`). The current inventory also retains a map, a deduplication set and pending directory records (`native_home_audit.dart:213-225`); the baseline remains live while the second inventory is built (`native_home_audit.dart:313-316`).
- **Gap:** No path-length, target-length or aggregate retained-string budget supports the claimed maximum. The measured entry count establishes useful entry-count headroom, not memory usage. Deep paths and long targets can exceed the estimate while remaining within 65,536 entries.
- **Test gap:** `tasks.md:417-425` tests entry admission but has no variable-length metadata or peak retained-storage cases.
- **Consequence:** An implementation can satisfy every listed case while exceeding the stated memory bound.

**M2. Link-owned metadata and Windows junction handling lack a concrete, testable acquisition contract.**

- **Evidence:** `design.md:160` and `agent-tool-access/spec.md:115` require comparison of a link’s **own** metadata and target text. The existing inventory seam exposes only `stat` and `children` (`native_home_audit.dart:64-67`). Its filesystem implementation delegates to `FileAuditIo` (`:70-75`), which supplies zero size and epoch timestamps for non-file/non-directory entries (`tool_file_audit.dart:21-30`). It supplies no target text.
- **Gap:** The amendment does not define how the seam acquires a no-follow link observation, distinguishes supported junctions/symlinks from unsupported reparse entries, or refuses unavailable or unstable link metadata. Extending the present sentinel tuple with target text would miss own-metadata changes despite apparently satisfying the comparison rule.
- **Test gap:** `tasks.md:419-425` names generic link cases and an injected lister, but does not explicitly require separate Windows junction and symlink fixtures exercising the real acquisition layer. An injected observation can prove comparison logic without proving that filesystem observations describe the link itself.
- **Consequence:** The planned tests could pass while real Windows links are compared using incomplete or target-derived observations, allowing a false unchanged classification.

**M3. The normative requirement still prohibits v2, and baseline refusal remains v1-only in the spec.**

- **Evidence:** `agent-tool-access/spec.md:92` says **only** `changed-artifacts-v1` enables wider coverage and **all metadata limits remain unchanged**. That contradicts the new v2 scenario (`:114-116`). The baseline-refusal obligation at `:110` also explicitly names only v1, whereas `design.md:163` applies it to v2.
- **Related stale authority:** The resource-bound table still specifies a single 4096-entry native inventory limit (`design.md:441`), without a selection-specific exception.
- **Consequence:** An implementer following the new scenario violates the requirement’s governing text. Conversely, a v2 implementation that skips baseline refusal lacks an explicit matching spec obligation, although the design and tasks require refusal.
- **Existing safeguard:** `tasks.md:428` does request v2 baseline tests. This reduces implementation risk but does not resolve the contradictory specification.

### Suggestions

**S1. Make the link limitation precise and carry it into results.**

- **Evidence:** `design.md:161` says writes through an unchanged link land outside the audit. A target may instead be independently inventoried through another ordinary path inside the home. The actual limitation is that the **link traversal route is excluded**, so its target receives no coverage merely because the link is present.
- Two inventories also establish equality at observation times, not continuous immutability. A temporary retarget restored between observations is not proven absent.
- Clarify both points in the canonical disclosure and recorded detector limits. Add helper assertions that receipts retain those fixed limits without target text or arbitrary names (`tasks.md:424-427`).

The overall direction is reasonable: unchanged-link acceptance is an explicit weakening, v1 and legacy meanings are preserved, protected-name links remain unread, concurrent writers are disclosed, and fresh approval must state that other Codex sessions are paused (`design.md:158-163`; `tasks.md:402-433`). Attempts 7–8 remain INCOMPLETE, with no provider work or content scan claimed (`docs/qualification/codex-app-server.md:1024-1028,1056-1067`). The concerns above concern the amendment’s enforceability, not the owner’s choice of home.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Bound retained metadata storage (M1).** Replace the unsupported fixed-size memory claim with an explicit storage model covering paths, target text, both inventories and traversal/deduplication state. Define enforceable length or aggregate storage limits, fail incomplete on exhaustion, and add deterministic long-path/long-target and overlapping-inventory tests. Preserve v1’s recorded limits.

2. **Specify and test link observation (M2).** Define a test-only injectable no-follow link-observation operation containing supported link type, own metadata and target text. Unavailable, unsupported or unstable observations must remain incomplete without emitting exception paths or target text. Require separate owned Windows junction and symlink acquisition tests, plus injected acquisition failures, protected-name links and link/file/directory transitions. Comparison tests alone must not satisfy acquisition coverage.

3. **Reconcile normative coverage and bounds (M3).** Update the requirement at `agent-tool-access/spec.md:92` to admit explicitly approved v1 and v2 with selection-specific metadata ceilings and the narrowly scoped v2 link exception. Apply baseline refusal and consumed-attempt receipt obligations explicitly to both wider modes. Update `design.md:441` consistently, keeping scanner file/byte limits and legacy/v1 meanings unchanged.

## Focused Recheck (Round 7 Required Changes)

### Required Change 1 — Applied

`design.md:159` replaces the estimated memory claim with UTF-8 accounting for every retained string, explicitly including relative paths, deduplication keys, pending directory paths and link target text. It establishes 16 MiB per inventory, 32 MiB combined while the baseline remains live, a 4096-byte individual path/target limit, bounded fixed record counts, upstream enumeration stop and an incomplete `metadataStorage` outcome. It preserves v1’s recorded limits.

`tasks.md:429-432` requires deterministic long-path/long-target tests, individual-length enforcement, per-inventory and overlapping-inventory exhaustion, upstream stop and error-category checks. `specs/agent-tool-access/spec.md:115` requires incomplete results for storage exhaustion or over-long paths/targets; `design.md:447` carries the aggregate budgets into the resource-bound table.

Applied to the planning artifacts; test execution and implementation were outside this recheck.

### Required Change 2 — Applied

`design.md:162-166` defines injectable, test-only `observeLink(path)` with supported link kind, own attributes, own creation/last-write times and stored target text, acquired without following the link. Windows acquisition uses the entry’s own find-data metadata and supported symlink/mount-point reparse tags. Other tags are unsupported; non-Windows link acquisition remains unavailable and incomplete.

Unavailable, failed, unsupported or immediately unstable observations produce content-free `linkObservation` errors without exception text, paths or targets (`design.md:165`). Link/file/directory transitions are changed entries (`design.md:166`), and protected-name links remain protected (`design.md:169`).

`tasks.md:433-438` explicitly requires separate owned real Windows junction and symlink fixtures through the real acquisition operation, injected failures, unsupported kinds, unstable re-observation, transitions, protected-name links and non-Windows refusal. It expressly rejects comparison-only injected tests as acquisition coverage. `tasks.md:424-425,439-441` adds output/privacy assertions and helper error-category handling. The normative incomplete outcomes appear in `specs/agent-tool-access/spec.md:115`.

### Required Change 3 — Applied

`specs/agent-tool-access/spec.md:92` now admits exact owner-approved v1 and v2 manifests with selection-specific metadata bounds and link handling. `specs/agent-tool-access/spec.md:108-110` states both entry ceilings and explicitly applies baseline refusal, consumed-attempt INCOMPLETE receipts, baseline counters and no-provider/no-content-scan indicators to both wider modes.

The narrowly scoped supported unchanged-link exception is specified at `specs/agent-tool-access/spec.md:114-116`. That text preserves v1/legacy behavior and scanner file/byte limits. `design.md:169` carries v2 through binding, baseline preflight and receipt obligations; `design.md:447` reconciles the resource-bound table with the selection-specific entry and storage budgets. Scenario-map rows remain red for the amended refusal scenario and new normal-home scenario (`tasks.md:87-88`), with v2 baseline/receipt tests required at `tasks.md:428`.

### Suggestion S1 — Applied

`design.md:167` precisely excludes coverage through the link traversal route while preserving inventory coverage through an ordinary native-home path. It also explicitly limits equality to the two observation times and discloses that a temporary retarget restored between them is undetected.

The same disclosure addresses concurrent writers and the owner’s pause of other Codex sessions (`design.md:167`). Canonical v2 disclosure validation remains required (`design.md:169`; `specs/agent-tool-access/spec.md:116`). `tasks.md:439-441` requires both receipts and canonical disclosure to carry the fixed detector limits without target text or arbitrary names.

No new inconsistency was identified in the amended planning text. These findings establish that the requested artifact edits are applied; they do not establish implementation or passing tests.

CHANGES_APPLIED: yes

## Rebuttals