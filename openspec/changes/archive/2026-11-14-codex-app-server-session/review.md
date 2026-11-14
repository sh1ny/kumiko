# Review

## Metadata

- **Round:** 13.
- **Prior round:** Round 12, APPROVE_WITH_CHANGES with CHANGES_APPLIED yes (native command wrapper amendment).
- **Reviewer:** Codex, fresh-context, read-only adversarial design reviewer.
- **Reviewed:** `AGENTS.md`; D7 amendment items 1–6, surrounding D7, Failure & Visibility, Resource Bounds and lifecycle rules in `design.md`; amendment section in `tasks.md`; `proposal.md`; Round 12 `review.md`; requested authentication and qualification requirements in both delta specs; fifteenth-attempt and isolated-authentication evidence in `docs/qualification/codex-app-server.md`; relevant sections of `codex_auth_signatures.dart`, `host_options.dart`, `test_hooks.dart`, `codex_client.dart`, `runtime_driver.dart`, `agent_service.dart`, `agent_session.dart`, `check_qualification.dart` and `qualify_codex_app_server.dart`. Repository reads only; no execution, credential access or disk writes.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. The preflight lacks a configuration-equivalence condition for Continue.**

D7 item 1 makes the process-level `account/read` result sufficient to refuse `thread/resume`. The isolated observation establishes that result for an empty default configuration; it does not establish that it describes every saved thread’s authentication needs.

The current driver distinguishes these stages: `initialize()` establishes the process, while `loadSession()` reads saved-thread metadata and subsequently calls `thread/resume`. New-thread responses also explicitly carry `modelProvider`. The amendment places the refusal before resume without requiring evidence that the account result applies to the saved thread’s effective provider and credential configuration.

A saved conversation using a provider that does not require OpenAI sign-in can therefore be refused on the basis of the process’s default OpenAI account state. The user cannot reach the native resume operation that would determine whether those credentials are needed. Repeated Retry does not resolve that mismatch.

The planned tests cover account-result shapes, but no configuration mismatch between the preflight and the resumed thread. Either establish and test the equivalence needed for this refusal, or let Continue proceed when equivalence cannot be established.

**M2. “The root returns to Idle” conflicts with pending Stop aggregation.**

D7 item 2 unconditionally associates a confirmed failed root turn with Idle. Existing D4 requires Stop to aggregate the root and known active descendants, retaining Stopping when addressed work remains unresolved.

The implementation already distinguishes these cases. `AgentSession` avoids setting Idle directly when a native turn ends after Stop and instead calls `_settleNativeStop()`. Consequently, a root HTTP 401 completion while an addressed child still runs must retain the outstanding Stop state.

Implementing the amendment’s unconditional Idle rule would enable normal interaction while cancellation remains unresolved and could obscure *Stop not confirmed*. Keeping the existing implementation would instead contradict the amendment’s stated outcome.

The amendment’s tests require Idle but omit both a 401 completion after Stop and an outstanding descendant. Explicitly preserve the existing aggregation rule and test those orderings.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

CHANGES_APPLIED: yes

1. Constrain preflight refusal to cases where its authentication result is established to apply to the effective configuration of the requested operation. Explicitly address saved-thread provider/configuration differences on Continue; fail open where equivalence is unknown. Add a regression case demonstrating that a saved conversation requiring no OpenAI sign-in is not blocked by an unrelated unauthenticated default account.

2. Qualify item 2’s Idle outcome and the corresponding task: authentication classification must preserve existing Stop and descendant aggregation. Add tests for a confirmed 401 completion after Stop, including an outstanding child and a late completion after the Stop deadline. Verify the auth guidance alongside the correct Stop outcome and state.

## Rebuttals

Round 12’s wrapper corrections are accepted and are not reopened.

Structured signals address the observed failure of exact error-message matching. The empty production registry, separate test-host candidates, explicit experiment approval and bidirectional provenance checks appropriately distinguish fixtures, research and real Kumiko observations.

The preflight’s fail-open handling of unsupported or inconclusive responses is appropriate. M1 concerns the applicability of a positive result, which the empty-home observation does not establish for every resumed configuration.

The experiment’s separate homes, ephemeral credential storage, environment filtering and bounded turn are useful safeguards. No concrete credential-access or billing bypass was established from the reviewed material.

## Focused Recheck

1. **Satisfied.** D7 item 1 restricts the preflight to Start, checks the effective configuration for the start `cwd`, and fails open for a different provider or inconclusive configuration/account result. Continue explicitly bypasses the preflight because saved-thread configuration may differ. This matches the relevant code boundaries: `prepareTools` reads effective configuration using `cwd`; `newSession` supplies only `cwd` and private MCP configuration to `thread/start`; `loadSession` reads saved-thread metadata before `thread/resume`. The tasks now require the saved-conversation/unauthenticated-default regression, and operation A consistently expects refusal at Start. No residual design concern within this recheck; implementation and regression execution remain future work.

2. **Satisfied.** D7 item 2 and the corresponding task now limit direct Idle settlement to turns without pending Stop, preserve descendant aggregation, and retain *Stop not confirmed* after the deadline. The tasks explicitly require both an outstanding-child case and a late-completion case, each with authentication guidance. This agrees with `AgentSession`: `_finish` publishes authentication classification without directly setting Idle during native Stop; `_settleNativeStop` waits for all addressed turns and delegated work, then reports the aggregate outcome with `late: _notConfirmed`. No residual design concern within this recheck; the planned tests must verify those outcomes during implementation.