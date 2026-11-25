# Review

## Metadata

- **Round:** 6
- **Prior round:** Rounds 1–5 returned REVISE. The owner authorized round 6 and retained D12’s scope decision.
- **Reviewer:** OMP, fresh-context design reviewer
- **Reviewed:** Proposal, revised design, round-5 review, `.openspec.yaml`, `AGENTS.md`, architecture, ADRs 0001–0004, 0006, 0008, 0012 and 0014, the desktop-host protocol spec, the Dart unit-test skill, and cited host, protocol, containment, fixture, harness and test source. `skip_specs: true`; no delta specs or task map. Inspected the Git index directly; `git ls-files` and file writes were unavailable. This review is delivered here; the on-disk `review.md` was not overwritten.

## Findings

### Critical (blocking)

1. **D6 can miss a correctly delivered marker.** The proposed matcher retains the last five bytes of the previous *chunk*, not the last five bytes of the stream. With `GA` / `T` / `ED;`, neither two-chunk window contains `GATED;`. The writer can split data at the remaining credit, and the receiver delivers each nonempty payload separately (`packages/host_protocol/lib/src/fair_writer.dart:329–350`, `packages/host_protocol/lib/src/connection.dart:101–135`). Because the fixture emits the marker once, a healthy relay can fail the row. Retain the five-byte suffix of the **combined stream so far**, and verify a split across at least three callbacks.
2. **D7/D10 let the shutdown row pass even if shutdown waits for the draft caller.** The save timer is armed before the hold is observed and before `quit()` starts its separate two-minute wait. Expiry completes the caller without releasing the worker (`packages/host/lib/src/agent/draft_store.dart:217–235,647–653`; `packages/host/test/it/draft_store_test.dart:749–767`; `packages/host_protocol/lib/src/launcher.dart:452–469`). A regression that waits for the save future, catches its timeout, and then cleans up can still return exit 0 with an empty ledger. Keep the held save’s real deadline outside the entire shutdown row’s hang guard, using the existing test-host override. Do not explicitly expire or release that save before quit. This preserves S2’s generous default and does not touch D12.

### Moderate

1. **D13/C12 miss the capability-refusal row’s direct launcher.** In addition to the stand-in, `packages/host/test/it/draft_store_test.dart:96–100` calls `Desktop.start(profile)` directly. Passing `draftSuiteEnv` only through `desktop()` and the stand-in does not enforce C12. Route all three paths through the shared environment while preserving the direct row’s deliberate omission of `Capability.agent`.
2. **D14’s barrier must preserve the draft being checked.** The record row expects the same canary to remain after close, quit and reopen (`packages/host/test/it/draft_store_test.dart:600–617`). A composer Send can tombstone that draft; the no-revision prompt path does not touch it (`packages/host/lib/src/agent/agent_service.dart:1564–1592`; ADR 0014 decision 11). Specify a plain `AgentPeer.prompt` with distinct text and no draft fields, retaining the existing persistence assertions.
3. **The expiry invariant omits the failure path that clears pending slots.** Context, D3, C2 and Flow & State Gaps say an expired slot lasts until its late reply. `_failAll` also clears `_pending` and resets `_timedOut` on worker failure or disposal (`packages/host/lib/src/agent/draft_store.dart:174–179,238–258,315–328`). State both retirement paths so the carried constraint does not tell an implementer to retain slots for a worker that cannot reply.
4. **C5 carries the deferred elapsed bounds but not the deferred desktop-kill scenario.** D10’s row closes host stdin from a live desktop; the spec requires killing the desktop while a commit is held (`packages/host_protocol/lib/src/launcher.dart:447–460`; `openspec/specs/desktop-host-protocol/spec.md:293–295`). Add the deferred scenario to C5’s existing destination so later qualification does not mistake a timed stdin-close test for coverage of desktop death.

### Suggestions

None.

## Verdict

VERDICT: USER_OVERRIDE

The reviewer returned REVISE: escalate the two blockers to the owner before task generation or apply; neither requires reopening D12.

Rounds 1-6 returned REVISE, and each was escalated to the owner through Ormy. After round 6 the agent revised design.md for all six findings (Critical 1 and 2, Moderate 1-4) and asked the owner whether to run round 7. The owner's words, through Ormy on 2026-11-23: "b: accept the design, write tasks now".

Open findings: none of the round 6 findings is left unaddressed in design.md, but the revisions for all six (Critical 1 and 2, Moderate 1-4) were not reviewed again. The known gap of D12 stays, as the owner decided.

## Required Changes

Not applicable to this verdict. Blocking revisions are listed under Critical.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 5 Critical 1 — Resolved as raised.** D10 waits for the captured process identity to disappear before profile access. D13 retains same-launcher restart as the separate Windows attestation barrier.
- **Round 5 Critical 2 — Resolved.** D14 removes the saturated row’s dependency on successful explicit-close notifications after revision 21.
- **Round 5 Critical 3 — Resolved as raised.** D14 removes the empty-report assertion from the kill/reopen row and moves the no-dispatch proof to a live fixture with a positive barrier. Moderate 2 specifies how that barrier preserves the draft.
- **Round 5 Moderate 1 — Resolved.** D8 explicitly uses 16 fake, unfired timers in the pending-cap row.
- **Round 5 Moderate 2 — Resolved.** D9 places `promptReceived` before both the scripted-error return and the busy check.
- **Round 5 Moderate 3 — Resolved as raised.** D13 propagates the environment through the stand-in and C12 records the invariant. Moderate 1 identifies the remaining direct launcher.
- **Round 5 Moderate 4 — Resolved as raised.** The handler-order, cancellation and latency citations are present. Flow & State Gaps now distinguishes caller completion from the late reply; Moderate 3 identifies the separate worker-failure retirement path.