# Review

## Metadata

- **Round:** 5. Full design review of the owner-approved qualification audit budget amendment (2026-11-11). It covers the D5 "Qualification audit budget" paragraph (`design.md:141`), the "Qualification audit budget amendment" task paragraph (`tasks.md:242-270`), the expanded privacy map row (`tasks.md:82`) and the planned-amendment record (`docs/qualification/codex-app-server.md:347-371`). (Line references in Findings and Required Changes are as of the original Round 5 pass; the focused recheck below uses current lines.)
- **Prior round:** Round 4 returned APPROVE_WITH_CHANGES for the ordinary-command approval clarification. Its focused recheck verified RC1 as applied, verified RC2's boundary as applied and accepted the rebuttal of RC2's owner-decision gate (CHANGES_APPLIED: yes). That verdict is void for the amended design until this round completes.
- **Reviewer:** Fresh-context subagent (Claude Code agent, `claude-opus-5-5`). Read-only, using file tools only, with no shell. I could not reach the scratch-folder comparison files (`audit-budget-before-design.md`, `audit-budget-before-tasks.md`, `audit-budget-prior-review.md`) because the file tools are confined to the repository. I compared against the Round 4 `review.md` in the change folder and the current source instead. I did not need the dart-add-unit-test or dart-build-cli-app skills, and no finding depends on them.
- **Reviewed:**
  - **Rules:** `AGENTS.md`.
  - **Change artifacts:**
    - `proposal.md`, `design.md` (in full), `tasks.md` (in full) and `review.md` (Round 4).
    - `specs/agent-tool-access/spec.md` in full.
    - The other five delta specs, searched for scan, canary and MiB wording. There were no matches.
  - **Decision and qualification records:**
    - `docs/adr/0015-native-codex-app-server-and-child-identity.md`: status and Decision 8.
    - `openspec/architecture.md`: canary and bound wording.
    - `docs/qualification/codex-app-server.md:300-371` and `:700-808`.
  - **Source:**
    - `agent_service.dart:380-567`
    - `codex/native_home_audit.dart` (all)
    - `test_hooks/test_hooks.dart:20-60, 130-250`
    - `tool/qualify_codex_app_server.dart:1-135, 355-420, 630-1081`
    - `host_protocol/lib/src/messages.dart:1783-1787` (`EmptyParams`)
    - `tools/tool_service.dart:78, 318` (secret format)
  - **Tests:**
    - `tool/test/qualify_codex_app_server_test.dart`: test index, `:437-510`, `:621-657`
    - `packages/host/test/it/codex_tools_test.dart:20-130`
    - `packages/host/test/it/release_contract_test.dart:40-100`
    - `packages/host/test/agent/native_home_audit_test.dart` (by search)
  - **Planned files:** `tool_file_audit.dart` and `tool_file_audit_test.dart` do not exist yet, as expected.
- **Not done:** no SDK commands, builds or tests, no native runtime or provider calls, no native-home reads, no auth experiments, no tracker or GitHub writes and no commits.
- **Focused recheck (Round 5, 2026-11-11):** same reviewer configuration, read-only file tools, no shell.
  - **Artifacts read:**
    - `design.md:141-147` (D5 audit subsection) and `:394-425` (Resource Bounds, including the new test-only row at `:425`).
    - `tasks.md:82` (privacy map row), `:184-186` (8.2 and its note) and `:244-301` (audit amendment).
    - `codex-app-server.md:347-403` (planned opt-in amendment).
    - `proposal.md`, searched for audit/MiB wording. It has no budget wording, which is acceptable for a test-only bound.
  - **Source read for coherence:**
    - `test_hooks.dart:159-165, 230-238`
    - `qualify_codex_app_server.dart:65-71, 575-594, 855-879`
    - `codex_tools_test.dart:25-124`
    - Prepare call sites, found by search.
  - **Scratch baselines:** still unreachable. No comparison evidence against them is claimed.
  - **Coordinator checks:** strict validation, diff check, checkbox and scenario counts, and source hashes were reported by the coordinator but not re-run by me (no shell). From the files, I confirmed that row `:82` is still red, that 8.3 and 8.4 are still open and that no `tool_file_audit*.dart` exists.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

**The checkpoint matches the artifacts:**
- **Map:** 131 rows (`tasks.md:9-139`). Row `:82` (expanded privacy coverage) and row `:119` (real Windows evidence) are red; the other 129 are green.
- **Checkboxes:** 22, of which 20 are ticked. 8.3 and 8.4 are open.
- **Windows section:** still INCOMPLETE (`codex-app-server.md:792-807`). The fourth attempt is recorded honestly as 29 files, 20,170,523 bytes, 0 subset matches and 11 errors, marked incomplete (`:753-763`). The later metadata-only finding (69,947,392 and 136,392,704 bytes) is described as a current obstacle, not the full cause of the 11 errors (`:765-772`).
- **Current scanner is still at the defaults:** `agent_service.dart:462-463` hardcodes 16/32 MiB and reads each whole file plus one byte into memory, then decodes it (`:518-529`). The new coverage is correctly prospective.

**Round 4 items remain coherent:**
- D4 Interactions and the clarification are intact (`design.md:119-121`).
- The approval and file-change boundary paragraphs are intact (`tasks.md:221-240`).
- The command row is now green, which the evidence record reports at `codex-app-server.md:718-723`.

**The amendment's direction is sound:**
- One closed preset, with the default unchanged.
- The preset is bound in a manifest that is validated before the claim.
- The preset is test-only.
- Reservation-based charging.
- Matches dominate incompleteness.
- No new exclusions or credential reads.
- No consumed approval can be reused.

The defects below are binding and accounting gaps that would let an implementation meet the paragraph's wording while breaking its intent.

### Critical (blocking)

None.

### Moderate

**M1. "Profile" collides with an existing manifest key, so the legacy rule and the binding rule cannot be implemented as written.**

- **The collision:** every schema-2 manifest already has a top-level `profile` key that holds the Kumiko host profile directory path (`qualify_codex_app_server.dart:34`, `:641`). The walk uses it as the host profile directory (`:859`) and as a scan root (`:66`, `:997`).
- **The three statements this breaks:**
  - D5 says "Existing schema-2 manifests without a profile remain valid only with the original default limits" (`design.md:141`).
  - The task paragraph tests "legacy schema-2 defaults" (`tasks.md:252`).
  - The qualification record says "Legacy schema-2 manifests without a profile" (`codex-app-server.md:357`).
- **Consequences of a literal implementation:**
  - Absence of `profile` never occurs, so the legacy branch is dead code.
  - Validating `plan['profile']` as a budget preset name rejects every legacy manifest.
  - Writing the preset name into `profile` would make `_WalkHost.open` use a relative directory named `large-native-home` as the host profile, and would add that directory as a scan root. That breaks root confinement and the declared-root consistency check.
- **Fix:** the field needs a distinct name and location. See RC1.

**M2. The host's effective budget is neither bound nor reported, so a manifest and host mismatch is silent.**

- **Where binding stops today:** D5 binds the preset in the manifest and says only "Pass only the selected known profile through the test entrypoint".
- **Why a mismatch would go unnoticed:**
  - `test/codex.audit.prepare` parses `EmptyParams.fromJson`, which ignores every key (`messages.dart:1785`).
  - `test/agent.stats` ignores unknown keys as well (`test_hooks.dart:231-249`).
  - The scan result carries no limits (`agent_service.dart:543-549`).
- **Consequence:** if the helper and host disagree (a stale test-host build, a typo in the parameter name, or a fixture that forgets to pass it), the host silently scans at the default while `observations.json` sits beside a manifest that declares 256/512 MiB. The audit result would be read against the wrong limits.
- **Two further gaps:**
  - Nothing says where the host learns the preset: an environment variable, a prepare parameter, or a per-scan parameter. A per-scan parameter would let each `test/agent.stats` call pick its own budget, separately from the native-home preparation.
  - Nothing forbids a walk-time CLI override. Today `--walk` accepts only `--manifest` and `--approved-sha256` (`:1076-1078`). The design should keep it that way explicitly.

**M3. The chunk size and end-of-file confirmation are unspecified, and the present size+1 growth probe conflicts with "exact-boundary completion is valid".**

- **The conflict:**
  - Today growth is detected by requesting `before.size + 1` bytes (`agent_service.dart:518`).
  - Under reserve-before-I/O, the final probe byte for a file of exactly 256 MiB, or one that exactly exhausts 512 MiB, cannot be reserved without exceeding the limit.
  - An implementation must then either exceed the budget, which violates "reserve before I/O", or mark exact-boundary completion incomplete, which violates D5.
- **Missing numbers:**
  - "Bounded chunks" has no number, so "bounded memory" is not testable.
  - The Resource Bounds table (`design.md:396-417`) has no row for this scanner.
- **Unpinned behaviour:** the design does not say whether a file whose pre-read size exceeds the per-file limit, or the remaining aggregate allowance, is skipped before reading (today's behaviour, which saves budget) or read up to the allowance (which observes more bytes for matches). The two choices give different `chargedBytes`. A test "exact boundary/oversize cases" cannot have one pass condition until this is decided.

**M4. Match retention inside a file that later fails is ambiguous, and today's code drops it.**

- **What the design says:** "Any observed canary match remains a failure even if another audit condition is incomplete."
- **What the code does:** it checks for a match only after the stability check passes (`agent_service.dart:520-530`), so a canary in a file that grows during the read is never counted.
- **Why chunking makes this sharper:** with chunked scanning, a match is observed before stability is known. The design must state that it is counted in `matchedFiles` whatever happens to the file afterwards, including:
  - instability;
  - a later read failure;
  - running out of budget mid-file.
- **The other half of chunk-boundary correctness:** the overlap carry must reset at each file, so that a canary prefix at the end of one file and its suffix at the start of the next is not a match. The task list includes neither case.

**M5. "Links ... keep the audit incomplete" contradicts current traversal of the workspace and profile roots, and no test is planned.**

- **Native-home roots:** links are counted as errors (`native_home_audit.dart:27-30`).
- **Workspace and profile roots:** `Directory.list(recursive: true, followLinks: false)` yields `Link` entities, and `if (entity is! File ...) continue;` (`agent_service.dart:491-492`) skips them silently. That includes Windows junctions and symlinks a run may create.
- **Consequence:** D5 now promises behaviour the implementation does not have, and the planned test list (`tasks.md:250-255`) never checks it. A "complete" result could still hide a skipped link.

**M6. Required failure paths cannot be produced on real files, so they need an injectable I/O seam.**

- **What is required:** "Reserve before I/O; a failed read with unknown count keeps the reservation" and "unstable files still consume the budget".
- **Why real files are not enough:**
  - A mid-file `RandomAccessFile.read` throw cannot be reproduced reliably with real files on Windows, Linux and macOS.
  - Cross-chunk matching under short reads (fewer bytes than requested before end of file) cannot be reproduced reliably either.
- **What the tasks require:** only "coordinator-owned synthetic files".
- **Consequence:** without a seam, the red-first tests for these clauses either cannot be written or degrade into tests that pass trivially. A seam would be an internal stat/open/read interface in `tool_file_audit.dart` that tests can inject but no RPC can reach.

### Suggestions

- **S1. Map row test names.** Row `:82` names `Codex audit budget:` and `Codex audit manifest:` as prefixes. That lets any subset of tests turn the row green. Either list the concrete test names, or state that every test with each prefix must pass and that the cases listed in `tasks.md:250-255` (plus RC3–RC6) each exist.
- **S2. Release contract.** Extend `release_contract_test.dart:64-70` so the release host is started with any new preset environment variable set. Also send `test/codex.audit.prepare` with the preset parameter and `test/agent.stats` with a budget key. All three must still return `methodNotAvailable`, and hello must advertise no new capability.
- **S3. Preparation user experience and the explicit/default rule.**
  - The qualification record says "Preparation will require explicit profile selection" (`codex-app-server.md:353`), while D5 keeps the default when nothing is chosen. Reconcile them: either omitting the option records `default` explicitly, or the option is mandatory.
  - Validate the option before `_prepare` creates the workspace (`:633-637`).
  - Print the preset and its exact limits next to the SHA-256 (`:695-700`), so the owner approves the limits knowingly.
- **S4. Behaviour after the budget is exhausted.**
  - Today, once `scannedBytes >= totalBound` the root loop breaks (`:493-496`), before checking whether the next file is empty.
  - Instead, continue enumerating metadata only, and classify as outstanding only files with a nonzero or unknown size. A stable empty file is not outstanding bytes.
  - Pin this down with a test.
- **S5. Scope and resource honesty.**
  - Add a test-only Resource Bounds row: chunk size, peak memory, per-call aggregate, the 4096-file cap and the four-root cap.
  - Note that `Connection.request` has no deadline (`connection.dart:232`), so a 512 MiB scan is bounded only by bytes, not time.
  - State that the budget applies per `test/agent.stats` call.
- **S6. Evidence interpretation.**
  - The canary is 43-character ASCII base64url (`tool_service.dart:78, 318`), and matching is on raw UTF-8 bytes. UTF-16 or otherwise re-encoded copies are not detected. Say so, so that "0 matches" is not over-read.
  - The scanned native home is the user's shared `~/.codex`. Concurrent writes by other Codex instances will legitimately show up as instability, not as a fault in the scanner.
  - A later approval should state that complete root history/state contents are read into memory (never printed) up to the larger limits.
- **S7. Use the manifest's roots directly.** The walk passes roots rebuilt from `workspace`, `profile` and `nativeHome` (`:995-999`), not `scan.roots`. After validating that the two agree, pass the validated `scan.roots` list itself, so the declared and used roots cannot diverge.
- **S8. Task 8.2 bookkeeping.** Task 8.2 stays ticked while two amendments require it to be reverified. That matches the Round 4 precedent, but a one-line note under 8.2 ("reverification pending after the audit-budget implementation") would stop a reader treating it as current.

## Focused Recheck (Round 5)

The author's correction trace was verified against the artifact text, not taken on trust. All six Required Changes are applied. Where the wording differs from the RC text, the difference keeps or narrows the requirement.

**RC1 (M1): applied.**
- **`design.md:143`:**
  - Preparation records `scan.auditProfile` (`default` or `large-native-home`), the exact `scan.maxFiles`, `scan.maxFileBytes` and `scan.maxTotalBytes`, and `scan.roots`.
  - The top-level `profile` key "remains the Kumiko host profile directory, never a budget name".
  - A schema-2 manifest without `scan.auditProfile` is legacy and "accepts only the original default numbers".
- **`tasks.md:252-258`** carries the same rule and adds the test "legacy schema-2 without scan.auditProfile (default numbers only, top-level profile unchanged)".
- **`codex-app-server.md:357-360`** matches.
- **Against current source:**
  - Current manifests already carry `scan.maxFiles`, `scan.maxFileBytes` and `scan.maxTotalBytes` at the default values (`qualify_codex_app_server.dart:65-71`), so the legacy rule can be satisfied by every existing manifest.
  - S3 is folded in: omitting `--audit-profile` records `default`, the option is validated before artifacts are created, and the limits are printed beside the hash. This removes the earlier "explicit profile selection" contradiction.
  - `--walk` accepts no budget option, with a test for rejection before the claim.

**RC2 (M2): applied, in a narrower form.**
- **`design.md:144`:**
  - Binding happens only through `test/codex.audit.prepare`, once, before any agent run or scan. Unknown, late and repeated bindings are refused.
  - Legacy unprepared fixture scans stay on the immutable default.
  - `test/agent.stats` must reject preset, numeric-limit and override keys rather than ignore them.
  - The preparation echo is validated before agent startup or content I/O, and every scan repeats the echo.
  - A mismatched or missing field makes the audit incomplete and the tool call unverified, while a match is preserved as a failure.
- **Dropping the environment path:** the RC allowed "prepare or the test-host environment". Choosing prepare-only removes one binding path and is acceptable.
- **Against current source:**
  - Each host process calls prepare exactly once: the preparation host at `qualify_codex_app_server.dart:586` and the separate walk host at `:870`.
  - Fixtures do the same (`codex_tools_test.dart:32, 109`).
  - "Repeated preparation refused" is therefore compatible with existing callers, read as once per host process.
- **Tasks and record:**
  - `tasks.md:260-265` add host rejection, the echo tests, the helper mismatch rule and the `--walk` refusal.
  - The release-capability rejection under budget inputs (S2) appears at `design.md:144` and `tasks.md:290-292`.

**RC3 (M3): applied.**
- **`design.md:145`:**
  - Chunks are at most 1 MiB, plus a carry of canary length − 1.
  - Peak storage is one chunk plus the carry plus constant state.
  - Each request is at most min(chunk, remaining per-file allowance, remaining aggregate allowance).
  - EOF is confirmed by unchanged post-read metadata plus a zero-byte read, but only when allowance remains, so exact-boundary completion needs no probe beyond the limit.
  - A file whose pre-read size exceeds the per-file maximum is unread and incomplete.
  - Aggregate overflow is read only to the remaining allowance and is incomplete for its outstanding bytes.
- **Resource Bounds:** a test-only row exists at `design.md:425` with these values, the 4096-file and four-root caps, byte-only bounds and no scan deadline.
- **Tests:** `tasks.md:266-271` add the request-bound, exact-256 MiB, exact-aggregate and pre-read-oversize cases.
- **Fold-ins with no contradiction:**
  - S4: after exhaustion, metadata enumeration stays bounded, stable empty files are counted without reads, and nonempty or unknown-size files are outstanding.
  - S5: per-call byte budget, one scan per walk with no retry, no deadline.

**RC4 (M4): applied.**
- **`design.md:146`:**
  - A match in any chunk counts in `matchedFiles` even if the file later changes, throws or runs out of allowance.
  - The carry resets at each file, so a prefix and suffix in different files do not match.
- **Tests:** `tasks.md:272-275` test every split offset 1..length−1 across a chunk boundary, one-byte short reads, retention after growth, failure or exhaustion, and the cross-file non-match.
- **`codex-app-server.md:388-390`** matches.
- **S6 fold-in:** the record now states the UTF-8-only detection limit and the shared-home concurrency caveat.

**RC5 (M5): applied with a clarification, which I accept.**
- **`design.md:146` and `tasks.md:275-277`:** any link, junction or other non-regular leaf entry in any root, including workspace and profile, adds an error and is never followed. Ordinary directories are metadata-only traversal containers.
- **Why I accept it:**
  - The RC's wording ("a link or other non-regular entry") was broader than M5 intended. Read literally, every root with subdirectories would be permanently incomplete, which would make the audit unusable without detecting anything more.
  - The clarification keeps M5's purpose: no silently skipped link or special file, and no link-following.
  - It excludes no file bytes, because directories are traversed and their regular files are scanned under the same budget.
- **Implementer note (non-blocking):** the error classification must not depend on `Directory.list` type alone in ways that let a Windows junction be reported as a `Directory`. The "junction" wording and the planned workspace/profile link test cover this as stated.

**RC6 (M6): applied.**
- **`tasks.md:283-288`:**
  - `tool_file_audit.dart` has an injectable stat/open/read interface, used only by `tool_file_audit_test.dart` and unreachable through RPC.
  - Throw-after-reservation is tested deterministically, keeping the full charge with `chargedBytes > readBytes`, as are short reads and post-read instability.
  - The invariant `scannedBytes <= readBytes <= chargedBytes <= maxTotalBytes` is asserted in every case.
- `design.md:147` and `codex-app-server.md:396-397` match.

**Other fold-ins checked for contradictions: none found.**
- **S1:** every test with the `Codex audit budget:` or `Codex audit manifest:` prefix must exist and pass, and a passing subset cannot turn row `:82` green (`tasks.md:292-294`).
- **S7:** the validated `scan.roots` list is used directly (`design.md:143`, `tasks.md:258`).
- **S8:** the pending note sits under 8.2 (`tasks.md:186`), and the amendment repeats the reverification list (`:295-297`).
- **Authorization scope:** preparation, review and fixture tests authorize no native content scan, provider walk, auth isolation or tracker write. A later walk needs fresh approval of the exact manifest stating the larger limits and chunked content reads. Consumed approvals are not reusable. This is consistent across all three artifacts.
- **Unchanged items:** the four consumed attempts and the INCOMPLETE section are stated as unchanged.

**Residual non-blocking notes for implementation:**
- **N1. Map row file list.** Row `tasks.md:82` lists `codex_tools_test.dart`, `tool_file_audit_test.dart` and `qualify_codex_app_server_test.dart`, but not `release_contract_test.dart`, which the task paragraph requires extending. Either add it to the row or rely on its existing release row; state which when the row turns green.
- **N2. Sentence at `tasks.md:288-289`.** "Also cover test_hooks.dart and the qualification helper in the named new tool_file_audit_test.dart, retained Codex tool/release tests and helper tests" reads as if helper coverage lives in `tool_file_audit_test.dart`. The intended split appears to be: scanner in `tool_file_audit_test.dart`, hooks in the Codex tool and release tests, helper in `qualify_codex_app_server_test.dart`.
- **N3. Per-file allowance.** Implement "remaining per-file allowance" as `maxFileBytes` minus the bytes reserved for that file, not the pre-read size. Growth past the stat size is then read only within the allowance and caught as instability by the post-read metadata check. Either reading is consistent with D5.
- **N4. Rejecting override keys.** The simplest testable form of "`test/agent.stats` rejects … budget overrides" is a closed key allowlist (`secretScanRoots`, `secretScanSessionId`) that rejects any other key, rather than a denylist of budget-like names.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Rename the preset field (M1).**
   - **`design.md:141`:**
     - Replace "Preparation records the selected profile and exact limits in the manifest." with:
       > "Preparation records the selected preset as `scan.auditProfile` (`default` or `large-native-home`) together with exact `scan.maxFiles`, `scan.maxFileBytes`, `scan.maxTotalBytes` and `scan.roots`; the existing top-level `profile` key remains the Kumiko host profile directory and is never a budget name."
     - Replace "Existing schema-2 manifests without a profile remain valid only with the original default limits." with:
       > "A schema-2 manifest without `scan.auditProfile` is legacy and is valid only when its scan numbers equal the original defaults."
   - **`tasks.md:252`:** replace "legacy schema-2 defaults" with:
     > "legacy schema-2 manifests without `scan.auditProfile` (defaults only; the host-profile `profile` key unchanged and never parsed as a preset)"
   - **`codex-app-server.md:357`:** replace "without a profile" with "without `scan.auditProfile`".

2. **Bind the budget in the host and echo it (M2).** Append to the D5 paragraph (`design.md:141`):
   > "The test entrypoint binds the preset once, through `test/codex.audit.prepare` or the test-host environment, before any run. The host rejects unknown names, and `test/agent.stats` accepts no preset, numeric limit or override. Every scan result reports `auditProfile`, `maxFiles`, `maxFileBytes` and `maxTotalBytes`. The helper compares them with the approved manifest: any mismatch or missing field marks the audit incomplete and `kumiko tool call` unverified, while a match is still a failure. `--walk` accepts no budget option; the preset comes only from the approved manifest."

   Add to the task list (`tasks.md:250-255`):
   > "host rejection of unknown presets; result echo of effective limits; helper mismatch treated as incomplete; `--walk` refusing a budget option before the claim"

3. **Specify chunks, end of file and oversize (M3).** Append to D5:
   > "Reads use chunks of at most 1 MiB, plus a carry of canary length − 1 bytes; peak scanner memory is one chunk plus the carry. Each request is the minimum of the chunk size, the file's remaining allowance and the aggregate remaining allowance. End of file is confirmed by unchanged post-read metadata, and, only when allowance remains, a zero-byte read. A file whose stable bytes exactly reach either limit completes without a probe read beyond the limit. A file whose pre-read size exceeds the per-file limit is not read and is incomplete. A file larger than the remaining aggregate allowance is read up to that allowance and is incomplete for its outstanding bytes."

   Add a test-only row to Resource Bounds with these values. Add to the task test list:
   > "maximum request size is never exceeded; a file exactly at 256 MiB and at the aggregate limit completes; pre-read oversize is unread and incomplete"

4. **Retain matches and reset the carry (M4).** Append to D5:
   > "A match observed in any chunk counts in `matchedFiles` even when the same file later changes, fails or runs out of allowance. The overlap carry resets for each file."

   Add to the task test list:
   > "a canary straddling every split offset 1..length−1 across a chunk boundary and under one-byte short reads; a match in a file that then grows still fails; a prefix and suffix split across two files does not match"

5. **Make links visible (M5).** Append to D5:
   > "In every root, a link or other non-regular entry found during traversal adds an error and is never followed."

   Add to the task test list:
   > "a link in the workspace or profile root makes the audit incomplete"

6. **Add a fault seam (M6).** Append to the task paragraph after "focused internal tool_file_audit.dart module":
   > "with an injectable stat/open/read interface, used only by `tool_file_audit_test.dart` and not reachable through any RPC, so that throw-after-reservation (full reservation kept, `chargedBytes > readBytes`), short reads and post-read instability are tested deterministically. Assert `scannedBytes <= readBytes <= chargedBytes <= maxTotalBytes` in every case."

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

<!-- Author: fixed (cite) or rebutted (reason) per finding. A Critical/Moderate rebuttal counts only once marked "accepted by reviewer". -->

- **M1:** fixed (`design.md:143`; `tasks.md:252-258`; `codex-app-server.md:355-363`).
- **M2:** fixed. Binding is prepare-only, narrower than the RC's "or environment" (`design.md:144`; `tasks.md:260-265`; `codex-app-server.md:365-373`).
- **M3:** fixed (`design.md:145`, `:425`; `tasks.md:266-272`; `codex-app-server.md:375-386`).
- **M4:** fixed (`design.md:146`; `tasks.md:272-275`; `codex-app-server.md:388-390`).
- **M5:** fixed with a clarification: ordinary directories are metadata-only traversal containers, and links, junctions and non-regular leaf entries in every root are errors and never followed (`design.md:146`; `tasks.md:275-277`; `codex-app-server.md:391-392`). The clarification was accepted by the reviewer in the Round 5 focused recheck.
- **M6:** fixed (`design.md:147`; `tasks.md:283-288`; `codex-app-server.md:396-397`).
