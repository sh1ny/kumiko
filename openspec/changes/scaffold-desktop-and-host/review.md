# Review

## Metadata

- **Round:** 2
- **Prior round:** APPROVE_WITH_CHANGES; all seven required changes were applied and re-checked before the D10 amendment voided the verdict.
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** Change `proposal.md`, `design.md`, `tasks.md`, all five `specs/*/spec.md`, and prior `review.md`; commit `237b2c1`; `tool/probes/sqlite/RESULTS.md`; ADRs 0001, 0002 and 0003; `openspec/architecture.md`.

## Findings

### Critical (blocking)

None.

### Moderate

1. **The release contract test does not verify the command-line test boundary.** D10 introduces independently dispatched `--test-fixture` registrations alongside protocol registrations. Task 9.2 checks only capability advertisement and rejection of `test/unit.launch`. Both assertions can pass while fixture dispatch remains reachable from shared startup code: capability gating does not protect command-line modes. Consequently, the stated release guard can pass while the release executable still runs a fixture or holds a profile lock through `--test-fixture lock-holder`.

   D10’s import separation is a sound design constraint, but task 9.2 does not establish that constraint or test every exposed test-only route. It also leaves the release `--unit-exec` path unqualified: the integration suite primarily runs the test entry point, so accidentally registering the shim only there could pass qualification and break future POSIX execution in the shipped host.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

CHANGES_APPLIED: no

1. **Extend D10 and task 9.2 to qualify both entry points and the command-line boundary.** Specify and test that the release executable rejects every supported `--test-fixture` variant promptly, without fixture execution, descendants, or profile changes. Check rejection of every test protocol method, including fault injection, while explicitly requesting test capabilities during negotiation. Add an import-dependency check establishing that the release entry point cannot transitively reach `lib/src/test_hooks/`. On Linux and macOS, run the release executable’s `--unit-exec` against a benign helper and verify session creation, preserved pid, exit propagation, and the unit marker. Keep fixture dispatch exclusive to the test entry point and shim dispatch available through both.

## Rebuttals

The probe supports replacing the compile-time define with separate entry points. No additional build-selection mechanism is needed.

The fixtures fit this layout: the test host launches its own executable in fixture mode, including through the POSIX shim. The release shim remains a deliberate execution feature under D2; its ability to execute argv is not itself test-code leakage.

The seven prior findings remain addressed. The required change concerns evidence for the amended boundary, rather than a demonstrated implementation defect or a need to reverse D10.