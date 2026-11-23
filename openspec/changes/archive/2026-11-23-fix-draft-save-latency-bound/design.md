# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | no | Test files only: `packages/host/test/it/draft_store_test.dart`, `packages/host/test/it/support/draft_support.dart` |
| T2 State (persistent state, caches, 3+ state machine) | no | No stored data or state machine changes; the draft store is untouched |
| T3 Concurrency (background work, workers/isolates, async, retries) | no | The host's worker and deadline are unchanged. The test helper waits for an existing notification and retries a test call, which is test-side sequencing, not product concurrency |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | no | No message, field, error code or file format changes. The spec text changes a latency bound, and the wire is identical |
| T5 Volume (grows without a fixed bound) | no | None |
| T6 Risk (security, money, data loss, unrecoverable user data) | no | Draft durability rules (journal, sync, secure delete) are unchanged |

TIER: LIGHT

## Context

See proposal.md for the failures and the CI evidence.

- A draft operation is answered only after the worker commits it. The worker runs `BEGIN IMMEDIATE`, the change, then `COMMIT` (`packages/host/lib/src/agent/draft_store.dart:642-661`). The file is opened with `journal_mode = DELETE`, `synchronous = EXTRA` and `secure_delete = ON` (`draft_store.dart:555-557`).
- Each operation has a host-side deadline. When it fires, the call fails `draft-unavailable` "the draft store did not answer in time", and the store counts as not responding (`draft_store.dart:219-227`, `:84`). While it is not responding, the next call fails at once (`draft_store.dart:210-212`). When the late operation returns, the count drops back. At zero, with the store available, the host sends `agent/draftStoreReady` (`draft_store.dart:254-258`, `packages/host/lib/src/agent/agent_service.dart:1641-1647`), and the test desktop counts it (`packages/host/test/it/support/harness.dart:196-197`, `:237`). A commit that missed its deadline is still committed (`draft_store.dart:254-259`: its result is dropped, not rolled back), and the "released commit" test relies on that (`packages/host/test/it/draft_store_test.dart:762-763`).
- The tests shorten the deadline to 1000 ms with `KUMIKO_TEST_DRAFT_DEADLINE_MS` (`draft_store_test.dart:36`, read at `packages/host/lib/src/test_hooks/test_hooks.dart:137`). Every operation of that host gets the shortened deadline, not only the held one.
- Calls in `quick` tests that are not wrapped in `refusal(...)`, and so fail the test when a commit is slow:
  - "held commit refuses send": `:477`, `:502`, `:504`;
  - "released commit clears not responding": `:740`, `:763`, `:764`.
- "draft save acked … under saturated output" asserts the worst of 20 saves ≤ 250 ms (`draft_store_test.dart:200-213`). That host runs with the default deadline (`:155`, no `env`), which is 5 s (`draft_store.dart:48`; ADR 0014 decision 14).
- The draft store starts after the host's other work and accepts calls while `starting`. Those calls are queued until the file is open (`draft_store.dart:202-204`, `:428-434`, `:592-593`), so the first save's deadline also covers the open. The tests have a `storeReady` helper that waits for phase `available` (`draft_store_test.dart:72-75`).

## Decisions

### D1: The saturated-output row asserts success within the draft deadline and keeps the measurement

- **Choice:** Every one of the 20 saves must return its revision; a save past the draft deadline fails with `draft-unavailable` and so fails the test. The stored row must hold the last text and revision, and terminal A must keep flowing. Remove the `≤ 250 ms` expectation. Keep the `measured:` print unchanged. Also assert the worst time, measured at the desktop from request to acknowledgement, against the default draft deadline: the host's own timer starts only once it dispatches the save, so the end-to-end check covers the queueing before it. Then hold one commit open (`draftCommitHangs`) and require A's output to keep arriving while the save is still unanswered, so "keeps arriving while it commits" is checked during a commit, not only between commits.
- **Rejected:** Relying on the host's own refusal alone for the deadline: its timer misses time spent before dispatch (pre-ship review round 1). Moving the Windows test profile to the runner's other disk loses for the reasons in proposal S1.
- **Reversal cost:** low
- **Important:** yes. It carries the contract change in proposal S1 (binds future changes).
- **Chosen by:** user (proposal S1)

### D2: Test calls that must succeed wait out a slow commit instead of failing on it

- **Choice:** Add two helpers to `test/it/support/draft_support.dart`, used only for the precondition and follow-up calls of tests that run with a shortened deadline, and of the draft-cap test, whose 128 fill saves of 256 KiB each run under the default deadline and missed it once on a Windows runner (PR #27 CI):
  - `settledSave`: on `draft-unavailable`, wait until `agent/draftStoreReady` has arrived after the call, then load. If the save landed late, accept it; otherwise save again.
  - `settledLoad`: the same wait, then load again.
  
  A real refusal still fails the test, as does a save that neither landed nor succeeds on the retry, or a store that never becomes ready (the existing `eventually` limit). Also wait for `storeReady` before the first save in those tests, so the shortened deadline does not cover the open.
- **Rejected:** Raising the shortened deadline (for example to 2500 ms) and widening the `inInclusiveRange(900, 3000)` checks. It only moves the threshold: a 2.5 s commit fails the same way, and every held-commit test gets slower. Rejected too: a separate per-fault deadline in the host's test hooks. That changes host code for a test-only need.
- **Reversal cost:** low
- **Important:** no. Test only. The held-send refusal, its timing range and the immediate second refusal are asserted exactly as before.
- **Chosen by:** agent

### Decision summary

| # | Decision | Choice | Rejected | Reversal cost | Important | Chosen by |
|---|---|---|---|---|---|---|
| S1 | Draft save bound under saturated output | Draft deadline, not control latency | Keep 250 ms and move the CI disk; known-flake note; per-platform bound; subtract commit time | low | yes | user |
| S2 | Held-commit flake in the same change | Yes | Separate change | low | no | agent |
| S3 | `terminal/activity` bound | Unchanged | Relax both | low | no | agent |
| D1 | Saturated-output test assertion | Every save succeeds, stored row matches, A flows, including during a held commit; desktop-measured worst ≤ draft deadline; keep the `measured:` print | Host refusal as the only deadline check; move the disk | low | yes | user |
| D2 | Precondition calls of shortened-deadline and draft-cap tests | `settledSave`/`settledLoad` wait for `draftStoreReady`; `storeReady` before the first save | Longer test deadline; per-fault host deadline | low | no | agent |

## Assumptions

- **A1:** The failing call in CI run 45202879686 was one of the un-held calls listed in Context, not the held send. Not checked because the CI output has no stack trace for the `RpcException`. The message, "did not answer in time" (`draft_store.dart:225`), can only come from a call that waited for its deadline, and the held send is wrapped in `refusal(...)`. Depends on it: D2.

## Carried constraints

- **C1:** A draft save's acknowledgement includes a durable commit, so its latency is bounded by the draft deadline and not by the control-latency bound. Control responsiveness under saturation is qualified by Stop and permission replies. Kind: invariant. Destination: spec: specs/desktop-host-protocol/spec.md → Requirement: Activity and draft requests are bounded
- **C2:** With a shortened test draft deadline, every draft call of that host shares it. A call that must succeed wraps its draft operation in `settledSave`/`settledLoad`. Kind: invariant. Destination: doc comment: packages/host/test/it/support/draft_support.dart settledSave
