# Review

## Metadata

- **Change:** omp-rpc-transport (FULL tier, repo-local OpenSpec root)
- **Round:** 4 follow-up, re-checking the round 4 Required Changes only
- **Prior round:** round 4 APPROVE_WITH_CHANGES, with Moderate 1-3 open (`20261123T005045118313Z.md`)
- **Reviewer:** Claude (Opus 5.5), Orca worker task_e09df375226d, read-only
- **Re-checked:**
  - amended design.md: D3, the Turn state diagram, the Resource Bounds table, and the Flow & State Gaps entries "`prompt_result` before the prompt response" and "Stop during admission";
  - tasks.md 7.3 and 7.4;
  - specs/omp-sessions/spec.md, the requirement "OMP prompt admission and completion are distinct" with its four scenarios.
- **Not re-checked:** findings from rounds 1-3 and the round 4 suggestions, except where an edit touches them. No code was run, and no code or artifacts were edited.

## Findings

### Critical (blocking)

None.

### Moderate

1. **Round 4 Moderate 1 (synchronous acceptance before output): resolved.**
   - D3 step 3 now has the driver's success-response handler call the session's synchronous acceptance callback "before returning to the line reader".
   - The callback enqueues the user event exactly once. Staged output may be released "only after the callback returns, before consuming another frame".
   - The Resource Bounds row was renamed "Events before prompt commit" and now ends "when synchronous session acceptance returns or Send is refused".
   - Flow & State Gaps holds an early `prompt_result` until acceptance, and delivers staged output before applying it.
   - The resulting relay order (`user`, staged output, then the terminal result) works with the session's single `_events` chain (`agent_session.dart:555-590`).
   - Task 7.3 adds the one-chunk test: acceptance, delta and terminal result, asserting exactly one user event before the reply and the turn end.
   - The spec scenario *Admission precedes output* now asserts that the prompt is shown once before any reply text or thinking.

2. **Round 4 Moderate 2 (sole Send commit point): resolved.**
   - D3 step 4 makes the synchronous handoff "the sole Send commit point". After it, the service "returns success without re-checking session liveness or restoring the draft, even if a later frame immediately fails the run or Close removes it". Before it, every failure, including a timeout or transport loss, restores the draft under the revision guard and never resends.
   - The 60 s prompt admission deadline is now named in D3 and in the Waiting commands row. This also settles round 4 Suggestion 1.
   - Task 7.3 adds the case of acceptance immediately followed by transport failure: Send still succeeds and the draft is not restored.

3. **Round 4 Moderate 3 (published Idle vs direct Stop/Close): resolved.**
   - **Admission state.** D3 step 2 registers an internal admitting turn and keeps the published state Idle. The desktop offers no Stop during admission, which is consistent with `canStop` at `agent_controller.dart:256-262`. Concurrent Sends are rejected even when they carry no draft revision, which closes the retry gap at `agent_service.dart:1505-1509`.
   - **Direct Stop and Close.** A direct host Stop and Close still address the registered turn.
   - **Diagram.** The Turn state diagram adds "Admitting → Stopping: direct Stop sends abort".
   - **Flow & State Gaps.** "Stop during admission" now covers:
     - a Stop before registration, which returns `notRunning`;
     - acceptance after a Stop, which settles from `prompt_result` without falling back to Running;
     - a local completion or a refusal after a Stop, which settle as *Finished before Stop* or *Turn ended with an error after Stop* without publishing Running;
     - an ambiguous failure, which fails the session.
   - **Spec.** *Admission refused* now says "does not publish Running", which replaces the conflicting "stays Idle".
   - **Tasks.** Task 7.3 checks that the desktop-facing state stays Idle during admission, that a direct Stop can abort after registration, and that Claude and Codex still acknowledge Send before their runtime responds. That last check also covers round 4 Suggestion 3.

### Suggestions

1. **A leftover sentence in D3 contradicts step 4.** The paragraph after the D3 steps still says "the service awaits the admission result inside its existing draft error path". That existing path's catch-all would restore the draft on a post-await exception (`agent_service.dart:1528-1540`). Step 4 is explicit and takes precedence, but rewording the sentence to "awaits the admission result; only pre-commit failures enter the draft-restore path" would stop an implementer from reusing the old catch-all unchanged. This is a wording fix, not blocking.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

All three round 4 Required Changes are resolved in design.md, tasks.md and the omp-sessions spec. The amended D3 is consistent with the diagram, the resource bounds, Flow & State Gaps and the accepted round 1-3 decisions. Only one optional wording suggestion remains.

## Required Changes

All three round 4 Required Changes were applied and re-checked; none remain open.

1. Staging now ends on a synchronous session acceptance that runs before the next frame is read, and there is a one-chunk ordering test. Resolved.
2. The synchronous handoff is now the sole Send commit point, with no draft restore after it, and there is an acceptance-then-failure test. Resolved.
3. The published state during admission is Idle, with no desktop Stop. Direct host Stop and Close are specified and aligned across D3, the diagram, Flow & State Gaps and *Admission refused*. Resolved.

CHANGES_APPLIED: yes
