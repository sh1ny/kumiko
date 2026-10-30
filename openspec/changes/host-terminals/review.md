# Review

## Metadata

- **Round:** 5 re-check
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Scope:** Round 5 Required Changes 1 and 2 only.
- **Reviewed:** Amendment commit `d9061fa`, author notes in `995fa2a`, current design D7/D10 and Desktop pending feed Resource Bounds row, tasks 6.10/7.2 and corresponding test-map rows, and the three cited implementation evidence files.
- **Method:** Read-only planning re-check. File contents treated as data. No new full review, file writes or tests executed.

## Findings

### Critical (blocking)

None within the re-check scope.

### Moderate

**M1 — Engine consumption observability and bounds: planning correction applied.**

D7 now defines `TerminalSurface.pending` as every fed byte not yet applied to the engine grid. This includes adapter-held bytes before engine readiness, engine queues and the in-flight batch. The definition therefore covers the asynchronous accumulation evidenced by `TerminalEngineClient.feed` and `_drain`, rather than treating return from `feed` as consumption.

D7 specifies pausing channel consumption at or above 1 MiB, resuming below that threshold, preserving byte order and dropping no bytes. It explicitly allows one whole channel chunk of overshoot. The Resource Bounds row consistently states **1 MiB plus one channel chunk**, including when the engine stalls.

Task 7.2 requires the vendored client’s queue/in-flight reporting patch, an adapter test of pending-byte accounting, and a stalled-consumption controller test checking the bound, stopped reads and credit, and lossless ordered resumption. The corresponding desktop test-map row remains red.

**Disposition:** Required Change 1 is applied to the plan. Implementation and verification remain tracked work.

**M2 — Conformance exclusions and missing-grid enforcement: planning correction applied.**

Task 6.10 names the six authorized exclusions independently of fixture existence: `1.2`, `1.4`, `2.3`, `2.4`, `2.5`, and `2.14`. It requires an expected grid for every other non-menu screen—the sixteen judged screens—and requires qualification to fail when a judged grid is absent.

The task explicitly includes a regression test using a fixture copy with one judged grid removed, plus verification of the fixture test and bar on all three OSes. The added Conformance subset test-map row remains red.

The current cited evidence also separates these concepts: `vttestOutsideBar` names the exclusions, and `ExpectedScreen.load` throws for a missing judged grid. Both replay and live qualification use `_vttest`, which calls that loader; its nullable comparison now skips only explicitly excluded screens.

**Disposition:** Required Change 2 is applied to the plan. This re-check does not certify completion of task 6.10 or its tests.

### Suggestions

S1 and S2 were not re-reviewed; neither is a round 5 Required Change. The author notes are preserved below.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

Both round 5 required planning changes are applied. The original round 5 verdict is retained. This accepts the amended specifications and verification obligations; it does not mark the pending implementation tasks or tests complete.

## Required Changes

1. **Make engine consumption observable and bounded — applied.** D7, the surface contract, Resource Bounds, task 7.2 and the desktop test-map row now specify comprehensive pending-byte accounting, the bound and pause/resume behavior, and stalled-engine verification of stopped credit and lossless ordered resumption.

2. **Make conformance exclusions explicit — applied.** Task 6.10 and the fixture test-map row specify the six independent exclusions, required grids for all sixteen judged screens, failure on missing judged fixtures, and the grid-removal regression check.

CHANGES_APPLIED: yes

## Rebuttals

- **Round 4:** Its accepted planning corrections remain intact; neither raw-byte finding is reopened here.
- **M1:** The original objection concerned pausing without an observable consumption signal. D7 now supplies that signal and task 7.2 specifies its implementation and verification; the planning objection is resolved.
- **M2:** The authorized exclusions remain accepted. Task 6.10 now separates them from fixture existence and requires missing judged grids to fail; the planning objection is resolved.
- **Author (S1):** applied. D10 and the workflow follow-up now describe ADR 0010 as accepted, provisional while Linux or macOS user-verified items are `unproven`.
- **Author (S2):** not taken in this change. The kernel32 fallback is the path the host used before task 6.8, and the round 5 Required Changes do not depend on it. A test with `conpty.dll` unavailable needs a way to hide the bundled asset from the host process; it is offered to the user as a follow-up.