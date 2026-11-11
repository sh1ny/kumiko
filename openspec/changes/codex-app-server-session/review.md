# Review

## Metadata

- **Round:** 4. A full design review of the owner-approved ordinary-command approval clarification dated 2026-11-11. It covers:
  - D4 Interactions and the Approval clarification paragraph (`design.md:119-121`);
  - the expanded "Approve a command" scenario (`specs/codex-sessions/spec.md:93-103`);
  - its map row (`tasks.md:99`);
  - the "Approval clarification amendment" paragraph (`tasks.md:210-229` after the amendment).
- **Prior round:** Round 3 returned APPROVE_WITH_CHANGES for the task-order amendment. Its focused recheck confirmed Required Changes 1–6 applied (Round 3 marked its changes applied). I read that `review.md` before this replacement. Its verdict is void for the amended design until this round completes.
- **Reviewer:** Fresh-context reviewer (Claude Code agent, `claude-opus-5-5`), read-only, file tools only (no shell). I could not fetch the cited upstream Codex 0.166 sources. Statements about native behaviour rely on the repository's research record and the coordinator's provenance notes. I don't claim to have read those URLs. Applicable skills (dart-add-unit-test, dart-build-cli-app) were not needed, and no finding depends on them.
- **Reviewed:**
  - **Project rules:** `AGENTS.md`.
  - **Change artifacts:** `openspec/changes/codex-app-server-session/{proposal.md, design.md, tasks.md, review.md}`; `specs/codex-sessions/spec.md` in full. I searched the other five delta specs (`agent-runtimes`, `agent-sessions`, `agent-tool-access`, `app-exit`, `desktop-host-protocol`) for approval and permission wording.
  - **Decision and research records:** `docs/adr/0015-native-codex-app-server-and-child-identity.md` (status and Decisions 4–5); `docs/qualification/codex-app-server.md` (core schema table at `:199-221` and the third-attempt record and Windows section at `:600-675`).
  - **Source:** `packages/host/lib/src/agent/runtime_driver.dart:1960-2208` (approval/question request mapping); `packages/host/test/it/codex_test.dart:1690-1910` (approval preview, explicit-list and overflow cases), plus searches for `availableDecisions` across `packages/host`; desktop `lib` searches for consumers of approval option `kind`.
  - **Baseline:** the coordinator-supplied pre-amendment excerpts of D4, the scenario and its map row.
- **Not done:** no SDK commands, builds, tests, real runtime calls, native-home reads, provider or auth experiments, or tracker actions.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

**Scope and bookkeeping are as stated.**
- **Map:** 131 rows (`tasks.md:9-139`). Two are red: `:99` (expanded command scenario) and `:119` (real Windows evidence). The other 129 are green.
- **Checkboxes:** 22, of which 20 are ticked. 8.3 and 8.4 are open.
- **Real evidence:** the Windows section still records command approval, Stop and the other required observations as unverified (`codex-app-server.md:659-674`).
- **No new walk authorized:** neither the design (`design.md:121`) nor the tasks amendment (`tasks.md:224`) authorizes a further real walk or auth experiment.

**The current implementation is unchanged, as the brief says.** `runtime_driver.dart:2066-2076` still auto-replies `decline` with a notice when `availableDecisions` is missing. The scenario is correctly red and planned; nothing claims it already passes.

**The core direction is sound:**
- The fallback offers only native one-shot `accept` and `cancel`.
- It is limited to ordinary requests.
- Explicit lists stay authoritative.
- No persistent grant comes from the fallback.

It also fits the shared contract:
- It reuses the existing `_deliverInteraction` staging, run/thread/turn/request fencing and retirement (`:2029-2056`).
- Its lifecycle cancellation value, `{'decision': 'cancel'}` (`:2102`), is one of the two fallback choices, so Stop or close never sends an un-offered value for fallback requests.
- Two choices fit well within the permission-option bound.

It doesn't conflict with ADR 0015 Decision 5 ("Preserve native offered approval choices"):
- When the list is absent, the fallback is a strict subset of the native default, so it adds no authority.
- Leaving out the native default's policy-amendment choice narrows authority rather than widening it.

**Round 3's Required Changes are still present and consistent.**

| Round 3 change | Where it is now |
|---|---|
| RC1 (fence and tool-grant rows) | task 4.1 at `tasks.md:159` |
| RC1 (child-content rows) and RC3 (auth rows) | task 4.3 at `:161` |
| RC3 (D7 sign-in wording) | task 5.1 at `:166` |
| RC3 (desktop restore row) | task 6.1 at `:171` |
| RC3 (child-Stop rows) | task 7.1 at `:177` |
| RC4 (`test:host`) | task 2.2 at `:149` and the workflow bullet at `:228` (now `:233`) |
| RC6 (stale group reference) | traceability row at `:207` |

Line numbers moved by two from Round 3; the text is unchanged. Two map cells have drifted since the Round 3 recheck (see S5). They remain coherent.

### Critical (blocking)

None.

### Moderate

**M1. "Visibly unavailable" has no defined native resolution, and it conflicts with D3 and the requirement text.**

- **What the artifacts say:**
  - D3 says malformed core contracts fail the run, and it lists approval requests as core (`design.md:101`).
  - Amended D4 says an explicit empty or malformed list is "visibly unavailable and grants nothing" (`design.md:119`).
  - The requirement allows only "an explicit user answer, Stop, close, native retirement or a visible capacity refusal" to resolve a request (`spec.md:89`). An "unavailable" refusal is none of these.
  - The scenario says non-ordinary requests with an absent or null list "do not receive the ordinary fallback" (`spec.md:101`). It doesn't say what they receive instead.
- **What the source does today:** it resolves the same class of problem three different ways.
  - **Native `decline`:** a list that is not a list, is empty or exceeds `maxPermissionOptions` gets one `decline` reply and a notice (`runtime_driver.dart:2069-2076`).
  - **Run failure:** an entry that is neither a string nor an object throws `CodexProtocolException` (`:2079-2080`).
  - **Native `cancel`:** the capacity path replies `cancel` (`codex_test.dart:1899`).
- **Why it matters:** native `decline` lets the turn continue, while `cancel` ends it. The planned red row "Empty or malformed command decisions stay unavailable" therefore has no defined pass condition. An implementation could keep the throw, so one bad entry ends the whole run, or switch to `cancel`, and still claim the scenario.
- **"Valid" is undefined.** The design never says whether an unknown but well-formed decision string in an explicit list is valid and kept as-is, or malformed. The current code keeps it.

**M2. File-change approvals still offer a session-scoped choice the native request never carried, and this clarification blurs who owns that.**

- **Code:** for `item/fileChange/requestApproval`, the driver offers a fixed set `['accept', 'acceptForSession', 'decline', 'cancel']`. It classifies `acceptForSession` as `allow_always` (`runtime_driver.dart:2066-2068, 2083-2084`).
- **Records it conflicts with:**
  - The research record says file approvals carry no decision list in the minimum schema: "Do not invent permission choices" (`codex-app-server.md:213`).
  - Amended D4 says "Never invent other allow/always choices".
- **Why the amendment makes this worse:** it says "other approval kinds ... do not use this fallback". It also adds a planned row "Special approvals do not use ordinary defaults". Together these suggest file-change approvals are covered, when this file-change set is a separate host-supplied fallback that includes a persistent grant.
- **A green test exercises it:** the preview test passes against this list without checking which choices are offered (`codex_test.dart:1733-1742`).
- **Consequence:** the clarification could be marked complete while a session-wide file-write choice, not supplied by the native request, stays offered. Changing file-change behaviour is outside the owner's authorization for this round. So the right fix is to state the boundary explicitly, not to change behaviour here.

### Suggestions

- **S1. `kind` provenance and null handling.**
  - The contract record's command-approval row (`codex-app-server.md:212`) doesn't list a `kind` field, but D3 says the minimum-version schema defines the contract.
  - Record where `kind` comes from in that row.
  - Also, the design says "`kind` absent or `command`" but "absent or null" for the other two fields. As written, `kind: null` falls out of the fallback and becomes unavailable. If that's intended, state it; otherwise align the wording.
- **S2. Fallback eligibility when the scope can't be seen.**
  - The approval preview shows only command, cwd and reason (`runtime_driver.dart:2095-2100`).
  - D3 ignores unknown additive fields.
  - So a fallback `accept` could be offered for a request with no command text, or with a context field a newer Codex adds, and the user would approve it without seeing its scope.
  - Consider requiring a nonempty `command` string for fallback eligibility.
- **S3. `cancel` ends the turn.** In the fallback, the only way to refuse is native `cancel`. The label is the raw decision string (`:2082`). Users may expect a plain decline that lets the turn continue. Label it so it's clear the turn stops.
- **S4. Persistent explicit decisions are classified as one-shot.**
  - An explicit object decision such as `acceptWithExecpolicyAmendment` (exercised at `codex_test.dart:1834-1847`) gets kind `allow_once` (`runtime_driver.dart:2083-2087`).
  - I found no desktop code in `lib` that uses that kind, so the impact is small today. Still, the shared DTO understates how long the grant lasts.
  - Consider classifying policy-amending or unknown object decisions as `allow_always` or as unclassified.
- **S5. Two map cells changed after the Round 3 recheck without a traceability note.**
  - Row `:120` now names `packages/host/test/it/codex_profiles_test.dart` instead of `codex_test.dart`.
  - Rows `:134-135` no longer list the codec file.
  - Both are coherent, since the named tests are end-to-end, but note them in the traceability text.
- **S6. Child requests take a different turn path.** Child approvals get their turn from the child registry (`runtime_driver.dart:2037-2050`), not from the root. Include one child ordinary-command case with an absent list among the planned rows.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Define the unavailable resolution (M1).**
   - **`design.md:119` (D4).** Replace "an explicit empty or malformed list is visibly unavailable and grants nothing." with:
     > "An explicit list that is empty, is not a list, exceeds the shared permission-option bound or contains an entry that is neither a string nor a JSON object, and an absent or null list on a non-ordinary command approval, is visibly unavailable: the host replies native `decline` once, shows a bounded notice, grants nothing and keeps the run (this optional field does not fail the run under D3). Well-formed decision values unknown to Kumiko in an explicit list are preserved verbatim."
   - **`specs/codex-sessions/spec.md:101`.** Replace the bullet text with:
     > "explicit empty/malformed lists, and absent/null lists on other approval kinds or permission contexts, are visibly unavailable: native `decline` is sent once with a bounded notice, nothing is granted and the run continues"
   - **`specs/codex-sessions/spec.md:89`.** Replace "or a visible capacity refusal" with:
     > "a visible capacity refusal or the visible unavailable refusal defined for command approvals"
   - **`tasks.md:220` (amendment paragraph).** After "refusal of empty/malformed lists", insert:
     > " (native `decline` once, bounded notice, run continues, including a non-string/non-object entry and an absent list on a non-ordinary request)"

2. **Set the file-change boundary (M2).**
   - **`design.md:119` (D4).** After "other approval kinds and permission contexts do not use this fallback.", insert:
     > "File-change approvals carry no decision list in the minimum schema and are outside this clarification; their current fixed set, including session-scoped `acceptForSession`, must be reconciled with the research record's no-invented-choices rule by a separate owner decision before task 8.4 completes."
   - **`tasks.md` amendment paragraph.** Append:
     > "The planned Special approvals row covers command approvals only and verifies no file-change choice set; the file-change reconciliation stays open for the owner decision named in D4."

## Focused recheck (Required Changes 1–2)

**Scope.** I rechecked only RC1 and RC2. I did not reopen S1–S6 or carry out any implementation or pre-ship review. Same reviewer constraints apply: read-only, file tools only, no shell, and no fetching of URLs. I read:
- the current `review.md`, including the author's Rebuttals;
- `design.md:99-123` (D3 Identity and D4 Interactions/Approval clarification);
- `specs/codex-sessions/spec.md:87-103`;
- `tasks.md:99` and `:205-229`;
- `runtime_driver.dart:2058-2089`;
- a repository-wide search for `acceptForSession`, `fileChange/requestApproval` and "invent".

I did not read the Codex rust-v0.166.0 URLs myself. Statements about them below are the coordinator's provenance notes, not my own observations. I also did not re-run strict validation, the whitespace check, the checkbox count or the 279-file snapshot comparison, since I have no shell. Those results are the coordinator's report.

**The implementation is unchanged.** `runtime_driver.dart:2059-2089` still:
- replies `decline` once with a notice for a missing, non-list, empty or over-bound list (`:2069-2076`);
- throws on a non-string/non-object entry (`:2079-2080`);
- supplies the fixed file-change set (`:2068`).

That matches the Round 4 baseline. The command scenario stays red at `tasks.md:99`, with no claim that it passes.

### RC1: verified as applied

- **D4 (`design.md:119`):**
  - It now enumerates the unavailable cases: empty, not a list, over the shared permission-option bound, an entry that is neither string nor JSON object, and an absent/null list on a non-ordinary command approval.
  - It defines one resolution for all of them: native `decline` once, a bounded notice, no grant, and the run continues.
  - It states that this optional field is an explicit exception to D3's malformed-core failure rule, while malformed required approval identity fields still fail the run. That resolves the D3 conflict without weakening identity fencing.
  - It keeps well-formed unknown decision values verbatim, which settles what "valid" means.
- **Scenario (`spec.md:101`):** it states the same enumeration and outcome, plus verbatim preservation of unknown values. It says "other command approval kinds or permission contexts" rather than RC1's broader "other approval kinds". That narrowing is correct, because RC2 now puts file-change approvals outside this rule. It is consistent with D4.
- **Requirement (`spec.md:89`):** the resolution list now includes "the command-approval unavailable refusal below". The shortened wording keeps the other semantics: session identity, native choice semantics, no automatic grant, visible failure for unsupported kinds, and refusal of retired answers. I accept the coordinator's report that strict validation passes at the 500-character limit; I did not run it.
- **Task amendment (`tasks.md:218-222`):** it states the same outcome and lists every case, including non-list, over-bound, non-string/non-object entries and absent/null lists on non-ordinary command requests, plus preservation of unknown values.
- **Result:** the planned red row "Empty or malformed command decisions stay unavailable" now has one defined pass condition. Keeping the throw or switching to `cancel` would visibly fail it. M1 is resolved.

### RC2: boundary verified as applied; the owner-decision gate rebuttal is accepted

- **Boundary applied:**
  - D4 (`design.md:119`) says file-change approvals carry no decision list in the minimum schema and are outside this command-only clarification, and that it does not modify their existing native response semantics.
  - The task amendment (`tasks.md:228-229`) limits the planned Special approvals case to command approvals and says it verifies or modifies no file-change choice set.
  - This removes the ambiguity M2 named: the clarification can no longer be read as covering, or marked complete over, the file-change choice set.
- **Gate not applied, and the author disputes it.** I decided on the evidence, not because a rebuttal was supplied. **I accept the rebuttal**, for two reasons. The first is enough by itself.
  1. **The gate goes beyond what M2 established and what this round owns.**
     - M2's stated consequence was a false-coverage risk: the clarification could be marked complete while the file-change set stayed unexamined. The applied boundary fully removes that risk.
     - The fixed file-change set existed before this amendment, in behaviour covered by earlier approved rounds and the group 5–7 commits. This amendment neither adds nor changes it.
     - M2's "invented choice" premise rested only on my reading of `codex-app-server.md:213`. That row records the request's required fields and the absence of a request-side list. It does not record which values the response accepts, so it cannot show that `acceptForSession` is non-native.
     - A blocking owner gate on task 8.4 for pre-existing, out-of-scope behaviour therefore does not follow from the evidence in this round.
  2. **The coordinator's version-specific provenance, which I have not read, directly contradicts the premise.**
     - According to the coordinator, Codex rust-v0.166.0's `FileChangeApprovalDecision` defines `acceptForSession` as a native response, scoped to the same files. The same tag's own file-change UI includes it in its unconditional baseline (`approval_overlay.rs` near line 981).
     - If accurate, the response contract defines the valid file-change choices, and the host's set preserves native choices rather than inventing them. That fits ADR 0015 Decision 5 and the research record's rule.
     - The repository is consistent with this: `tool/test/qualify_codex_app_server_test.dart:416` already exercises an `acceptForSession` file-change choice in the qualification tooling.
     - My acceptance does not depend on this unverified provenance, and I make no claim about upstream behaviour beyond the coordinator's report.
- **Residual note (non-blocking, not a Required Change):**
  - The research record row `codex-app-server.md:213` would read more clearly if it named the response-side decision set and its source. That would stop a future reader from making the same inference M2 made.
  - The S4-style classification of `acceptForSession` as `allow_always` is coarser than the native same-files scope.
  - Neither point affects this command-only clarification, and neither is a gate on task 8.4.

### Disposition

RC1 is verified as applied. RC2's boundary is verified as applied. Its additional owner-decision gate is explicitly accepted as rebutted by the reviewer, for the reasons above. No required item remains unresolved for this round. This disposition does not waive any finding for the owner and does not supply real qualification evidence. The expanded command scenario (`tasks.md:99`) and real Windows evidence (`:119`) stay red, and tasks 8.3/8.4 stay open, as the artifacts already state.

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

**RC1 applied for independent recheck.** D4 now defines one native `decline`, a bounded notice, no grant and a continuing run for unavailable command decision lists, preserving unknown well-formed values. The scenario and task amendment state the same outcome. The requirement's resolution list now includes this unavailable command refusal; its wording was shortened to stay within strict validation's 500-character limit. Required identity fields remain core failures. No implementation changed.

**RC2 boundary applied; owner-decision gate rebutted, not yet accepted by reviewer.** D4 explicitly leaves file-change approvals outside this command-only clarification, and the task amendment limits the planned Special approvals case to command approvals. The proposed additional owner-decision gate is disputed on new version-specific primary evidence:

- Codex 0.166's native `FileChangeApprovalDecision` response contract explicitly supports `acceptForSession`, with future approval limited to the same files: [native protocol](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server-protocol/src/protocol/v2/item.rs).
- That version's own file-change UI presents this session option in its baseline choices, not a request-supplied decision list: [native file-change options](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/bottom_pane/approval_overlay.rs#L981).
- Thus absence of a decision-list field on the file-change request does not establish that the existing native response choice is invented. The research record's no-invented-choices rule is compatible with preserving protocol-defined choices. No new file-change authority or behavior is proposed or implemented here.

The reviewer must independently accept or reject this rebuttal. The findings, Required Changes, verdict and applied-status line above remain unchanged pending that recheck.

**Reviewer disposition (focused recheck):** I accept the RC2 owner-decision-gate rebuttal. The main reason is that the applied boundary fully resolves M2's stated consequence, and the gate addressed pre-existing, out-of-scope file-change behaviour that the repository record never showed to be non-native. The coordinator's version-specific provenance, which I could not fetch and have not personally read, supports this but is not needed for it. RC1 is verified as applied, and the applied-status line is set accordingly by the reviewer.