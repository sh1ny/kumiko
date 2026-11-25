I've finished the round 2 review. Here it is for the runner to validate and write. I changed no files.

```markdown
# Review

## Metadata

- **Round:** 2
- **Prior round:** Round 1 gave APPROVE_WITH_CHANGES with CHANGES_APPLIED: no. It had four Required Changes: M1 (A3 and how D2 handles requests before admission), M2 (C11), M3 (evicting closed tool ids) and M4 (A1 fields and the `rpc_frame_error` rule). It also made six Suggestions, S1–S6.
- **Reviewer:** cross-model CLI (Claude Code, claude-opus-5-5), fresh context
- **Reviewed:**
  - **Change artifacts:** the round 1 review.md, then the current proposal.md, design.md and the five spec deltas (agent-runtimes, agent-sessions, agent-tool-access, desktop-host-protocol, omp-sessions), all in full.
  - **Main specs:** omp-sessions (whole file), agent-sessions (requirement and scenario index, and lines 73–106), desktop-host-protocol (lines 170–209).
  - **Source:** omp_driver.dart (whole file), omp_client.dart (whole file), agent_session.dart:60-210, 335-395, 575-610, 815-935, 1080-1420, agent_service.dart:215-244, 1025-1175, 1325-1375, plus the tools-status sites at 1352-1358 and 1423-1434. Also tool_service.dart:540-626, tool_catalog.dart (whole file), agent_events.dart:25-114, messages.dart:2375-2464.
  - **ADRs:** 0016 decisions 1–5 and consequences; 0013 decision 16.
  - **Schema:** the review artifact in schema.yaml (lines 430–609) and templates/review.md.
  - **Not done:** I had no shell in this session, so I could not run `git ls-files`. Every file I opened is named in the request or sits in the same tracked package, spec or ADR directories. None is a symlink, an ignored path or a path outside the repository. I did not reopen agent_pane_view.dart or architecture.md this round; round 1 checked the cited ranges and the design text citing them has not changed. The OMP source URLs in A1 and A3 cannot be opened, so I judged them as recorded Assumptions only.

## Re-check of Round 1 Required Changes

**1. (M1): Applied.**
- **A3 is recorded as an Assumption** (design.md:91). It separates two cases:
  - **The normal root model path.** `onPromptAdmitted` fires before model setup and before `agent.prompt`, and the RPC response is released on that callback. So native approvals for that prompt follow the response.
  - **Hooks that run before admission and are awaited.** These are extension `input` hooks and builtin command dispatch. A `select` from one of them is sent at once and awaited before the response.
- **No general ordering guarantee is implied.** A3 says "Do not assume a global event-order guarantee; early transcript frames remain defensively staged."
- **A3 carries a check before implementation:** "Check the pinned source before implementing D2; change 5 checks the ordering on a real Windows prompt."
- **The other texts agree with A3:**
  - D2 Choice (design.md:40) declines a recognized request that arrives before admission.
  - D2 Rejected (design.md:42) states both cases. Holding the request would not help normal approvals, and a lookalike from a hook would wait for a reply that never comes.
  - Flow & State Gaps (design.md:208) says hook dialogs are declined at once so an input hook can finish, and that native root approvals begin after admission.
  - The lifecycle diagram (design.md:126) shows Pending only from "admitted root turn and supported frame".
  - The spec delta *Request after the turn* (omp-sessions spec.md:19-22) names "before prompt admission".
  - *Early activity waits for admission* (omp-sessions spec.md:64-67) stays as defensive staging.
- **Recording standard:** given the source cannot be opened here, recording this as an Assumption with an explicit check is adequate.

**2. (M2): Applied.**
- C11 (design.md:105) uses the requested wording, kind invariant and the single destination `ADR 0018`.
- The code confirms the premise: OMP gets `runId: null` (agent_service.dart:1349), and the existing token is built from `runId` (agent_session.dart:839).

**3. (M3): Applied.**
- **Correlation** (design.md:50) says:
  - closed ids are held in a bounded FIFO;
  - reaching the cap evicts the oldest;
  - a start that reuses an evicted id "opens a new card with a fresh local id";
  - "Only the open cap refuses new cards."
- **Resource Bounds** (design.md:202):
  - keeps the cap of 16 open cards;
  - says "Evict the oldest closed id when its cap is reached";
  - gives "sequential calls keep opening cards" in the 10x/100x column.

**4. (M4): Applied.**
- A1 (design.md:89) says `overflowFrame` emits `rpc_frame_error` with `originalType` when the failed frame had a string type, and carries no request or tool id.
- The Failure table now has one `rpc_frame_error` row (design.md:189):
  - a known one-way transcript event gets an omission notice;
  - an interactive or host-tool frame, or an absent or unknown `originalType`, fails the run.
- The related rows agree:
  - approval frame: "a malformed or elided id fails the run" (design.md:183);
  - root tool event: marked incomplete (design.md:186);
  - native callback: "missing or unusable call id fails the run" (design.md:188).

**Round 1 Suggestions the author reports addressing, now verified:**
- **S2:** the THEN clauses can now be asserted.
  - desktop-host-protocol spec.md:16-18: another session's Stop is acknowledged while the queue is full, and the result arrives after credit resumes.
  - agent-runtimes spec.md:39-42: accepts, streams, Stops, and shows the approval and card without an exact-version row.
- **S3:** design.md:240 says "the active private callback replaces grant liveness in decision 16".
- **S4:** design.md:58 gives `label` as "(the name)".
- **S5:** the agent-sessions delta modifies *Replies and tool activity stream into the chat* (spec.md:5-6). It adds an OMP qualifier that forbids inventing location, kind or diff, and keeps all four existing scenarios.
- **S6:** the trade-off is recorded in Risks (design.md:235).
- **S1 was not adopted:** the table of 8 pending writes remains (design.md:60, 204, 224). It was optional and is not required.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

**S7. Two existing seams contradict the design, and the Context section does not name them.**

The spec scenarios would catch both in tests. Naming them now avoids a wrong first implementation.

- **Approvals before admission.** `_admitOmp` sets `_hasTurn = true` before OMP admits the prompt (agent_session.dart:335-337).
  - `AgentSession._nativePermission` refuses only on `!_hasTurn` (agent_session.dart:830), so it accepts an OMP request that arrives before admission.
  - If the D2 decline before admission is placed only behind that guard, a hook's lookalike `select` would get an actionable card.
  - The decline has to use the driver's admission state (`turn.accepted`, omp_driver.dart:160), or an equivalent flag passed to AgentSession. Name this in D2 or in Context.
- **Tools status.** OMP has no grant, so `toolsAuthenticated` is `false` (agent_service.dart:1358).
  - At the first turn end, agent_session.dart:684-689 changes *not yet used* to *not started by the adapter*.
  - `_startTools(null, …)` returns *unavailable* (agent_service.dart:1423-1427).
  - Left unchanged, a registered OMP run would show the bridge startup state that C7 (design.md:101) and agent-tool-access spec.md:145-147 forbid.
  - Name both sites and the planned change, for example: "registration success sets *not yet used* and marks the run authenticated".

**S8. Classify `prompt_result` explicitly in the `rpc_frame_error` rule.**
- The rule says "known one-way transcript event" (design.md:189). `prompt_result` needs no reply, but it is the terminal frame and has no other source.
- If an overflowed `prompt_result` were treated as an omission notice, the turn would stay Running.
- Stop would also never settle, because the running turn's `prompt_result` settles Stop (design.md:41). Stop would end at *not confirmed* until Close.
- Fix: list `prompt_result` with the frames that fail the run. A lost `response` is already covered by its command deadline: prompt admission fails the client (omp_driver.dart:197), and registration becomes unavailable (design.md:58).

**Criteria with no findings:**
- **Ownership:** the State table has one writer per row. The OMP token scope is justified by C11.
- **Bounds:** every new queue is bounded, and the fixed M3 row meets its 10x/100x claim.
- **Ordering:** covered by the M1 re-check and Flow & State Gaps (design.md:208-213).
- **Decisions:** no `Chosen by: user` decision was changed while applying the Required Changes. S1, S2, D1's scope and D4's transport are unchanged. The ADR plan (design.md:240) supersedes only ADR 0016 decision 5 (lines 37–43), which matches that decision's "until … implemented" wording.
- **Specs:** each modified or added requirement has a failure or refusal scenario. The THEN clauses round 1 flagged can now be asserted.
- **Claims:** every code range cited in Context (design.md:20-25) supports its claim on re-reading.
- **Carried constraints:** C1–C11 each have exactly one destination.
- **Test map:** there is no tasks.md yet.
- **ADR 0017:** the test approach (design.md:214) uses fixture acknowledgements, injected deadlines and real time only as outer hang guards. That fits AGENTS.md "Tests that run in Windows CI". The dart-add-unit-test and flutter-add-widget-test skills apply when tasks are written.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

Round 1 listed four Required Changes. This round checked each against the current text, and all four are applied:

1. **(M1)** Applied: A3 at design.md:91; D2 at design.md:40-42; design.md:208; omp-sessions spec.md:19-22.
2. **(M2)** Applied: C11 at design.md:105.
3. **(M3)** Applied: design.md:50 and design.md:202.
4. **(M4)** Applied: A1 at design.md:89; Failure table at design.md:183, 186, 188 and 189.

This round adds no new Required Changes. S7 and S8 are optional.

CHANGES_APPLIED: yes

## Rebuttals

None.
```