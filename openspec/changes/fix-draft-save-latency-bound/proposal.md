# Proposal

## Why

`build (windows-latest)` fails intermittently in `packages/host/test/it/draft_store_test.dart` (issue #25), on commits that change no application code. Two rows fail:

- **Draft save under saturated output.** The spec requires the save to be acknowledged within the 250 ms control-latency bound. The measured time is a control round-trip plus a durable draft commit (rollback journal, `synchronous=EXTRA`, `secure_delete=ON`: three syncs per commit; ADR 0014 decision 13). On the Windows runner the test profile sits in the system temp folder on the OS disk. There a lone commit has a median of 15–31 ms with spikes past 300 ms. The worst of 20 saves under saturation was over 250 ms in 3 of the last 14 CI runs: 278, 398 and 473 ms. Linux and macOS stay at 1.5–15 ms, with one Linux outlier at 76 ms. In the same runs, Stop and permissionReply under the same saturation took 1–2 ms. So the control path is healthy, and the row mostly measures the runner's disk.
- **Held commit refuses send within the deadline.** The test shortens the draft deadline to 1000 ms so that the held send is refused quickly. The same shortened deadline also applies to the test's ordinary, un-held save and load calls. On a loaded runner one of them went past 1000 ms and was refused `draft-unavailable`. The failing run took about 9.3 s, against about 1.4 s for a passing one.

A 400 ms draft-save acknowledgement is not visible to a user. Saves are debounced, human-paced and off the control isolate. The desktop saver gives each save a 10 s deadline, and the host gives each draft operation its draft deadline (5 s) (ADR 0014 decisions 10 and 14). The property the 250 ms row was meant to protect is that saturated output and stalled channels do not starve control traffic. That property is already qualified by the Stop and permission-reply rows. The cost of a draft commit is held separately by the unit test `measured: draft save and removal latency`, which fails above a 100 ms median (ADR 0014).

Milestone: **M2 – Daily-driver workbench (Windows)**, exit criterion "Main CI builds the Windows desktop with bundled host…". A Windows CI job that fails on unrelated commits works against that criterion. This is a small fix outside the milestone's numbered change list. It advances no user-verified criterion.

## What Changes

- Amend `desktop-host-protocol` / "Activity and draft requests are bounded":
  - `terminal/activity` keeps the control-latency bound under saturated output.
  - An `agent/draftSave` under saturated output must instead be answered within the draft deadline, and the saturated terminal keeps flowing.
  - The control-latency claim stays with Stop and permission replies, which other requirements already bound.
- `draft_store_test.dart` "draft save … under saturated output": drop the 250 ms assertion. Assert that every save succeeds within the draft deadline and that terminal A keeps flowing. Keep the `measured:` line, so the time is still recorded on every platform.
- `draft_store_test.dart` "held commit refuses send draft-unavailable within the deadline", and "released commit clears not responding", which has the same exposure: make the shortened deadline apply only to what each test measures. Wait until the store is available before the first save, and let the ordinary save and load calls wait out a slow commit instead of failing on a 1000 ms deadline. The held operation is still refused `draft-unavailable` within its deadline, and the next one is still refused at once. No assertion about the held commit is weakened.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `desktop-host-protocol`: the requirement "Activity and draft requests are bounded" and its scenario "Draft save under saturated output". A draft save under saturated output is bounded by the draft deadline instead of the control-latency bound.

## Impact

- Spec: `openspec/specs/desktop-host-protocol/spec.md`, through the delta at archive.
- Tests: `packages/host/test/it/draft_store_test.dart` only. No host, protocol or desktop code changes, and no wire or behaviour change.
- AGENTS.md lists timing rows that can fail under load. The saturated draft-save row is not listed there, so no entry is removed.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Bound a draft save under saturated output by the draft deadline, not the control-latency bound

- **Choice:** Amend the requirement. The test asserts success within the draft deadline and that terminal A keeps flowing, and keeps printing the measured time.
- **Rejected:** Keeping 250 ms and moving the Windows test profile to the runner's other disk. That would hide the cost of a durable commit instead of bounding what matters to users. Documenting the row as a known flake: it would still fail CI about one run in five on Windows. A per-platform bound: an arbitrary number for the same disk noise. Subtracting the worker's own commit time from the ack: it needs a new test hook to check a property the Stop and permission rows already cover.
- **Reversal cost:** low. It is one requirement sentence and one test assertion.
- **Important:** yes. It changes a protocol contract that binds later changes.
- **Chosen by:** user. Asked why the measurement was needed, then chose option 1, "amend the spec".

### S2: Fix the held-commit test in the same change

- **Choice:** Make the test's shortened deadline apply only to the held operation it measures, in the same change, because issue #25 reports both failures together.
- **Rejected:** A separate change. Both failures have one cause, a draft commit that is slow on the Windows runner. Two one-file PRs would double the review for no gain.
- **Reversal cost:** low. Test only.
- **Important:** no. Test only; no contract or behaviour change.
- **Chosen by:** agent

### S3: `terminal/activity` keeps the control-latency bound

- **Choice:** Change only the draft half of the "Both SHALL stay answered…" sentence.
- **Rejected:** Relaxing both. `terminal/activity` makes no durable write, so the reason for this change does not apply to it.
- **Reversal cost:** low
- **Important:** no. It leaves an existing contract unchanged.
- **Chosen by:** agent
