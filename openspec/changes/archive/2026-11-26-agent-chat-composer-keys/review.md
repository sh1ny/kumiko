# Review

## Metadata

- **Round:** 4 (recheck of the required change)
- **Prior round:** Round 3 returned APPROVE with CHANGES_APPLIED: n/a and no Critical or Moderate findings. After that, the author edited `design.md` to add a Windows-only refinement to D1. During composition, D1 now claims an Enter that reaches Flutter. The D1 summary row, A1 and the Risks native check were updated to match. Because of that edit, the round-3 verdict no longer applied, and round 4 was a new full review. It returned APPROVE_WITH_CHANGES with one Required Change: record a Linux/macOS assumption as A2. This recheck covers only that change.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, claude-opus-5-5)
- **Reviewed:** For round 4: `openspec/changes/agent-chat-composer-keys/{proposal.md, design.md, specs/agent-sessions/spec.md, tasks.md, review.md (round 3)}`; `openspec/schemas/specwright/schema.yaml` (design and review instructions) and `templates/review.md`; `mise.toml` (Flutter pin, line 5); `openspec/architecture.md` (supported platforms, lines 232 and 255); `packages/desktop/lib/src/agent/agent_controller.dart` (40-269, 728-1047, 1370-1451); `packages/desktop/lib/src/agent/agent_pane_view.dart` (290-379); `packages/desktop/lib/src/agent/agent_transcript.dart` (72-151); `packages/desktop/lib/src/workbench_page.dart` (1366-1385); `packages/host_protocol/lib/src/messages.dart` (1794); `docs/adr/0014-app-exit-decisions-terminal-activity-and-local-drafts.md` (38-46); `.claude/skills/flutter-add-widget-test/SKILL.md`. The Flutter 3.47.9 Windows engine lines (`keyboard_key_embedder_handler.cc:177-184`, `flutter_windows_view.cc:599-617`, `text_input_plugin.cc:86-104,483-502`) came from the author. They are outside the repository, so they were not opened; this review treats them as evidence supplied by the author. The untracked `packages/desktop/test/agent_composer_keys_test.dart` was not opened.
  For this recheck: `review.md` (round 4), `design.md` (full), `specs/agent-sessions/spec.md`, and `openspec/schemas/specwright/templates/review.md`. The Flutter 3.47.9 Linux `fl_text_input_handler.cc:499-539` and macOS `FlutterTextInputPlugin.mm:647-675` lines came from the author. They are outside the repository and were not opened, so they are treated as evidence supplied by the author. No diff was run. The finding that nothing else changed comes from comparing D1, the decision summary, A1, C1 and Risks with the round-4 record; they match, and the spec matches the scenarios quoted in round 4.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

1. **Resolved in recheck: the IME scenario on Linux and macOS depended on an assumption the design did not record.**
   - **Original finding.** The scenario "Confirm an IME candidate" applies on every platform, and Kumiko ships on Windows, Linux and macOS (`openspec/architecture.md:232,255`). On Windows, D1 claims a composing Enter. On the other platforms, D1 only passes the Enter on. No assumption covered what the platform does with that passed-on Enter, and A1 covers Windows only.
   - **Fix.** `design.md:50` now has A2. On Linux and macOS, an Enter that D1 passes on during candidate confirmation "is handled by the platform IME and does not become a newline or a second commit". A2 names what depends on it: D1's pass-through and the scenario on those two platforms. It also says what happens if it fails: D1 reopens for that platform.
   - **Recheck.** A2 records the required assumption and keeps two things apart:
     - **Engine routing (author-read).** "The pinned SDK routes unclaimed keys through GTK or AppKit text input." This matches the author's evidence: GTK's IME filter runs before the newline path, and AppKit text input handles unclaimed events.
     - **OS candidate behavior (unproven).** "Actual IME output on those platforms has not been checked."
     - **Consistency.** A2 agrees with C1 ("does not intercept IME confirmation to submit or add text") and with the spec scenario (`specs/agent-sessions/spec.md:17-19`). D1, the D1 summary row, A1 and the spec are unchanged.
   - **Accepted deviations from the Required Change text.**
     - **Failure path.** The required wording said a failure means "apply the Windows claim there too". A2 instead only reopens D1 for that platform. Accepted by the reviewer, and it is the better wording. A Linux or macOS IME may need that Enter event, so consuming it as Windows does cannot be decided before investigation.
     - **Scope phrase.** "During candidate confirmation" replaces "during active composition". Here the two mean the same thing, because the dependent scenario is the confirmation case.

### Suggestions

1. **Write down the engine evidence the author has already checked.**
   - A1 still says the pinned engine "is expected to run its multiline fallback only if the app does not claim the event", and it leaves this to task 1.1. The author has since read the pinned 3.47.9 sources.
   - The source sits outside the repository, so it cannot be a design citation. Keeping it in A1 is correct.
   - When task 1.1 is ticked, record the Flutter version (`mise.toml:5`) and the three engine files and line ranges in task 1.1's completion note. A later Flutter upgrade can then re-check the same lines. Add the Linux and macOS files from A2 too.

2. **Detect the platform in a way widget tests can switch.**
   - "On Windows only" should come from `defaultTargetPlatform == TargetPlatform.windows`, not from `dart:io` `Platform.isWindows`.
   - Then the IME row in the test map can use a `TargetPlatformVariant`. It can assert that Windows claims the event (`simulateKeyDownEvent` returns `true`, draft unchanged, nothing sent) and that other platforms ignore it (returns `false`, draft unchanged, nothing sent). This works on any CI host and stays deterministic under ADR 0017.
   - With `Platform.isWindows`, the non-Windows branch could not be tested on a Windows host, and the Windows branch could not be tested on any other host.

3. **Say whether the Windows claim also covers a modified Enter.**
   - D1's Windows sentence says "a composing Enter". Elsewhere D1 defines Enter as both Enter keys and "plain" as unmodified. So it is unclear whether Shift+Enter (or Ctrl+Enter) during composition is also claimed.
   - The author's evidence says the engine fallback acts on `VK_RETURN` and inserts a newline for multiline. If that holds whatever modifiers are pressed, an unclaimed Shift+Enter reaching Flutter mid-composition would insert a newline. That would break the IME scenario's "without … inserting a line break".
   - IMEs normally consume Shift+Enter as `VK_PROCESSKEY`, so this is unlikely. A short phrase such as "any Enter key-down or repeat, regardless of modifiers, while composing" would settle it, and the same widget test could cover it.

4. **The refinement checks out.** The checks behind this conclusion:
   - **Raw Enter is safe.** Claiming a raw Windows Enter while `composing.isValid` adds no send path, because D1 still stops all shortcuts during composition. It only stops the engine's unhandled-key fallback. That is the one path left by which a confirming Enter could insert a newline on Windows.
   - **IME-processed Enter is unchanged.** Per the author's evidence, an Enter the IME processes never reaches Flutter as a key event.
   - **The follow-up Enter is tested both ways.** A1 names the remaining ordering question: does the composing range clear before the next deliberate Enter? A1 sends that question to the native check, and it matches `design.md:104` and task 2.1, which cover both IMEs, the Windows build, the tested commit, and that a failure reopens D1.
   - **Test map routing is correct.** The candidate UI can only be judged by a person, so it goes to the `[user]` task. The claim and the follow-up send are testable, so they stay in the widget test (task 1.1, row 3 of the test map).
   - **Outside composition, the scenarios still hold.** Blocked Enter is consumed, and Shift+Enter is applied as one value replacement and claimed. So on Windows, neither path can add a second newline through the engine fallback. This supports the scenarios "Enter on a blank draft or during a reply" and "Insert a line break with Shift+Enter".
   - **Carried constraints still cover it.** C1 still describes the behavior ("does not intercept IME confirmation to submit or add text"). Its single spec destination holds.
   - **No user-chosen decision changed.** Scope (S1, S2), the requirement text, the scenarios and the draft rules are unchanged from round 3. D1 is `Chosen by: agent`, and in `autonomous` mode this refinement needed no question to the user.

5. **The citations still support their claims.**
   - `agent_controller.dart:250-257` (Send gate), `1376-1381` (whitespace and gate check), `1382-1392` (256 KiB local rejection, `messages.dart:1794`), `1397-1417` (`lastPrompt` set at 1402 before `promptAgent`), `1418-1430` (unchanged-draft clear), `1432-1449` (refusal and latch release).
   - Link lifecycle: `761-783` (`putIfAbsent`), `785-801` (removal disposes the link), `919-937` (new session creates a new link and carries only the composer value, not the recall slot), `740-758` (`detach` keeps the link), `806-869` (`restore`), `985-1044` (Continue reuses the link).
   - Elsewhere: `agent_pane_view.dart:327-351`, `workbench_page.dart:1369-1383`, `agent_transcript.dart:75-97,145-149`, and ADR 0014 at 42-46.
   - The design's lifetime claims for the recall slot match the source.

6. **A2's failure trigger points to a check that has not been planned.**
   - A2 ends with "A failed native check reopens D1 for that platform". The only native check in the design, at `design.md:104`, is on Windows (A1, task 2.1).
   - Round 4 required only that the assumption be recorded, so this does not block. Still, "a failed native check" can make readers think Linux and macOS are covered.
   - If the design text is reopened later, either reword it ("If it is found to fail on a platform, D1 reopens for that platform") or add an optional `[user]` check on Linux and macOS. Each IME, platform build and outcome would be recorded the same way as on Windows.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. In `design.md` under `## Assumptions`, add after A1:
   `- A2: On Linux and macOS, an Enter that D1 passes on during active composition is handled by the platform input method and does not become a newline or a second commit in the multiline composer. Not checked: the engine source is outside the repository and only the Windows engine was read. Depends on it: D1 (non-Windows pass-through) and the "Confirm an IME candidate" scenario on those platforms. If it fails on a platform, apply the Windows claim there too, which reopens D1.`
   Do not change any other part of D1, the decision summary or the spec.
   - **Recheck:** Applied at `design.md:50`. The reviewer accepts the wording differences recorded under Moderate 1. The failure path no longer prescribes the Windows claim, because consuming the Enter on another platform needs investigation first.

CHANGES_APPLIED: yes

## Rebuttals

- **Moderate 1.** Fixed at `design.md:50` (A2); the reviewer re-checked it. The failure path now reads "reopens D1 for that platform" and no longer requires applying the Windows claim there. The reviewer accepts this deviation.