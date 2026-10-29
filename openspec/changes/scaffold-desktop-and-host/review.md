# Review

## Metadata

- **Round:** 2 — re-check of the sole Required Change.
- **Prior round:** APPROVE_WITH_CHANGES; all seven prior required changes remain addressed.
- **Reviewer:** codex
- **Reviewed:** Current `design.md` D2, D10 and D13; `tasks.md` tasks 3.1, 9.2 and the release-contract test-map row; current `review.md`; commit `0bfd8a8`.
- **Scope:** Design amendment verification only; implementation and test execution were not reviewed.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The release contract test does not verify the command-line test boundary — addressed.** D10 now requires release rejection of all five fixture variants promptly, with a usage error, no descendants, no lock acquisition and a byte-identical profile. It also requires rejection of all four test protocol methods, including fault injection, with test capabilities explicitly requested during negotiation.

   D10 and D13 require a transitive import-graph check excluding `lib/src/test_hooks/` from the release entry point; task 3.1 provides corresponding audit coverage. D10 and task 9.2 qualify the release `--unit-exec` path on Linux and macOS using a benign helper, checking preserved pid, session creation, exit propagation and the unit marker. Fixture dispatch remains exclusive to the test entry point, while shared shim dispatch serves both entry points consistently with D2. The test-map row reflects the expanded release boundary checks.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

The sole Required Change is fully applied to the planning artifacts. The amendment introduces no new Critical problem.

## Required Changes

CHANGES_APPLIED: yes

1. **Applied — Extend D10 and task 9.2 to qualify both entry points and the command-line boundary.** All requested checks and dispatch constraints are specified, with the import audit carried through D13 and task 3.1 and the release-contract test map updated.

## Rebuttals

The probe supports replacing the compile-time define with separate entry points. No additional build-selection mechanism is needed.

The fixtures fit this layout: the test host launches its own executable in fixture mode, including through the POSIX shim. The release shim remains a deliberate execution feature under D2; its ability to execute argv is not itself test-code leakage.

The seven prior findings remain addressed. This re-check confirms that the amended plan supplies the requested boundary qualification; it does not claim those tests have already been implemented or passed.