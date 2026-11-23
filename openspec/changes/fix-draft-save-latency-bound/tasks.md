# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| desktop-host-protocol → Activity and draft requests are bounded | Too many terminals | packages/host/test/it/terminal_activity_test.dart | 65 ids refused invalid-params without a table read | green |
| desktop-host-protocol → Activity and draft requests are bounded | Oversized draft | packages/host_protocol/test/agent_messages_test.dart | draft one byte past 256 KiB encoded refused draft-too-large | green |
| desktop-host-protocol → Activity and draft requests are bounded | Unknown session | packages/host/test/it/draft_store_test.dart | bounds and refusals draftSave for unknown session refused unknown-session | green |
| desktop-host-protocol → Activity and draft requests are bounded | Draft save under saturated output | packages/host/test/it/draft_store_test.dart | bounds and refusals draft save acknowledged within the draft deadline under saturated output | green |

## 1. Draft save under saturated output (S1, D1)

- [x] 1.1 Re-run the unchanged rows to confirm they still pass: `mise exec -- dart test test/it/terminal_activity_test.dart -N "65 ids refused"` and `mise exec -- dart test test/it/draft_store_test.dart -N "unknown-session"` in `packages/host`, and `mise exec -- dart test test/agent_messages_test.dart -N "draft-too-large"` in `packages/host_protocol`. All three pass.
- [x] 1.2 In `draft_store_test.dart`, rename the row to "draft save acknowledged within the draft deadline under saturated output" and rewrite its assertions per design D1:
  - each of the 20 saves returns its revision;
  - the stored row then holds the last text at revision 20;
  - terminal A kept flowing;
  - no `≤ 250 ms` expectation, and the `measured:` line printed unchanged.
  
  Verify: run that test alone, and it passes. Flip its Test map row to green.
- [x] 1.3 C1: confirm the fact is at its destination, `specs/desktop-host-protocol/spec.md` → Requirement "Activity and draft requests are bounded" in this change. Verify: `openspec validate fix-draft-save-latency-bound --strict` passes.

## 2. Shortened-deadline tests wait out a slow commit (S2, D2)

- [x] 2.1 Verify A1: confirm that "the draft store did not answer in time" is raised only by the deadline timer (search `packages/host/lib` for the string; expect only `draft_store.dart` `_run`), and that the held send in "held commit refuses send…" is wrapped in `refusal(...)`. Together these settle that the CI failure came from an un-held call. If either check fails, stop: that is design drift.
- [x] 2.2 Write a failing test in `draft_store_test.dart`, "a save that outlives the shortened deadline is waited out", in a host with `quick`:
  - hold the commit with `draftCommitHangs`;
  - start a save of revision 1 through the new `settledSave`;
  - release the fault after the deadline;
  - expect the save to resolve, and the store to hold that text at revision 1.
  
  Verify: it fails before the helper exists (with a plain `drafts.save` in its place it fails `draft-unavailable`).
- [x] 2.3 Implement `settledSave` and `settledLoad` in `test/it/support/draft_support.dart` per design D2, with the C2 doc comment on `settledSave`. Verify: the 2.2 test passes, and the C2 text is in the doc comment.
- [x] 2.4 Use `storeReady` before the first save, and `settledSave`/`settledLoad` for the un-held calls, in "held commit refuses send draft-unavailable within the deadline" (`:477`, `:502`, `:504`) and "released commit clears not responding and sends draftStoreReady" (`:740`, `:763`, `:764`). Leave every `refusal(...)` assertion and timing range unchanged. Verify: run both tests alone 10 times in a row (`-N` per test); they pass every time, and `git diff` shows no edited `refusal(...)`, `inInclusiveRange` or `lessThan(250)` line.

## 3. Integration

- [ ] 3.1 `mise run check` passes (format, analyze, fast tests).
- [ ] 3.2 `mise run test:host` passes. Re-run any of the AGENTS.md timing rows alone before treating its failure as real.

## Workflow follow-up

- Ship through `specwright-pr`; the PR body says "Fixes #25".
- After merge, archive the change so the delta lands in `openspec/specs/desktop-host-protocol/spec.md`.
