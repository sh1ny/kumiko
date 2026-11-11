# Review

## Metadata

- **Round:** 6
- **Prior round:** Round 5 (a full review of the D5 qualification audit budget) returned APPROVE_WITH_CHANGES. Its focused recheck set CHANGES_APPLIED to yes. This round reviews the attempt-6 planning amendment: the D4 complete decision display and the helper's answer fence, plus the D5 explicit native coverage, changed-artifact selection and protected-data paragraphs. That amendment voided the earlier verdict.
- **Reviewer:** Cross-model CLI route (Claude Code, `claude-opus-5-5`). I used read-only repository file tools only, with no shell, SDK, build, test, native, provider, Git or tracker operations. I did not read the authoring conversation. The installed skills dart-add-unit-test, dart-build-cli-app, dart-use-path-package and flutter-add-widget-test were not needed: no finding depends on them.
- **Reviewed:**
  - **Rules:** `AGENTS.md`
  - **Change artifacts:**
    - `proposal.md`, `design.md`, `tasks.md` and `review.md` (Round 5), all in full.
    - `specs/codex-sessions/spec.md` and `specs/agent-tool-access/spec.md` in full.
    - The other four delta specs, through the map rows only.
  - **ADRs:**
    - `docs/adr/0015-native-codex-app-server-and-child-identity.md:30-79`
    - `docs/adr/0002-versioned-desktop-host-protocol.md`, by search for bounds and additive evolution.
  - **Qualification evidence:**
    - `docs/qualification/codex-app-server.md:880-987`
    - `docs/qualification/codex-app-server-windows-attempt-6-2026-11-11.json`
  - **Source:**
    - `packages/host/lib/src/agent/runtime_driver.dart:1927-2214`
    - `packages/host/lib/src/agent/agent_session.dart:745-850`
    - `packages/host/lib/src/agent/agent_service.dart:505-590`
    - `packages/host/lib/src/agent/codex/native_home_audit.dart` (all)
    - `packages/host/lib/src/test_hooks/test_hooks.dart:159-175, 240-250`
    - `packages/host_protocol/lib/src/messages.dart:1778-1780, 2346-2410`
    - `packages/desktop/lib/src/agent/agent_pane_view.dart:506-571`, plus a search of `packages/desktop/lib/src/agent/` for option-kind use.
    - `tool/qualify_codex_app_server.dart:125-235, 700-830, 860-910, 1025-1085`
  - **Tests:** the existing host, desktop and helper tests were located through the six red map rows (`tasks.md:85-87, 102-103, 123`). I did not run any of them, and their prior results are not treated as verification of the new behaviour.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

**The evidence matches the artifacts:**
- **Display loss:** the attempt-6 receipt records `namesLoss` true with `maxNameBytes` 406, a 580-byte preview, three options and no other loss flags.
- **Its cause:** `runtime_driver.dart:2089` serializes object decisions into option labels, `messages.dart:2382` clamps them to 256 bytes, and `agent_session.dart:787` cancels on the resulting fidelity loss. D4's diagnosis is correct.
- **Audit errors:** the receipt's two native errors are one `changedUnknownFile` (`modelCache`) and one `changedUnknownDirectory` (`otherDirectory`). Both come from `native_home_audit.dart:171-192`, which turns any change outside `sessions/log/logs/state` into an error. D5's diagnosis is correct.
- **Unchanged state:**
  - Six rows are red: `tasks.md:85-87, 102-103, 123`.
  - Tasks 8.3 and 8.4 are open.
  - The Windows section is still INCOMPLETE (`codex-app-server.md:971-986`).
  - No consumed approval is reused.
  - No cap is raised.
  - No ADR conflict found: ADR 0015 decisions 5 and 8 cover preserving choices and the canary scan, and test-only audit selection needs no new ADR.

**The direction is sound:**
- Display is separate from response: opaque tokens keep the exact native values, and the display copy is redacted.
- The fidelity guard is unchanged, so oversized content still cancels.
- The helper fence never selects by index or by kind.
- Coverage is opt-in, manifest-bound and closed to two values, and legacy stays the default.
- A match always counts, protected files are never read, and the baseline is a preflight.

The defects below would let the named regression rows turn green while the amendment's own guarantees (complete display, no implied scope, an honest coverage claim and disclosed scope) fail.

### Critical (blocking)

None.

### Moderate

**M1. The desktop renderer hides parts of approval previews, so "complete display" is not established.**

- **What the code does:**
  - Permission previews go through `AgentPlainText` (`agent_pane_view.dart:515`).
  - That widget splits on triple backticks, drops the backtick markers themselves, and inside each odd segment drops everything up to the first newline, treating it as a fence language tag (`:555-566`).
- **Consequence for previews that already exist:** a command preview containing triple backticks loses visible bytes on the desktop. One example is a model-generated heredoc that writes Markdown into a file. The host's fidelity guard (`agent_session.dart:787`) checks only host-side clamping, so this loss is never detected.
- **Why the amendment makes it worse:** D4 now appends the full JSON decision array to the same preview (`design.md:123`) and claims that "native strings/objects remain data, never rendered markup". A policy-amendment object normally repeats the command tokens, so the same fence handling can hide part of the scope being approved.
- **Why the map would not catch it:** the desktop `Codex decision display:` row (`tasks.md:102`, `:333-340`) would pass with any fixture that has no backticks, while real approvals can still hide scope.

**M2. Object decisions keep the `allow_once` kind, which contradicts "labels do not imply one-shot or persistent scope".**

- **Today's mapping:** any decision other than `acceptForSession`, `decline` or `cancel` is `allow_once` (`runtime_driver.dart:2090-2094`). That includes JSON objects such as policy or session amendments.
- **What the design leaves unsaid:** D4 changes only labels (`design.md:123`) and does not specify `kind` for object entries.
- **Consequence:**
  - The protocol DTO (`messages.dart:2346-2360`, which carries `kind` verbatim) advertises a persistent policy-amending choice as one-shot.
  - The helper's diagnostic already reasons over `kind` (`qualify_codex_app_server.dart:219-221`).
  - The spec's claim that nothing implies scope or a grant (`codex-sessions/spec.md:105`) cannot be asserted while `kind` asserts it.
- **Not affected:** the helper's answer rule, which requires the literal name `accept`.

**M3. A failed baseline preflight consumes the approved manifest, and the plan does not say so.**

- **Validation before the claim:** D5 makes value validation fail "before attempt claim" (`design.md:153`).
- **The baseline comes after the claim:**
  - The baseline is produced by `test/codex.audit.prepare` inside the walk host.
  - The walk host opens after the durable claim (`qualify_codex_app_server.dart:902-904` runs before `:1036-1054`).
  - So an incomplete baseline (`design.md:155`, `agent-tool-access/spec.md:110`) aborts after the approval is consumed and after the real native-home metadata has been read.
- **Why it matters:** the design itself expects that "a large shared home may legitimately fail this preflight". Each such failure burns an owner approval. Nothing defines what the receipt records: the category counters, no provider work, and an INCOMPLETE status.
- **Why the map would not catch it:** the refusal row (`tasks.md:87`) can pass without asserting the claim-state or receipt behaviour.

**M4. Excluding files because their metadata is unchanged is a form of exclusion, but the design forbids exclusion and leaves the always-scan set at legacy depth.**

- **The contradiction:**
  - D5 says "unknown entries become accounted for only by complete inventories and stable selected reads, never by exclusion" (`design.md:157`).
  - The same design skips unchanged ordinary files elsewhere because their type, size, mtime and ctime are equal (`design.md:155`).
- **Why legacy always-scans some files:** it scans mutable SQLite, WAL and SHM files regardless of metadata, because metadata equality is not trusted for them. It does so only at the top level or under known directories (`native_home_audit.dart:155-166`).
- **Gap under changed-artifacts-v1:** an SQLite, `-wal` or `-shm` file inside a formerly unclassified directory is excluded whenever its metadata compares equal. SHM files are written through memory mappings, and on Windows mapped-view writes are not guaranteed to update the last-write time.
- **Consequence:**
  - A secret written there produces `complete` with zero matches, which is exactly the false-clean outcome this mode exists to prevent.
  - The "unchanged-file exclusion" test (`tasks.md:350`) would enshrine that outcome.

**M5. The wider content scope is disclosed only by prose, the protected set is narrower than the current invariant, and the spec's precondition cannot be asserted.**

- **The current invariant:** "Credentials and configuration are never read" (`native_home_audit.dart:7-9`).
- **The new rule:** changed-artifacts-v1 protects only two literal basenames (`design.md:157`) and reads every other changed regular file. The design cites no inventory of 0.166.0's other credential- or configuration-bearing files.
- **How disclosure is handled:** the design delegates disclosure to "the later exact-manifest approval", but makes neither preparation nor the helper print that disclosure. Today preparation prints only limits and a hash (Round 5 RC1 and S3).
- **Assertability:** the spec's WHEN clause, "the separately approved exact manifest discloses wider private-content reads" (`agent-tool-access/spec.md:97`), is a human act that no named test (`tasks.md:85`) can assert.
- **Consequence:** an owner can approve a changed-artifacts-v1 manifest hash without the tool stating that any other credential store would be read into host memory.

### Suggestions

- **S1. Name collisions.**
  - A well-formed native string decision kept verbatim could equal a generated label such as `Native option 2`. That gives two identical buttons with different tokens.
  - Either refuse a list in which a string name equals a generated label (bounded notice and cancel, as for overflow), or mark generated labels so they cannot collide with string names.
- **S2. Invisible or reordering characters.**
  - `jsonEncode` escapes control characters below U+0020 but leaves bidirectional overrides (such as U+202E) and U+2028/U+2029 untouched. The raw `Command:` and `Reason:` lines (`runtime_driver.dart:1995`) are not escaped at all.
  - A model-crafted command can visually reorder what the desktop shows, both in the approval preview and in the appended JSON line.
  - Consider escaping these characters in permission previews and testing it under `Codex decision display:`.
- **S3. Host-side baseline gate.** Only the helper refuses an incomplete changed-artifacts-v1 baseline. For defence in depth, the test host could also refuse `agent/start` after an incomplete wider-mode preparation, so a future caller cannot skip the check.
- **S4. Iterative traversal.** Today's `_metadata` recurses (`native_home_audit.dart:60-93`). The planned test for "no growing pending queue" (`tasks.md:367-368`) should run through an injected lister that reports the maximum pending depth, so the iterative-traversal claim is actually observed.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Show previews as plain data (M1).**
   - **`design.md:123`:** after "native strings/objects remain data, never rendered markup.", add:
     > "The desktop renders permission titles, previews and option names as plain selectable text with no fence or markup interpretation; no displayed byte is dropped or reinterpreted."
   - **`tasks.md`, desktop Codex decision display paragraph (`:337-340`):** add:
     > "include a command and an object decision containing triple backticks and newlines, and assert that the complete preview text appears unchanged."

2. **Give object decisions a conservative kind (M2).** In `design.md:123`, after "Labels do not imply one-shot or persistent scope.", add:
   > "JSON-object decisions are published with kind `allow_always` (the conservative persistent-scope kind), never `allow_once`. String decisions keep their existing kind mapping. Tests assert the kind of every object entry."

   Add the same assertion to the `Codex decision display:` cases in `tasks.md:330-334`.

3. **Define what happens when the baseline fails after the claim (M3).**
   - **`design.md:155`:** after "otherwise aborts before provider work without falling back to legacy", add:
     > "This preflight runs after the durable attempt claim. An incomplete baseline consumes that approval, starts no App Server, prompt or provider work, and records an INCOMPLETE receipt with the content-free baseline counters; a further attempt needs a fresh exact-manifest approval."
   - **`specs/agent-tool-access/spec.md:110`:** extend the AND clause with:
     > "the consumed attempt is recorded INCOMPLETE without provider work"
   - **`tasks.md:357-359`:** add a matching helper test.

4. **Always scan the mutable SQLite family at every depth and state the metadata limit (M4).**
   - **`design.md:155`:** replace "Retain the legacy always-scan mutable log/logs/state/SQLite/WAL/SHM selection as a union" with:
     > "Retain the legacy always-scan selection and additionally always scan `.sqlite`, `-wal` and `-shm` regular files at every depth (except protected leaves), as a deduplicated union"
   - **`design.md:157`:** replace "never by exclusion" with:
     > "never by exclusion other than the stated metadata-equality assumption for non-SQLite ordinary files, which is a detector limit recorded with the result, like the UTF-8-only match limit"
   - **`tasks.md:347-351`:** add a test with an SQLite/SHM file inside an unclassified subdirectory whose metadata is unchanged.

5. **Make the disclosure mechanical and the spec assertable (M5).**
   - **`design.md:157`:** add:
     > "For changed-artifacts-v1, preparation prints, beside the selection, limits and hash, a fixed disclosure stating that all native-home metadata is inventoried, that only `auth.json` and `config.toml` leaves are protected, and that every other new/changed regular file (including caches and any other credential-bearing store) is read in chunks into host memory and never printed. Before implementation, the minimum-version research record lists any other known credential or configuration file names, and each is added to the protected set."
   - **`specs/agent-tool-access/spec.md:97`:** replace the AND clause with:
     > "**AND** preparation printed the fixed changed-artifacts-v1 disclosure beside the manifest hash"
   - **`tasks.md:353-359`:** add a helper test that asserts the disclosure text, and that it is absent in legacy mode.

## Focused Recheck (Round 6 Required Changes)

**Scope and method:**
- **Read with read-only file tools:**
  - The current `review.md` and `AGENTS.md`.
  - `design.md:118-159`, covering D4 and the D5 audit-budget, native-coverage, changed-artifact and protected-data paragraphs.
  - `tasks.md:300-389`, the final amendment and its test paragraphs.
  - `specs/codex-sessions/spec.md:95-110` and `specs/agent-tool-access/spec.md:88-111`.
  - `proposal.md` in full.
  - `docs/qualification/codex-app-server.md:940-997`, the planned follow-up and the actual Windows rows.
- **Searched:** `tool/qualify_codex_app_server.dart` for `nativeScope` and `allow_once`, and the non-test sources under `packages/` for `allow_always`.
- **Counted:** I found six `| red` map rows. Task 8.4 is still `- [ ]`, and 8.2 is still `- [x]`.
- **Not done:** no tests, validation, release-note or whitespace checks, hash comparisons, Git, native-home, provider or tracker operations.
- **Coordinator receipts not used as verification:** "strict validation 15/15, 135 scenarios mapped (129 green, 6 red), 22 checkbox lines unchanged, 281 Dart hashes unchanged". I did not reproduce those checks.

**RC1 (M1): verified.**
- **Design:** `design.md:123` now states:
  - "The desktop renders permission titles, previews and option names as plain selectable text with no fence or markup interpretation; no displayed byte is dropped or reinterpreted."
  - "This applies to permission display only, not transcript formatting." This scopes the change correctly and leaves `AgentPlainText` transcript behaviour alone.
- **Tasks:** `tasks.md:340-343` requires a command and an object decision containing triple backticks and newlines, and asserts that the complete permission preview appears unchanged as plain selectable text. It also forbids using the transcript fence renderer for permission display. That makes the M1 defect observable in the desktop `Codex decision display:` row.
- **Spec:** `codex-sessions/spec.md:105` adds "all permission display is literal selectable text, including backticks and newlines".
- **Qualification record:** `codex-app-server.md:953` agrees.

**RC2 (M2): verified.**
- **Design (`design.md:123`):**
  - JSON-object decisions are published with kind allow_always, the conservative persistent-scope classification, and never allow_once.
  - "this changes no response value or grant".
  - String decisions keep their existing kind mapping.
  - Tests assert the kind of every object entry.
- **Tasks:** `tasks.md:333` asserts that every object kind is allow_always and never allow_once, with exact response values and the string kind mapping unchanged.
- **Spec:** `codex-sessions/spec.md:105` says "objects use conservative allow_always classification".
- **Consistency with the helper:** the helper fence (`design.md:125`, `tasks.md:343-347`) still requires one literal string `accept` with the allow_once kind, and states that kind alone never authorizes an answer.
- **Desktop side effects:** a search of the non-test sources under `packages/` found `allow_always` only in `runtime_driver.dart:2091`, the existing `acceptForSession` mapping. No desktop code keys an automatic or remembered grant on that kind, so reclassification adds no authority.

**RC3 (M3): verified.**
- **Design (`design.md:155`):**
  - The preflight runs after the durable attempt claim.
  - It reads real native-home metadata only under that exact-manifest approval.
  - An incomplete baseline consumes the approval and starts no App Server, prompt or provider work.
  - It records an INCOMPLETE receipt with content-free baseline counters, the baseline-preflight stage, and explicit no-provider and no-content-scan indicators.
  - A further attempt needs a fresh exact-manifest approval.
  - The design says "never move the metadata read ahead of approval or silently reuse the claim". The earlier "without falling back to legacy" also remains.
- **Spec:** `agent-tool-access/spec.md:110` adds "the consumed attempt is recorded INCOMPLETE with baseline counters and no-provider/no-content-scan indicators".
- **Tasks:** `tasks.md:363-368` asserts:
  - the claim stays consumed;
  - the INCOMPLETE receipt has counters, the stage and both indicators;
  - reuse is refused;
  - another attempt needs fresh approval.
- **Qualification record:** `codex-app-server.md:964-966` agrees.

**RC4 (M4): verified.**
- **Selection rule (`design.md:155`):**
  - Keeps the legacy always-scan selection.
  - Additionally always scans `.sqlite`, `-wal` and `-shm` regular files at every depth, except protected leaves, as a deduplicated union, even when metadata compares equal.
  - Labels these "filename-family rules, not content-based database discovery".
  - States the metadata-equality detector assumption for other unchanged ordinary files.
- **Exclusion rule (`design.md:157`):**
  - The sentence now reads "never by exclusion other than the stated metadata-equality assumption for ordinary files outside the always-scan union".
  - It requires recording this detector limit with the result, alongside the ASCII/UTF-8-only matching limit.
  - It disclaims complete persistence detection for metadata-preserving writes.
- **Spec:** `agent-tool-access/spec.md:98-99` makes both the every-depth selection and the recorded detector limits assertable.
- **Tasks (`tasks.md:351-355`):**
  - The former "unchanged-file exclusion" case is replaced by "metadata-equal ordinary files outside the always-scan union and the recorded detector limit".
  - A test covers SQLite/WAL/SHM files inside unclassified subdirectories whose metadata is unchanged.
  - Protected leaves under always-scan paths are covered at `tasks.md:385`.

**RC5 (M5), with the requested clarification: verified.**
- **Disclosure (`design.md:157`):** preparation prints a fixed disclosure beside the selection, limits and hash. It covers:
  - the full metadata inventory;
  - that "only the enumerated protected basenames are metadata-only";
  - that every other new or changed regular file, "including caches and any other credential-bearing store", plus the always-scan union, is read in chunks into host memory and never printed;
  - the metadata-equality and ASCII/UTF-8 detector limits.
- **Binding:**
  - `scan.nativeScope` carries the canonical disclosure, and the helper checks it before the claim.
  - Legacy keeps its existing scope text and never prints the wider-mode disclosure.
  - The existing legacy `nativeScope` string is at `tool/qualify_codex_app_server.dart:71`, so "original scope text" refers to concrete data that can be compared.
- **Enumeration, as requested:**
  - The two-name list is called "the starting minimum, not a claim that no other credential stores exist".
  - The canonical disclosure must "enumerate the effective protected set".
  - No RPC or CLI argument may supply arbitrary protected names, so the set stays closed.
- **Research gate:**
  - The research record must list other known credential and configuration filenames with exact-version evidence, and add each one to the closed set and to its tests.
  - Unresolved known names block implementation and any real read.
  - Research uses documentation and installed protocol material only, never real native-home contents.
  - `tasks.md:372-376` repeats the gate: unresolved names block implementation, and no native-home inspection is authorized.
- **Assertability:**
  - The WHEN/AND precondition at `agent-tool-access/spec.md:97` is now "preparation printed the fixed changed-artifacts-v1 disclosure beside the manifest hash and the helper validated the canonical manifest scope before claim". Both are machine-observable.
  - `tasks.md:368-372` names helper tests for the disclosure beside the hash, its absence in legacy, canonical `scan.nativeScope` validation before the claim, enumeration of the effective protected set, and the warning about other credential-bearing stores.
  - The protected-entry scenario (`agent-tool-access/spec.md:108`) names auth.json and config.toml "plus other known credential/configuration names established before implementation". That is testable against the closed set fixed before implementation.
- **The scope stays honest:**
  - `codex-app-server.md:969-976` matches the design.
  - `proposal.md:73` and its release note (`:102`) claim only explicit, bounded selection with protected and unaccounted entries left incomplete.
  - The record still requires the later exact-manifest approval to disclose the wider scope.
- **Residual observation, not blocking:** the research gate is prose in `design.md:157` and `tasks.md:372-376`, not its own checkbox. That fits the constraint that checkbox lines stay unchanged. The implementer must treat it as a hard precondition for the group 8 follow-up.

**Status of the suggestions (none required):**
- **S1, name collisions: folded in.**
  - `design.md:123` refuses the whole request with native cancel when a redacted string name collides with a generated object label.
  - `tasks.md:333` tests that collision, with a visible cancel and no partial offer.
- **S4, iterative traversal: folded in.** `tasks.md:385-387` requires observing the maximum pending entries and depth through a test-only injected lister.
- **S2, bidi/Unicode escaping: still advisory and not adopted.** No artifact escapes U+202E or U+2028/U+2029 in permission previews or tests for it.
- **S3, host-side baseline gate: still advisory and not adopted.** The refusal remains helper-side only.
- **All four suggestions are planning text only.** None is implemented in source.

**State preserved:**
- Six red rows remain.
- Task 8.4 is open, and 8.3 is not marked complete in the lines I read.
- The actual Windows rows (`codex-app-server.md:981-997`) still record attempt 6 as INCOMPLETE, with command approval, Stop, containment and `kumiko tool call` unverified.
- No consumed approval is reused, and no cap is raised.

All five Required Changes are present in the current design, specs and tasks, with matching assertions. The Round 6 findings and verdict stand as written.

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

<!-- Author: fixed (cite) or rebutted (reason) per finding. A Critical/Moderate rebuttal counts only once marked "accepted by reviewer". -->