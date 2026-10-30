# Review

## Metadata

- **Round:** 5
- **Change:** `host-terminals`
- **Tier:** FULL
- **Reviewer:** Codex
- **Scope:** Current planning artifacts, supplied amendment commits and aggregate diff, ADRs 0001–0010, architecture, and supporting implementation and CI evidence.
- **Method:** Read-only design review covering ownership, failure, bounds, ordering, decisions, over-engineering and specs. No files written; no tests executed.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — The adopted engine boundary cannot enforce the planned desktop output bound.**

`design.md:138` and its Resource Bounds table require pausing channel consumption when the engine’s pending feed reaches 1 MiB. Task 7.2 carries that requirement forward.

However, `TerminalSurface.feed` returns `void` and exposes neither pending bytes nor consumption completion. `AlacrittySurface.feed` forwards immediately to the engine. The vendored `TerminalEngineClient` appends bytes to `_buf`, then asynchronously processes a batch while further bytes accumulate (`terminal_engine_client.dart:142–181`).

Consequently, completing a `feed` call does not mean those bytes have been consumed. A controller that bounds only its own queue can continue returning channel credit while output accumulates inside the engine. The spike’s throughput result does not establish a bound under a stalled engine.

**Consequence:** group 7 cannot implement the stated memory guarantee through the approved interface. The design must define an observable consumption or admission contract, including bytes queued before engine initialization and bytes in flight.

**M2 — Conformance qualification silently accepts missing expected grids.**

The amended bar explicitly identifies six unjudged screens and requires comparison of the other sixteen.

`ExpectedScreen.load` returns `null` whenever an expected-grid file is absent (`integration_test/bar/vttest.dart:29–31`). `_vttest` then treats that as “ran, not judged” and produces no mismatch (`terminal_bar_test.dart:218`). There is no independent check that missing grids correspond exactly to the authorized exclusions.

Deleting a judged screen’s `.txt` fixture therefore weakens both replay and live qualification without failing the test. The spike-results checker validates recorded statuses, not fixture completeness.

**Consequence:** the implementation used as qualification evidence does not enforce the amended subset. Explicit exclusions and required expected grids need separate representations.

### Suggestions

**S1 — Reconcile the remaining ADR lifecycle wording.**

Design D10 and the workflow follow-up still describe ADR 0010 as proposed until merge. The ADR and architecture now record accepted, provisional adoption. Update those remaining statements to reflect the current decision.

**S2 — Add focused fallback verification.**

The bundled-console test proves the normal `OpenConsole.exe` path. Add a separate-process test for unavailable `conpty.dll`, covering creation, resize and close through kernel32. Clarify the narrower failure contract: a loadable DLL with a missing companion executable is not covered by the current library-load probe.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

The user-authorized provisional adoption, hardware-only frame gate, Windows transcript replay and vendored engine are reasonable decisions. Two gaps remain in bounded consumption and qualification enforcement.

The remaining design follows the established ownership model: the host owns PTYs and process cleanup; the desktop owns rendering, search and close confirmation. Attach ordering, channel reservations and cleanup ownership remain explicit. Vendoring records provenance, patches and update procedures, with native builds and desktop checks on three OSes.

Task 6.9’s controller attachment, supplied search bar and painter patch have focused supporting tests. Windows replay is accurately distinguished from ConPTY coverage. The frame gate remains an explicit real-hardware obligation, and the provisional checker preserves Linux/macOS unproven items.

Groups 7 and 8 still follow from the design, subject to M1 and M2. Their unfinished desktop integration and architecture updates are appropriately tracked as pending.

## Required Changes

1. **Make engine consumption observable and bounded.** Amend D7, the surface contract, Resource Bounds and task 7.2 to specify admission/completion or queue-pressure signals. Account for adapter queues, pre-initialization buffering and in-flight batches. Add a desktop test with engine consumption deliberately stalled: verify the stated bound, stopped channel credit, ordered resumption and no dropped bytes.

2. **Make conformance exclusions explicit.** Define the six authorized unjudged screen IDs independently of fixture existence. Require expected grids for all sixteen judged screens and fail on missing fixtures. Add a regression check demonstrating that removing a judged grid fails qualification, and include this verification in the remaining tasks.

CHANGES_APPLIED: no

## Rebuttals

- **Round 4:** Its accepted planning corrections remain intact; neither raw-byte finding is reopened here.
- **M1:** Task 7.2’s planned pause is insufficient without a signal distinguishing engine admission from actual consumption.
- **M2:** The authorized exclusions are accepted. The finding concerns accidental additional exclusions caused by missing fixtures.
- No author rebuttals to the Round 5 findings were available.
- **Author (S1):** applied. D10 and the workflow follow-up now describe ADR 0010 as accepted, provisional while Linux or macOS user-verified items are `unproven`.
- **Author (S2):** not taken in this change. The kernel32 fallback is the path the host used before task 6.8, and the round 5 Required Changes do not depend on it. A test with `conpty.dll` unavailable needs a way to hide the bundled asset from the host process; it is offered to the user as a follow-up.