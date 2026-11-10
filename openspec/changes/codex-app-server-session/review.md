# Review

## Metadata

- **Round:** 2. This is a focused re-check of Required Changes 1–5 only, not a new full review.
- **Prior round:** Round 1 returned REVISE. C1 covered baseline admission for untested Codex versions; C2 covered the fallback MCP secret path, which conflicted with ADR 0013. M1–M5 covered Stop semantics, busy children in close/quit, profile detection and the default profile, Codex auth and the checker, and containment of the version probe. S1–S5 were suggestions. The full Round 2 review returned APPROVE_WITH_CHANGES with Required Changes 1–5. This re-check covers only those five.
- **Reviewer:** Fresh-context reviewer (Claude Code agent, `claude-opus-5-5`), read-only.
  - The full Round 2 review had no shell, so it couldn't run `openspec instructions review --change codex-app-server-session --json`. It took the template and rules from `openspec/schemas/specwright/templates/review.md` and from the `review` artifact in `openspec/schemas/specwright/schema.yaml`. This re-check had no shell either.
  - Applicable project skill: dart-build-cli-app (`F:/Dev/Orca/Workspace/kumiko/.agents/skills/dart-build-cli-app/SKILL.md`). None of the findings or re-check results depended on it.
- **Reviewed in the full Round 2 review:**
  - **Project constraints:** `AGENTS.md`.
  - **Change artifacts** (`openspec/changes/codex-app-server-session/`):
    - `proposal.md`, `design.md` and the prior `review.md`;
    - `specs/{codex-sessions, agent-runtimes, agent-sessions, agent-tool-access, app-exit, desktop-host-protocol}/spec.md`.
  - **Planning documents:** `openspec/roadmap.md` in its current form (I couldn't diff it without a shell) and `openspec/architecture.md` (the Codex/ACP/qualification lines).
  - **Main specs, read in full:** `openspec/specs/{agent-runtimes, agent-sessions, agent-tool-access, app-exit}/spec.md`.
  - **ADRs:**
    - 0004, 0005 and 0012 in full;
    - 0013, decisions 1–23;
    - 0014, the decision list (1, 3, 6, 11, 15, 17 in detail).
    - I did not reopen 0001–0003. I relied on how ADR 0012 and the architecture describe them.
  - **Source:**
    - `packages/host/lib/src/agent/agent_service.dart:640-972`
    - `agent/qualification.dart`
    - `agent/qualified_adapters.dart`
    - `agent/tools/tool_service.dart:12-18,440-469`
    - `unit_manager.dart:20-250`
    - `packages/host_protocol/lib/src/messages.dart:55-124`
    - `packages/domain/lib/src/profile/profile.dart` (runtimeKind)
    - `packages/desktop/lib/src/workbench_controller.dart:790-834`
    - `packages/desktop/lib/src/agent/agent_controller.dart:1256-1331`
    - `runtime_profiles_dialog.dart:286`
    - `tool/check_qualification.dart:1-80`
- **Re-read for this re-check:**
  - **The Round 2 review:** `review.md`.
  - **Revised design:** `design.md`, specifically D3, D5, D6, D7, the T2 diagram, State & Ownership and Resource Bounds.
  - **Delta specs:**
    - `specs/desktop-host-protocol/spec.md`
    - `specs/agent-tool-access/spec.md`
    - `specs/agent-runtimes/spec.md`
    - `specs/codex-sessions/spec.md`
    - the child/delegated lines of `specs/agent-sessions/spec.md` and `specs/app-exit/spec.md`
  - **Main spec:** `openspec/specs/agent-runtimes/spec.md:119-148`, to confirm the MODIFIED block keeps every scenario.
- **Not done:**
  - No tests, builds or live runtime checks were run, in either the full Round 2 review or this re-check.
  - The file tools are restricted to the repository, so I couldn't inspect the installed Codex 0.166.0 executable, its npm package or its generated schema. Wherever a finding depends on Codex behaviour, it says so.
- **Owner policy kept intact:** the owner's minimum-version policy (any Codex version ≥ 0.166.0 is admitted with no allowlist) is settled and preserved. None of the edits below reintroduces an exact-version gate:
  - D3 states that a newer version runs without an allowlist;
  - D7 says the M2 evidence requirement "does not impose a runtime allowlist or disable later installed versions";
  - `codex-sessions` "Codex updates do not require a Kumiko version allowlist" is unchanged apart from the added scenario.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Prior findings re-check

From the full Round 2 review; unchanged.

| Prior | Status | Evidence |
|---|---|---|
| C1: admitting an untested version | **Resolved** per the owner's decision | All the artifacts give one rule: any version at or above 0.166.0 is admitted with no allowlist. Missing, unparseable, inconsistent or below-minimum versions are refused before a thread is created. The Claude ACP gate is unchanged. |
| C2: safe secret delivery | **Resolved at design level**; the verification gap was M5 | Only a private stdin config request is allowed, with the secret confined to the entry's env. Env, argv and file fallbacks are forbidden. A pre-existing or unprovable `kumiko` entry is refused. |
| M1: Stop semantics | **Resolved** | T2 has a Stopping self-loop on timeout. Aggregate results map onto the existing four outcomes. The MODIFIED Stop requirement keeps all original scenarios. |
| M2: busy children in close/quit | **Resolved in the specs**; how the desktop learns of child activity was open (M1 below) | The MODIFIED `agent-sessions` and `app-exit` requirements keep all original scenarios. ADR 0015 amends ADR 0014 decision 1. |
| M3: detection and default | **Resolved** | Claude-specific "not installed" wording; Claude-first default; kind filters on every path. |
| M4: Codex auth and checker | Auth **resolved**; the checker was **partly resolved** (M4 below) | — |
| M5: probe containment | **Resolved**; target attribution is unclear (S1) | — |
| S1–S5 | As recorded in the full Round 2 review | — |

## Findings

From the full Round 2 review; these are the findings the required changes respond to. They are not reopened here.

### Critical (blocking)

None.

### Moderate

- **M1.** The desktop can't learn about active child work from sequenced control, so the new close, quit and Stop scenarios can't be met.
- **M2.** Under the minimum-version policy, "malformed required fields fail the run" turns upstream changes to experimental APIs into a failure of every Codex run.
- **M3.** The bridge connection cap per grant isn't reconciled with inherited child tools. Whether Codex starts an MCP client per thread is unverified for 0.166.0.
- **M4.** The Codex evidence item set and the checker rules contradict each other and the specs.
- **M5.** The secret-isolation check doesn't cover files Codex itself writes. Whether Codex persists per-thread config is unverified.

### Suggestions

S1–S10 stand as written in the full Round 2 review. They are not required changes, and this re-check doesn't reopen them.

## Required Changes re-check

| # | Required edit | Status | Evidence |
|---|---|---|---|
| 1 | D6 delegated-activity summary in sequenced `agent/state`; close, exit and Stop read only that state | **Applied** | `design.md` D6 opening paragraph. It adds that AgentSession is the sole publisher, and that an incomplete registry keeps the warning conservative. |
| 1 | T2 transitions `Idle --> Waiting` and `Waiting --> Idle` | **Applied** | T2 diagram: "child approval or question" and "last child request resolved with no root turn". |
| 1 | State & Ownership row for the summary | **Applied** | Row "Delegated-activity summary \| AgentSession (fed by Codex driver) \| One run \| Recomputed from child registry; reset on loss \| Host memory". |
| 1 | `desktop-host-protocol` requirement with a happy-path and a no-credit scenario | **Applied** | "Delegated activity is reported in sequenced state", with scenarios "Child starts" and "Child starts with no transcript credit". This is consistent with the `agent-sessions` close and Stop scenarios and the `app-exit` scenarios that depend on it. |
| 2 | D3: core contract versus optional contract | **Applied** | D3 lists the core surfaces that fail the run when malformed: initialize, thread start/resume, turn start/interrupt/completion, message, command and file items, and approval requests. It lists the optional surfaces that disable only their own feature with a visible reason: child/collaboration metadata, steering, structured questions, elicitation, history paging and relationship filters. Child content follows the unknown-child path. |
| 2 | `codex-sessions` scenario for experimental metadata changes | **Applied** | "Experimental metadata changes in a newer version", under "Codex updates do not require a Kumiko version allowlist". |
| 3 | Resource Bounds row for bridge connections per root grant | **Applied** | Bound: the existing 4 (`tool_service.dart:14`). Further bridges are refused busy, and a child-tools-unavailable notice appears without changing the root's tools status. |
| 3 | D6: cite evidence or keep the row | **Applied** (row kept) | D6: "Keep the existing per-grant bridge connection cap; do not assume Codex shares one MCP client across threads." |
| 3 | `agent-tool-access` cap scenario | **Applied** | "Child bridge connection cap". |
| 4 | D7: one required/optional item set | **Applied** | Required: launch/streaming, tool activity, command approval, Stop, close/descendant containment, `kumiko tool call` and auth-required (pass with signature, or unverified). Optional: recovery, steering, structured question and child attribution. The earlier contradiction is gone. |
| 4 | D7: checker output and the M2 exit | **Applied** | D7 defines `CODEX OBSERVATIONS: <version> <OS>: PASS \| INCOMPLETE \| FAIL`, and says the checker never prints ACCEPTED or QUALIFIED for Codex. M2 close needs a Windows section for the then-installed version with every required observation passing. |
| 4 | D7: `toolDeliveryFailures` semantics | **Applied** | A literal entry starts that exact version's tools unavailable, and a later observed call still wins (ADR 0013). This is explicitly not a runtime-admission allowlist. |
| 4 | `codex-sessions` "Real Codex qualification…" aligned | **Applied** | The body lists the same required set ("tools" = tool activity, "MCP call" = `kumiko tool call`). The four optional observations are separate. Missing observations never disable features. |
| 4 | `agent-runtimes` "Kumiko tool delivery…" MODIFIED, keeping every scenario | **Applied** | The body now reads "every listed Claude adapter version and every recorded Codex evidence section". All seven main-spec scenarios (`openspec/specs/agent-runtimes/spec.md:122-148`) are retained word for word. |
| 5 | D5 post-run canary scan of Codex-written files and Kumiko's profile | **Applied** | D5 requires the scan after fixture runs and after the separately approved real Windows walk. A match is a tool-delivery failure for that version, and that configuration path is refused. Neither the secret nor scan results containing it are logged. |
| 5 | `agent-tool-access` THEN extended | **Applied** | "Unrelated commands cannot read bridge secret" now ends with "and the secret appears in no file the runtime wrote during the run". |

**Non-blocking note** (not a required change, no new scope): the retained main-spec scenario "Recorded failure matches evidence" still prints **QUALIFIED**. Under the modified body it reads as applying to Claude's listed versions, and D7 defines the Codex output separately. That is coherent. During apply, the test map should attach that scenario to the Claude path only.

All five required changes are present and consistent with each other, with the delta specs and with the owner's minimum-version policy.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

These are the changes from the full Round 2 review. All five were confirmed applied in the re-check above.

1. **Child activity on sequenced control (M1):**
   - the D6 summary;
   - the T2 `Idle <-> Waiting` transitions;
   - the State & Ownership row;
   - the `desktop-host-protocol` requirement "Delegated activity is reported in sequenced state" with both scenarios.
2. **Core contract versus feature contract (M2):**
   - the D3 wording;
   - the `codex-sessions` scenario for experimental metadata changes.
3. **Bridge connections per grant (M3):**
   - the Resource Bounds row;
   - the D6 statement keeping it;
   - the `agent-tool-access` cap scenario.
4. **Evidence and checker consistency (M4):**
   - the D7 item set, checker output, M2 exit rule and `toolDeliveryFailures` semantics;
   - the aligned `codex-sessions` qualification body;
   - the MODIFIED `agent-runtimes` tool-delivery requirement with every scenario kept.
5. **Secret persistence check (M5):**
   - the D5 canary scan;
   - the extended `agent-tool-access` THEN.

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

None.