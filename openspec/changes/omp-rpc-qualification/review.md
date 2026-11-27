# Review

## Metadata

- **Round:** 2
- **Prior round:** Round 1 returned APPROVE_WITH_CHANGES with no Critical findings and four Moderate required changes. M1 covered `LOCALAPPDATA` inheritance by the OMP probe and launch. M2 covered approval binding and reuse. M3 covered the root/child model field. M4 covered process discovery and the close/quit pass criteria.
- **Reviewer:** cross-model CLI (Claude, `claude-opus-5-5`), independent read-only design reviewer
- **Reviewed:**
  - The round 1 report: `openspec/changes/omp-rpc-qualification/review.md`
  - The revised `openspec/changes/omp-rpc-qualification/design.md` and `openspec/changes/omp-rpc-qualification/specs/omp-sessions/spec.md`
  - `openspec/schemas/specwright/templates/review.md`
  - The source ranges the revision newly cites, re-read: `packages/host/lib/src/agent/omp/version_probe.dart:30-44`, `packages/host/lib/src/agent/agent_service.dart:964-971`, `agent_service.dart:1028-1041` and `agent_service.dart:1137-1150`
  - ADR 0019 decision 5 (`docs/adr/0019-omp-history-child-view-and-shutdown.md:14`), read to check that the M4 pass criteria are consistent with it
  - Installed skills considered: `dart-add-unit-test`, `dart-use-path-package` and `dart-run-static-analysis`
  - Limits: the scope was only M1–M4 and whether they agree with each other. I ran no commands and opened no external URLs.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — fixed.**
- **Inheritance is now stated.** D2 (design.md:39) says the host inherits the child-process `LOCALAPPDATA`. It says the version probe preserves it and cites `version_probe.dart:31-44` and `agent_service.dart:1030-1041`. It says the OMP workspace launch also preserves it "unless the profile overrides it", citing `agent_service.dart:964-971,1137-1149`.
- **The citations support this.**
  - `ompProbeEnvironment` allowlists `LOCALAPPDATA` (`version_probe.dart:41`), and `_open` applies it to `Platform.environment` (`agent_service.dart:1040`).
  - For OMP, `_launchEnvironment` returns `profile.env` (`agent_service.dart:971`), and the launch uses `inheritParentEnvironment: profile.runtimeKind != 'codex'` (`agent_service.dart:1148`). The "unless the profile overrides it" qualifier is therefore accurate.
- **The gate is extended.** It resolves the config, auth, session and cache roots "under the exact launch environment". It uses identity/help, public documentation and local non-secret metadata only. It aborts "if native sign-in resolution would change" (design.md:40).
- **The approval lists the redirected roots** (design.md:41).
- **The Failure & visibility table has the matching Preparation row** (design.md:160).

**M2 — fixed.**
- **D1 has the approval field.** It adds `approval` with `sha256` (64 lowercase hex digits of the exact presented plan) and `approvedAt` (UTC ISO 8601). The audit rejects "missing, malformed or repeated approval references" (design.md:30-31).
- **D2 checks the plan before launch.** It hashes the plan's UTF-8 bytes. Before the first launch, it matches version, executable, build, model, targets, profile argv, overlay and queued prompts against the plan (design.md:41).
- **Reuse is blocked.** D2 creates an exclusive spent marker for the digest, which restores the Codex exclusive claim that round 1 flagged as dropped.
- **The rejected-alternatives list is updated.** It includes "drop the Codex plan-hash binding" (design.md:42).
- **The spec matches.**
  - The malformed scenario includes "lacks or repeats an approval reference" (spec.md:35).
  - The requirement now says the record "SHALL identify the approval" (spec.md:7).
- **The summary tables agree.** The D1 and D2 rows, the State & ownership table and the Mechanism ledger all describe hash-bound approval.

**M3 — fixed (the allowed alternative was chosen).**
- **D1 keeps one field.** It keeps a single `model`, "exact `provider/model` pinned for both root and child" (design.md:30).
- **D2 requires the pin.** The gate says "Pin the same exact provider model for root and child" (design.md:40), and the approval names the exact model (design.md:41).
- **D3 handles a mismatch.** Step 5 says an observed child model mismatch fails the child row, and missing model proof keeps it unverified (design.md:55). A real mismatch can therefore be recorded truthfully, with no malformed record and no false identity.

**M4 — fixed.**
- **Discovery is specified** (design.md:49):
  - Launch the desktop as a direct child of the operator's process and keep its handle.
  - While the processes are live, enumerate only that process's parent-PID chain.
  - Check creation times and end-to-end parent ownership.
  - Open handles immediately and label each owned runtime tree by pane before any close.
  - Do not use delays or name searches.
- **The `close` criteria are defined.** Step 6 (design.md:56) passes `close` only when Cancel kept the work, the confirmed pane closed, every owned handle in B signaled, and A stayed available. Missing handle evidence means unverified.
- **The `ordinary quit` criteria are defined.** Step 7 (design.md:57) requires:
  - all owned handles signaled
  - OMP exit 0
  - the retained root saved and not running on reopen
  - an inert child pane
  - no unconfirmed-save or cleanup warning
  - the prior root history present

  Missing evidence means unverified.
- **This matches ADR 0019 decision 5** (`0019:14`), where a nonzero exit leaves an unconfirmed save and unit settlement proves cleanup, not persistence.

### Suggestions

None new. The round 1 suggestions S1–S3 appear to be adopted in D1 (design.md:30-31). This recheck does not depend on them.

## Verdict

All four required changes are applied, and each matches its round 1 fix. The new citations support their claims. The spec, design decisions, decision summary, State & ownership table and Failure & visibility table agree with each other on these points. No Critical finding is open.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. design.md D2: state `LOCALAPPDATA` inheritance, resolve the roots under the launch environment, list the redirected roots in the approval and add the Preparation failure row. Applied (design.md:39-41,160).
2. design.md D1/D2 and spec.md: approval field and audit rejection, plan hash and launch match, the added rejected alternative and the spec's malformed scenario. Applied (design.md:30-31,41-42; spec.md:7,35).
3. design.md D1: pin one model for root and child, and make an observed child mismatch fail the child row. Applied (design.md:30,40,55).
4. design.md D3: discovery method and close/quit pass criteria, with missing evidence recorded as unverified. Applied (design.md:49,56-57).

CHANGES_APPLIED: yes

## Rebuttals

None.