# Review

## Metadata

- **Round:** 3
- **Prior round:** Round 2 returned APPROVE_WITH_CHANGES with CHANGES_APPLIED: yes. It confirmed all five round-1 required changes and found no open Critical or Moderate findings. After that, OpenSpec strict validation required shortening the requirement text to 500 characters or fewer. The requirement and the WHEN lines of "Recall the last accepted prompt" and "Recall skips a refused prompt" were tightened. This round is a fresh full review of the resulting text.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, claude-opus-5-5)
- **Reviewed:** `openspec/changes/agent-chat-composer-keys/{proposal.md, design.md, specs/agent-sessions/spec.md, review.md (round 2)}`; `openspec/specs/agent-sessions/spec.md` (composer and draft requirements, 363-484); `packages/desktop/lib/src/agent/agent_controller.dart` (40-264, 728-942, 1360-1451); `packages/desktop/lib/src/agent/agent_pane_view.dart` (300-369); `packages/desktop/lib/src/agent/agent_transcript.dart` (70-150); `packages/desktop/lib/src/workbench_page.dart` (1364-1387); `packages/host_protocol/lib/src/messages.dart` (`maxAgentPromptBytes`, 1794); `docs/adr/0014-app-exit-decisions-terminal-activity-and-local-drafts.md`; ADR 0004 and ADR 0017 (presence only); `.claude/skills/flutter-add-widget-test/SKILL.md`; `openspec/schemas/specwright/templates/review.md`.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

None. The shortened delta still states the same behavior as the proposal and design. Each point below was checked against both documents and the source.

- **Enter follows Send.** The requirement says "unmodified Enter follows Send". This matches the proposal ("when Send allows it … does nothing for a blank draft or while Send is disabled") and D1 ("Use the same send callback as the button; consume blocked Enter").
  - The Send button calls `controller.send(id, link.prompt.text)` behind `link.canSend` (`agent_pane_view.dart:346-351`).
  - `send` checks `canSend` again and returns early on whitespace (`agent_controller.dart:1379-1381`).
  - So "follows Send" covers both the blank-draft case and the disabled case. The scenario "Enter on a blank draft or during a reply" still says "the draft remains unchanged … does not send, queue, or steer", which matches S1.
- **Draft safety.**
  - Blocked Enter is consumed and inserts no newline (D1). This matches "the draft remains unchanged".
  - Recall is "an ordinary composer edit … do not mute the draft listener" (D2). It goes through `_promptChanged` → `draft.edit()` (`agent_controller.dart:150-155`) and not through the muted `_setComposer` (`158-169`). This matches "Recall SHALL edit the draft without sending".
  - A recalled prompt left unsent can be stored as a draft. D2 states this, and it is the user's own new draft under ADR 0014 decisions 8-11. It does not keep a sent prompt in recall history, so D29 holds.
  - A late acknowledgement cannot discard recalled text. Flow & State Gaps bullet 3 relies on `unchangedSince` and the text-equality guard at `agent_controller.dart:1419-1430`, and both still back it.
- **IME safety.** The requirement says IME-confirming Enter "SHALL NOT send". The IME scenario adds "or inserting a line break". The Shift+Enter scenario keeps "outside IME composition". Together they still carry C1 ("does not intercept IME confirmation to submit or add text").
  - D1's signal (`link.prompt.value.composing.isValid` at key-down), A1, and the manual Windows check before archive (`design.md:103`) are unchanged.
  - D1 hands every handled key to the platform during composition, including Up. This is stricter than the spec and does not contradict it.
- **Recall scope.**
  - "last accepted prompt only into an empty composer" plus "without … reading saved history" in the requirement keeps S2 and C2.
  - The scenario "Recall does not cross conversations or restore history" still covers closing and reopening a pane and restarting the app.
  - The design's lifetime claims still match the source:
    - `sync()` creates links with `putIfAbsent` (`761-783`).
    - Removing a pane disposes its link (`785-801`).
    - *New session* creates a new link (`919-937`).
    - `detach()` and `restore()` keep the same link (`733-759`, `806-869`).
- **Refused-prompt scenario.** "Prompt B was refused before dispatch" still separates D2 from reading `lastPrompt` when B is refused by the host. `link.lastPrompt = text` runs at `1402`, before `promptAgent` throws at `1432`. D2 changes the recall slot only after a successful result. See Suggestion 1 for the remaining ambiguity.
- **Citations.** The design's cited sources still say what the design claims:
  - `workbench_page.dart:1369-1383`
  - `agent_transcript.dart:75-97,145-149`, which shows text merging and eviction
  - `messages.dart:1794`, which sets 256 KiB
  - `agent_controller.dart:250-257`, `1382-1392` and `1397-1449`
- **Length.** The requirement is about 430 characters, within the 500-character limit.

### Suggestions

1. **"Refused before dispatch" can be read two ways.** The base spec uses "refused … before it reaches the adapter" for host refusals (`store-error`, `draft-unavailable`; `openspec/specs/agent-sessions/spec.md:440, 468, 476`). Under that reading, B is the case that tells D2 apart from `lastPrompt`. But design T5 also calls the local 256 KiB rejection "before dispatch" (`design.md:11`), and that path returns at `agent_controller.dart:1382-1392`, before `lastPrompt` is set. Both readings require the same behavior from D2, so the spec needs no change. Round 2's test advice still applies, more firmly now: per `flutter-add-widget-test`, make B a host refusal by having a fake `promptAgent` throw `RpcException` (for example `store-error`). Do not use an oversized prompt.
2. **Two invariants are only in scenarios, not in the requirement text.** "No line break on IME confirmation" and "this open conversation" appear in scenarios and in the proposal and design, but not in the requirement text. Scenarios are binding, so nothing is lost. If a later edit frees characters, consider adding "or insert a line break" to the IME sentence. This is not required.

## Verdict

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None.