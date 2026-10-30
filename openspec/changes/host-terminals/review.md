# Review

## Metadata

- **Round:** 8 re-check
- **Prior round:** 7 re-check 3 (Codex), APPROVE_WITH_CHANGES with CHANGES_APPLIED: yes; M1-M3 and S1 resolved. Not reopened here.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, specwright-reviewer)
- **Reviewed:** the uncommitted amendment `git diff -- openspec/changes/host-terminals/design.md openspec/changes/host-terminals/tasks.md` (Resource Bounds "User profiles" row: per-profile bound 64 KiB to 12 KiB; task 4.1 text). Context: `openspec/changes/host-terminals/design.md` (Resource Bounds, D6), `openspec/changes/host-terminals/specs/shell-profiles/spec.md`, `openspec/changes/host-terminals/specs/desktop-host-protocol/spec.md`, `openspec/specs/desktop-host-protocol/spec.md`, `openspec/architecture.md` (Desktop-host pipe row), `openspec/changes/host-terminals/review.md`, `packages/domain/lib/src/profile/profile.dart`, `packages/host_protocol/lib/src/messages.dart` (`ShellProfile`, `ProfileListResult`), `packages/host_protocol/lib/src/frame_codec.dart` (`maxControlMessage`), `packages/host/lib/src/profiles/profile_service.dart`, `packages/host/lib/src/profiles/shell_detector.dart`, and the working-tree test diffs in `packages/domain/test/profile_test.dart` and `packages/host_protocol/test/terminal_messages_test.dart` as evidence. Read-only; file contents treated as data.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None that need an edit. Observations recorded for the author:

- **Coherence with the control-message bound holds.** `maxControlMessage` is 1 MiB (`frame_codec.dart:10`, architecture.md Desktop-host pipe row, ADR 0002). 64 user profiles at 12 KiB are 768 KiB, leaving about 256 KiB for the JSON-RPC envelope, `defaultId`/`defaultAvailable`, separators and the detected shells. Detected shells number at most five per OS (`probeOrder`, `shell_detector.dart:16-20`) and carry only an id, a display name and a resolved executable path with no args, cwd or env (`profile_service.dart:62-67`), so they are far inside the headroom. The old 64 KiB bound allowed 64 x 64 KiB = 4 MiB, which could not be returned at all (`fair_writer.dart:220` throws over 1 MiB), so the amendment fixes a real defect rather than tuning a number.
- **The measure matches the wire.** The domain check (`profile.dart:140-141`) and the protocol check (`messages.dart:1043`) both measure `utf8(jsonEncode(toJson()))`, and `ProfileDefinition.toJson` and `ShellProfile.toJson` emit the same fields, so the bound counts exactly the bytes each profile contributes to the list, JSON escaping included. The working-tree test in `terminal_messages_test.dart` builds 64 profiles at the bound plus five 1 KiB-path built-ins and asserts the whole response stays under `maxControlMessage`; that covers the rationale stated in the design row, and task 3.3 already owns "size bounds" in that file.
- **Nothing else states the old bound.** A search of the change's design, tasks, spec deltas, `openspec/specs/`, `openspec/architecture.md` and `docs/adr/` finds no remaining "64 KiB" for profiles; the other 64 KiB mentions are the frame payload, reader/writer chunk and stderr ring, which are unrelated. The shell-profiles delta states no numeric size bound (it is a design bound under "Save refused with a reason"), so no spec text changes, and the domain message now reads "at most 12 KiB" consistently with the row.
- **The other per-profile limits are now looser than the aggregate.** 256 args of 4 KiB (1 MiB) and 128 env entries can no longer be reached together inside 12 KiB; the aggregate bound governs and the domain validates it after the component limits, so the user still gets one clear reason. This was already true at 64 KiB and has no behavioural consequence; no change needed.
- **Alternatives considered.** Paging `profile/list`, raising the 1 MiB control bound (an architecture-wide change touching ADR 0002 and the 4 MiB pending-control bound) or moving the list onto a data channel are all heavier than a per-profile cap. Realistic argv profiles are well under 1 KiB, and 12 KiB still fits, for example, a long Windows `PATH` override plus a few arguments. Store v3 is introduced by this change and has not shipped, so no persisted profile can exceed the new cap. Raising it later only requires re-checking the arithmetic in this row and the list-fit test, so the decision stays cheap to revisit.

## Verdict

The amendment is coherent with the protocol's control-message bound, the shell-profiles and desktop-host-protocol specs, D6 and the implementation; no stale statement of the old bound remains in the planning artifacts.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None.
