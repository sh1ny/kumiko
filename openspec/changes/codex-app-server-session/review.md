# Review

## Metadata

- **Round:** 3. This is a full review of the task-order amendment: the new `## Implementation sequence amendment (2026-11-10)` in `design.md` and the reordered groups 2–8 in `tasks.md`.
  - **Focused recheck (2026-11-10):** this recheck covers only whether Round 3 Required Changes 1–6 were applied. The design, findings and suggestions were not reopened. The Round 3 findings, verdict and Required Changes below are unchanged. Only the recheck notes and the `CHANGES_APPLIED` line are new.
- **Prior round:** Round 2 returned APPROVE_WITH_CHANGES. Its focused re-check confirmed Required Changes 1–5 applied (CHANGES_APPLIED: yes). The prior `review.md` was read before writing this replacement. I re-checked that its five applied changes are still present in D3, D5, D6, D7, T2, State & Ownership, Resource Bounds and the delta specs. They are, unchanged.
- **Reviewer:** Fresh-context reviewer (Claude Code agent, `claude-opus-5-5`), read-only. I had file tools only, with no shell. The focused recheck was done by the same kind of reviewer (Claude Code agent, `claude-opus-5-5`), also read-only with file tools only.
  - **Commit comparison.** In Round 3 I couldn't run `git diff` or `git show 57e9f55:…/tasks.md`, and I had no copy of the commit-57e9f55 `tasks.md`. So I checked that obligations were preserved against four things: the in-file traceability table, the test map, the scenario set in the six delta specs, and the current task text.
    - **Recheck:** the user supplied the full commit-57e9f55 `tasks.md` as data, and reported that a mechanical comparison found tasks 1.1 and 1.2 identical.
    - **Tasks 1.1 and 1.2:** I compared them textually against that baseline. Current `tasks.md:143-144` match it exactly.
    - **Test-map rows:** I compared these too. Every row not named in Required Change 2 matches the baseline. The changed rows are only those Required Change 2 names: `tasks.md:119-120` and `128-139`.
  - **Applicable skill:** dart-build-cli-app (`F:/Dev/Orca/Workspace/kumiko/.agents/skills/dart-build-cli-app/SKILL.md`). I didn't need it; no finding depends on it. The recheck used no skills.
- **Reviewed:**
  - **Project rules:** `AGENTS.md`.
  - **Change artifacts:** `openspec/changes/codex-app-server-session/{proposal.md, design.md, tasks.md, review.md}` and all six `specs/*/spec.md`.
  - **Decision and research records:**
    - `docs/adr/0015-native-codex-app-server-and-child-identity.md`, in full;
    - `docs/qualification/codex-app-server.md`, in full;
    - `openspec/architecture.md`, the Codex lines;
    - `openspec/roadmap.md`, change 1.
  - **In-force ADRs:**
    - ADR 0013: the decision list (decision 8 in detail).
    - ADR 0012: the ownership, test-host and release-fence passages (lines 62, 102, 110, 144).
    - ADRs 0004, 0005 and 0014: I relied on ADR 0015's limited-supersession text and the architecture index. I didn't reopen them in full.
  - **Source:**
    - `packages/host/lib/src/agent/agent_service.dart:99-123, 247-340, 560-1000`
    - `agent_session.dart:1-200`
    - `acp/acp_client.dart:148-160`
    - `runtime_profile_service.dart`, its `runtimeKind` uses
    - `adapter_detector.dart:166`
    - `test_hooks/test_hooks.dart`, `fixtures.dart`, `host_main.dart:17-29`, `host.dart:103-121`
    - `packages/host_protocol/lib/src/connection.dart:440-520`, `messages.dart:84-130`, `pubspec.yaml`
    - `packages/domain/lib/src/profile/profile.dart:113-167`
    - desktop capability checks (`main.dart:50`, `workbench_controller.dart:736`, `agent_controller.dart:326-727`)
    - the existing test inventory under `packages/host/test`, `packages/host_protocol/test` and `packages/desktop/test`.
  - **Read for the focused recheck:**
    - current `tasks.md`, in full;
    - current `review.md`;
    - `design.md` D7 (`:161-169`);
    - the commit-57e9f55 `tasks.md` baseline supplied by the user;
    - `openspec/schemas/specwright/templates/review.md`.
  - **Searched for the focused recheck:**
    - the change directory, for the removed phrases "capability refusal before spawn", "Preserve exact-version" and "Test-map rows above are unchanged". None remains in `tasks.md`.
- **Not done:** no provider calls, schema generation, builds or tests. The focused recheck also made no author edits and didn't reopen the design or suggestions.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

**The amendment's premise matches the code.**
- `_AgentIO` builds `AcpClient` directly (`agent_service.dart:103`).
- `AgentSession` hooks ACP normalization, permission and failure callbacks directly (`agent_session.dart:57-60`).
- Start and Continue share one `_open` path (`agent_service.dart:661-663`). It reserves the channel at :673, registers the grant at :682-699, launches the unit at :700 and releases on failure at :807.

So shared startup admission and channel release can only be shown through `AgentService`, and folding the seam, routing, probe and mapping into group 4 is justified. Moving delegated-summary delivery from former 4.3 to 7.1 puts scope later, not earlier, which is allowed.

**Triage is still correct:** T1–T6 apply, so the tier is FULL. The amendment changes only sequencing.

**No contradiction with D1–D7 or the requirements was found**, apart from the wording in M3(d).

### Critical (blocking)

None.

### Moderate

**M1. Three invariants the amendment states have no failing-first test in group 4, the first native integration.**

- **(a) The capability gate can end up after the version probe.**
  - The spec requires refusal "before spawn", and ADR 0012:62 says start validates the runtime before spawning.
  - The contained version probe is itself a UnitManager spawn. 4.4 adds it after 3.1 has already placed the gate, and no task fixes their order.
  - Consequence: an older desktop's Codex start could launch `codex --version` before it is refused.
- **(b) "Without minting or leaking a usable bridge secret" isn't testable as written.**
  - Today `_open` registers a grant whenever the endpoint exists. It also builds the `kumiko` entry with `KUMIKO_TOOL_SECRET` before initialization (`agent_service.dart:682-723`).
  - Task 4.4 only says "tools remain visibly unavailable".
  - Consequence: if the shared `_open` is reused unchanged, the secret-bearing entry is available to the Codex driver. It could reach `thread/start` config, which is exactly the persistence path D5 forbids until 6.2 and 6.3 prove it safe.
  - `_startTools` would also report the misleading `endpoint-unavailable: not started` reason (:955-959).
- **(c) Content from child threads has no test before group 7.**
  - Task 4.3 only covers "unknown child requests refused and attributed visibly".
  - Native child threads can stream items and deltas from group 4 onwards. Nothing checks that they are withheld through the unknown-child path rather than appended to the root reply.
  - Consequence: the proposal's "must not flatten child activity" rule can go unenforced through groups 4–6.

**M2. Red/green rules contradict the test map and the test file layout.**

- **(a) A row that cannot be red first.** Task 4.1 lists "capability refusal before spawn" as a row that must fail before 4.4. But 3.1 has already implemented and verified that refusal, so the row passes before 4.4 starts and the red-first rule can't be met.
- **(b) Protocol rows mapped only to a codec file.**
  - Every `desktop-host-protocol` row is mapped only to `packages/host_protocol/test/codex_messages_test.dart`.
  - `host_protocol` depends only on `domain` and `process_containment` (`pubspec.yaml:9-14`), so it cannot exercise a host with stalled native stdin or no transcript credit. The existing stalled-output bound lives in `packages/host/test/it/agent_qualification_test.dart:66-67`.
  - Task 3.1 and the amendment both say a codec test cannot turn these rows green. So rows such as "Stop while Codex output is stalled", "Stalled native input" and "Child starts with no transcript credit" either go green on a codec test, against the rule, or never go green at all.
- **(c) Qualification rows mapped to the wrong place.**
  - "Real Windows evidence passes" and "Tests pass but walk is unrun" are mapped to host fixture tests in `codex_test.dart`.
  - Task 8.1 puts those checks in `tool/test/check_qualification_test.dart`.
  - A host fixture test cannot establish real evidence: the map's own preamble and 8.3 forbid that.

**M3. Some rows have no owning task, and one task contradicts D7.**

- **(a) Host authentication rows.** No task writes the host rows "Known Codex authentication failure" and "Unknown auth-like diagnostic" (`codex_test.dart`) red first. Task 4.3 omits authentication; 5.1 covers only the desktop. Existing classification recognises only `AcpRemoteException` at `session/new` (`agent_service.dart:845-849`), so Codex start and turn classification is new host work without a test owner.
- **(b) Desktop restore row.** "Codex restores through native history" (`codex_agent_test.dart`) is unowned: 6.1 names only host files.
- **(c) Desktop child-Stop rows.** "Codex native interruption completes" and "One child interruption is unsupported" (`codex_agent_test.dart`) are in neither 5.2 nor 7.1.
- **(d) Version-gated sign-in wording.** Task 5.1 says "Preserve exact-version auth evidence rules". D7 says confirmed auth signatures apply to every admitted Codex version and that version metadata is "not a sign-in-guidance gate". As written, 5.1 invites version-gated guidance.

**M4. The riskiest change to ACP ownership is under-verified.**

- Task 2.2 moves `AgentSession` off `AcpClient` onto the driver seam. It verifies only `acp_client_test.dart`, `agent_session_transport_test.dart` and `agent_event_relay_test.dart`.
- It leaves out `packages/host/test/agent/agent_session_test.dart`, which holds the retained green Stop, permission, refusal and authentication rows. It also leaves out `mise run test:host`, which `AGENTS.md` requires for any host or protocol change. The pre-commit hook runs only `test:fast`, which excludes the host suite.
- Groups 3, 6 and 7 also change the host or protocol without naming `test:host`.
- Consequence: a Claude Stop or permission regression introduced in group 2 surfaces only at 4.4, two groups later.

**M5. Tests could launch the owner's real Codex.**

- ADR 0012:110 requires fixture starts to select their scripted profile or isolate detection, so a real installed runtime never becomes a fixture's default. Existing isolation goes through `KUMIKO_TEST_RUNTIME_PATH`/`DIRS` (`test_hooks.dart:37-48, 78`).
- The new Codex discovery (D3: PATH plus the npm global root) is new code. No task requires it to honour those overrides.
- The owner has `codex.exe` 0.166.0 on PATH. With Claude isolated away, the empty-store default rule picks Codex, so a fixture test could start the real App Server. Provider activity needs separate approval (8.3).

**M6. A completed artifact sends a test task to the wrong group.**

- `docs/qualification/codex-app-server.md:111` says "Verify these cases in group 3 fixtures". That refers to the former group 3. Version-grammar and mismatch cases are now 4.2 red and 4.4 green.
- Under the new order, group 3 is the protocol group, which has no probe. Following the record would pull version-probe testing into group 3, ahead of 4.4's rule of "no bare runtime version probe outside UnitManager".

### Suggestions

- **S1. Codex profiles still route through ACP in groups 2–3.**
  - Until 4.4, the host doesn't check the runtime kind. A `codex` profile with compatible peers would still go through the ACP `_open` path (`agent_service.dart:700-726`); `runtimeKind` is only checked for env at :638.
  - The result is harmless: initialize fails and the grant is revoked. But it contradicts D1's "do not route Codex through synthetic ACP methods" in intermediate commits.
  - Consider having 3.1 refuse the `codex` kind before spawn as not yet available until 4.4 replaces it.
- **S2. Close and quit aren't child-aware in groups 5–6.** Group 5 exposes a usable Codex launcher, but close and quit only become child-aware in 7.2. The amendment could state that these commits are development builds with child-unaware close and quit, so nobody daily-drives them.
- **S3. "Child bridge connection cap" has two owners and three file names.**
  - The map names `codex_tools_test.dart`.
  - Task 6.2 covers the 4-connection cap.
  - Task 7.1 lists "child bridge cap" in `codex_test.dart`.
  - Name one owner and the map's file.
- **S4. Where the 2.1 fixture lives.** Task 2.1 adds "a scripted native App Server fixture", but the release fence is only stated in 4.1. The existing structure already refuses `--test-fixture` in release (`host_main.dart:27`, ADR 0012:102/144). Still, 2.1 should say whether its fixture is test-package-only or a test-hook mode, and 4.1 should reuse it rather than add a second fixture.
- **S5. Make the traceability table reviewable without git.** Paste the former pending task texts, or a link to `git show 57e9f55:openspec/changes/codex-app-server-session/tasks.md`, into it.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

All edits are to `openspec/changes/codex-app-server-session/tasks.md` unless stated otherwise.

1. **Group 4 invariant tests (M1).**
   - **Task 4.1:** after "capability refusal before spawn", insert:
     > "; the refusal precedes the contained version probe as well as the App Server spawn, with no unit launched and no channel left reserved; and, until task 6.3 passes, a Codex start or Continue with the endpoint available registers no usable ToolGrant (or revokes it before any native write), sends no `kumiko` entry or secret in any native request, argv or environment, and reports tools unavailable with a Codex safe-delivery reason rather than endpoint-unavailable"
   - **Task 4.3:** append:
     > "Add red rows proving that items, deltas and tool updates from any non-root native thread are never appended to the root reply before group 7: they produce the bounded unknown-child notice and are withheld within the Resource Bounds unknown-child budget."

   **Recheck: applied.**
   - **Refusal ordering, `tasks.md:157`:** it reads "the refusal precedes the contained version probe as well as the App Server spawn, with no unit launched and no channel left reserved". This text is attached to the regression rerun from Required Change 2.
   - **Tool grant, `tasks.md:157`:** the grant clause appears as "Add red rows proving that, until task 6.3 passes, a Codex start or Continue with the endpoint available registers no usable ToolGrant (or revokes it before any native write), sends no kumiko entry or secret in any native request, argv or environment, and reports tools unavailable with a Codex safe-delivery reason rather than endpoint-unavailable."
   - **Accepted deviation:** the author split the clause into its own sentence and made it explicit red rows. This is accepted. It keeps every obligation, and it is consistent with Required Change 2: the refusal rows are green regressions, while the grant suppression is new behavior that must fail first.
   - **Task 4.3, `tasks.md:159`:** the child-thread sentence is present word for word.

2. **Red/green consistency (M2).**
   - **Task 4.1:** replace "capability refusal before spawn" in the list of red rows with:
     > "and rerun the group 3 capability-refusal rows through shared AgentService start and Continue as regressions that must stay green (not red-first rows here)"

     Keep the M1 insertion attached to this regression.
   - **Test map, `desktop-host-protocol` rows:** extend the Test file cell, using `;` as the existing rows do and keeping the test names:
     - "Compatible peers", "Older desktop", "Answer the current question", "Prior run sends a late answer", "Two children use the same tool identifier", "Attribution capacity is exceeded": add `packages/host/test/it/codex_test.dart`.
     - "Stop while Codex output is stalled", "Stalled native input": add `packages/host/test/it/agent_qualification_test.dart`.
     - "Running turn identity published", "Delayed prior-turn state": add `packages/desktop/test/codex_agent_test.dart`.
     - "Child starts", "Child starts with no transcript credit": add `packages/host/test/it/codex_test.dart; packages/desktop/test/codex_agent_test.dart`.
   - **Test map, `codex-sessions` qualification rows:**
     - "Real Windows evidence passes": change the file to `tool/test/check_qualification_test.dart; docs/qualification/codex-app-server.md` and the test name to "Codex: Real Windows evidence passes (checker); approved Windows section recorded by 8.3".
     - "Tests pass but walk is unrun": change the file to `tool/test/check_qualification_test.dart; packages/host/test/it/codex_test.dart`.
   - **Test map preamble:** append:
     > "A row naming several files is green only when its named test passes in every listed file; a row naming the qualification record is green only after task 8.3 records the approved observation."
   - **Traceability text:** replace "Test-map rows above are unchanged" with:
     > "Test-map rows are unchanged except for the Round 3 end-to-end file additions".

   **Recheck: applied.**
   - **Task 4.1, `tasks.md:157`:** contains the regression sentence word for word. The phrase "capability refusal before spawn" no longer appears in `tasks.md`.
   - **Rows `tasks.md:128-133`:** each adds `packages/host/test/it/codex_test.dart`.
   - **Rows `:134-135`:** each adds `packages/host/test/it/agent_qualification_test.dart`.
   - **Rows `:136-137`:** each adds `packages/desktop/test/codex_agent_test.dart`.
   - **Rows `:138-139`:** each adds both host and desktop files.
   - **All of these rows:** the codec file comes first, the test names are unchanged and the state stays red.
   - **Row `:119`:** the file and test name match the required text exactly.
   - **Row `:120`:** the files match exactly.
   - **Preamble, `tasks.md:5`:** ends with the required sentence.
   - **Traceability text, `tasks.md:189`:** reads "Test-map rows are unchanged except for the Round 3 end-to-end file additions". I compared this against the baseline. No other row changed.

3. **Row ownership and authentication wording (M3).**
   - **Task 4.3:** append:
     > "Include the host rows Known Codex authentication failure and Unknown auth-like diagnostic for start and turn errors, with any signature supplied only through the test-host candidate override and never through Claude's classifier."
   - **Task 6.1:** append:
     > "Add and pass the desktop row Codex restores through native history in packages/desktop/test/codex_agent_test.dart."
   - **Task 7.1:** after "Idle root with active children", insert:
     > ", Codex native interruption completes, One child interruption is unsupported"
   - **Task 5.1:** replace "Preserve exact-version auth evidence rules;" with:
     > "Show Codex sign-in guidance only for a signature confirmed by recorded real evidence, applying a confirmed signature to every admitted Codex version (D7);"

   **Recheck: applied.**
   - **Task 4.3, `tasks.md:159`:** ends with the authentication-row sentence word for word.
   - **Task 6.1, `tasks.md:169`:** ends with the desktop restore sentence word for word.
   - **Task 7.1, `tasks.md:175`:** reads "Idle root with active children, Codex native interruption completes, One child interruption is unsupported and stalled transcript credit".
   - **Task 5.1, `tasks.md:164`:** contains the replacement word for word, followed by "unknown auth-like errors remain native diagnostics". "Preserve exact-version" no longer appears in `tasks.md`.
   - **Consistency with D7:** it matches D7 (`design.md:167`): "Confirmed auth signatures apply to every admitted Codex version; version metadata identifies the observation, not a sign-in-guidance gate. Never reuse Claude's classifier." Task 4.3's "never through Claude's classifier" also matches that last sentence.

4. **Verification (M4).**
   - **Task 2.2:** replace "Verify 2.1 plus acp_client_test.dart, agent_session_transport_test.dart and agent_event_relay_test.dart." with:
     > "Verify 2.1 plus acp_client_test.dart, agent_session_transport_test.dart, agent_event_relay_test.dart and agent_session_test.dart directly, then mise run check and mise run test:host before committing."
   - **Workflow follow-up:** add the bullet:
     > "Every group that changes packages/host, packages/host_protocol or process containment runs mise run check and mise run test:host before it is ticked and committed; desktop-only groups run mise run check plus the affected flutter test files."

   **Recheck: applied.**
   - **Task 2.2, `tasks.md:149`:** contains the replacement word for word.
   - **Workflow follow-up, `tasks.md:209`:** contains the bullet word for word.
   - **Cosmetic, non-blocking:** `tasks.md:210` is a blank line between this bullet and the next. It makes the list render loose. It is not a required edit.

5. **Fixture isolation from the installed Codex (M5).** Task 4.1: append:
   > "Codex discovery honours the existing test runtime PATH/DIRS overrides, and every fixture start selects its scripted profile explicitly (ADR 0012), so no test can launch an installed real Codex or make a provider call."

   **Recheck: applied.** Task 4.1 (`tasks.md:157`) ends with this sentence word for word.

6. **Stale group reference (M6).** Add a traceability table row:

   | Former task | Revised task(s) |
   |---|---|
   | Research record "group 3 fixtures" (docs/qualification/codex-app-server.md:111) | 4.2 red version/mismatch rows; 4.4 implementation |

   This leaves the completed 1.2 artifact unchanged.

   **Recheck: applied.**
   - **Traceability row:** `tasks.md:205` contains it word for word.
   - **Completed tasks:** 1.1 and 1.2 (`tasks.md:143-144`) are unchanged against the commit-57e9f55 baseline. Neither is unticked.

**Focused recheck result:** Required Changes 1–6 are all applied and agree with each other, with D7 and with the commit-57e9f55 baseline for the completed tasks and the unaffected test-map rows. No edits remain.

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

None yet.