# Proposal

## Why

A test must never fail because the runner is slow (issue #28). The draft-store tests in `packages/host` break that rule in three ways:

- **Short real deadlines.** Each test host starts with one global shortened draft deadline (`KUMIKO_TEST_DRAFT_DEADLINE_MS`, 800 or 1000 ms). Every draft call gets it, including incidental saves and loads that the test does not measure, so a slow fsync on a loaded runner turns them into `draft-unavailable`. PR #27 papered over this with the `settledSave`/`settledLoad` retry helpers, and still needed three CI rounds.
- **Wall-clock assertions.** "Fails at once" is checked as under 250 ms, "the deadline fired" as 700–3000 or 900–3000 ms, Stop and permission replies during a held commit as at most 250 ms, and the save under saturated output as at most 5 s. The unit tests of the worker add 100 and 200 ms caps, a 380–1500 ms window and an fsync median under 100 ms. More time alone can turn each of these red.
- **A weak synchronisation** (issue #26, waived pre-ship finding F1 of #25). The saturated-output row releases the held commit once `pending == 1`, which only shows that the host registered the save, not that the worker reached the hold. Its byte-count check can be met by one chunk already in flight.

This change is the first slice of #28 and covers #26: the draft-store tests. It also writes #28's ten rules into `AGENTS.md`, so new tests follow them, and removes the `AGENTS.md` advice to re-run known flaky timing rows, which contradicts rule 8.

Milestone: **M2 – Daily-driver workbench (Windows)**, exit criterion "Main CI builds the Windows desktop with bundled host…". A Windows job that fails on unrelated commits works against it. This is a test and tooling fix outside the milestone's numbered change list, and it advances no user-verified criterion.

## What Changes

- **Deadlines fire on demand in tests.** A test hook fires the draft deadline of the pending operations explicitly, once the worker has reported that it reached the stage under test: a held commit, or a held open. No test relies on a short real budget.
- **Test hosts get a generous normal draft deadline**, so it only guards against hangs. The production 5 s deadline, and the "fails at once while not responding" path, are proven on a fake clock in a unit test of the store.
- **The worker reports the hold.** `test/draft.stats` gains `heldCommit`, the id of the commit held at the moment (null when none), and `openHeld`, whether the first open is held at its gate. The saturated-output row waits for a held commit, then requires terminal output that the fixture emits only after the hold began, and tracks the original save request apart from any retry.
- **Order and occurrence instead of elapsed time** in `draft_store_test.dart` and `draft_store_worker_test.dart`: "fails at once" means refused while the held operation is still held; "not queued" means answered before the hold is released; Stop and permission replies are answered while the commit is still held. Real time stays only as an outer hang guard per test. The one exception is a known gap, decided by the owner (design D12): the inner cleanup budgets of process containment, left to a later slice of #28. The `measured:` prints stay, as information only; the fsync median becomes one.
- **`settledSave`/`settledLoad` are removed**; ordinary draft calls no longer need them.
- **`AGENTS.md`**: a new section "Tests that run in Windows CI" with the ten rules of #28, and the bullet that tells agents to re-run timing rows alone is removed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. The product's draft deadline (5 s), the control-latency bound and every draft scenario stay as they are. Only how the tests prove them changes, and the latency bounds remain for a later qualification slice of #28. The change sets `skip_specs: true`.

## Impact

- Host test hooks: `packages/host/lib/src/test_hooks/test_hooks.dart`, the draft fault plumbing in `host_faults.dart` and `draft_store.dart` (a held-stage counter and an explicit expiry, active only in test hosts). No protocol, wire or production behaviour change.
- Tests: `packages/host/test/it/draft_store_test.dart`, `test/it/support/draft_support.dart`, `test/agent/draft_store_worker_test.dart`, and the terminal fixture if it needs a post-hold marker.
- Docs: `AGENTS.md`.
- Out of scope, later slices of #28: `terminal_close`, the qualification acknowledgement bounds, the throughput profile and the `mcp_bridge_test` race. Their flaky rows are no longer excused by `AGENTS.md` once this lands.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting. The owner was asked the decisions below anyway, through Ormy on 2026-11-23, and answered "all (a)".

### S1: Fire draft deadlines explicitly in tests

- **Choice:** A test hook fires the pending operations' deadline once the worker reports it reached the hold (held commit or held open).
- **Rejected:** A shortened real deadline applied only to operations the active fault holds. The outcome would be certain, but it keeps a real timer in the test path, which rule 3 asks to avoid.
- **Reversal cost:** low. Test hooks and tests only.
- **Important:** yes. It sets how later slices of #28 test deadlines.
- **Chosen by:** user

### S2: Generous normal draft deadline in test hosts; the 5 s proven on a fake clock

- **Choice:** Test hosts run with a draft deadline of minutes, a hang guard only. A unit test proves the production 5 s and the not-responding path on a fake clock.
- **Rejected:** Keeping 5 s in test hosts: incidental operations would still race a real budget on a slow runner.
- **Reversal cost:** low
- **Important:** yes. It changes what the integration tests can prove about the deadline.
- **Chosen by:** user

### S3: No spec change

- **Choice:** Keep every draft scenario, including its wall-clock wording; the tests prove order. `skip_specs: true`.
- **Rejected:** Rewording the draft scenarios to order now. The latency bounds are product promises, qualified in a later slice of #28.
- **Reversal cost:** low
- **Important:** yes. It decides whether a contract changes.
- **Chosen by:** user

### S4: Include the worker unit tests

- **Choice:** `draft_store_worker_test.dart` timing assertions are in scope; the fsync median becomes a `measured:` print only (rule 7).
- **Rejected:** Leaving them for a later slice: they are the same store and the same failure mode.
- **Reversal cost:** low
- **Important:** no. Test only.
- **Chosen by:** user

### S5: AGENTS.md rules in this change

- **Choice:** Add a section "Tests that run in Windows CI" after Commands, with the ten rules from #28 verbatim, and remove the bullet that says to re-run timing rows alone.
- **Rejected:** A separate docs change: the owner asked for both together.
- **Reversal cost:** low
- **Important:** yes. It binds how every later test is written.
- **Chosen by:** user
