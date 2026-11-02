# Review

## Metadata

- **Round:** 1 re-check
- **Prior round:** Round 1: APPROVE_WITH_CHANGES with 4 Required Changes (C1 Windows endpoint I/O not host-cancellable; M1 early `authenticated` event lost before binding; M2 checker `fail` semantics for `kumiko tool call` undefined against ADR 0012 decision 7; M3 proposal silent on departing from "qualified session injection when supported"), CHANGES_APPLIED: no.
- **Reviewer:** fresh-context subagent (Claude Code, specwright-reviewer)
- **Reviewed:** openspec/changes/kumiko-tool-delivery/{review.md (round 1 Required Changes and Rebuttals), proposal.md, design.md (D2, D3, D6, D8, D10, Resource Bounds, Flow & State Gaps, status diagram), specs/agent-tool-access/spec.md, specs/agent-runtimes/spec.md, specs/desktop-host-protocol/spec.md}. Source as cited by the design and by round 1: packages/process_containment/lib/src/windows_pipe_io.dart (`:176-181`, `:300-321`), packages/host/lib/src/agent/agent_service.dart (`:657-672`), tool/check_qualification.dart (`:178-185`, `:369-370`), docs/adr/0012-agent-session-transport-and-qualification.md (decision 7). Re-check scope: only C1, M1, M2, M3. No skill was named for this re-check, so none was loaded.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

**C1. The Windows endpoint I/O plan contradicts itself, and the host cannot close its own end of a connection.** **Resolved.**
design.md D2 now specifies overlapped `ConnectNamedPipe`/`ReadFile`/`WriteFile` on the `FILE_FLAG_OVERLAPPED` handles. Each operation waits on its I/O event plus a stop event (`WaitForMultipleObjects`). A host-initiated close signals the stop event, and the worker then runs `CancelIoEx`, `GetOverlappedResult(..., bWait: TRUE)`, `DisconnectNamedPipe`, `CloseHandle` and exits. The host joins the worker before counting the slot free. D2 says explicitly that `WindowsPipeReader`/`WindowsPipeWriter` are not reused, and gives the reason from `windows_pipe_io.dart:300-321`. It names every close path: preamble deadline, authentication refusal, `busy`, line bound, revocation and host shutdown. It plans the Windows test for a client that never writes or closes, which must be disconnected within the preamble deadline with its slot freed. Resource Bounds adds a "Windows connection workers" row: cancellable by the stop event, with no peer cooperation needed. The agent-tool-access spec adds *Endpoint connection held open by a client*, which requires the close on every OS and the slot to be released. The *Wrong secret* and *Missing secret* THENs can now be met on Windows.

### Moderate

**M1. An `authenticated` event that arrives before binding has nowhere to go, so the status can falsely report *not started by the adapter*.** **Resolved.**
D6 now puts `everAuthenticated` and `everCalled` on the grant from the pending-slot stage on, with a citation to `agent_service.dart:657-672`. The session reads both flags when it is created. The first-turn-end transition reads the grant's `everAuthenticated`, not forwarded events. Flow & State Gaps (*Bridge connects before `session/new` answers*) says the same. The spec adds *Bridge authenticated during session creation*: the bridge authenticates before `session/new` returns and the first turn makes no tool call, and the pane must show *not yet used*, never *not started by the adapter*. That matches the Required Change.

**M2. The checker's `fail` semantics for `kumiko tool call` are undefined, and they conflict with ADR 0012 decision 7.** **Resolved.**
D8 now covers every point of the Required Change:
- **Where the text lives.** The observed text is held in the Notes cell as `observed: "<text>"`, and a `fail` without it fails the checker.
- **When a `fail` is accepted.** Only when `toolDeliveryFailures` lists the same name, the same version and exactly that text.
- **What else fails.** These cases all fail the checker, naming the adapter, version and OS: a `fail` with no list entry; a list entry whose evidence is `pass`, `unproven` or missing; a list entry whose text differs from the evidence.
- **Verdict.** QUALIFIED when every checked item passes or is an accepted tool-delivery failure. The accepted failure is printed. QUALIFIED is never given with an unaccepted `fail`.
- **Source grammar.** It is extended with a second literal after `qualifiedAdapters`. Its third string may contain spaces but no single quote, backslash or newline. An empty list is valid, and a missing or unparseable literal fails the checker. This addresses the limits found in round 1 at `check_qualification.dart:178-185`.

D10 now has ADR 0013 record D8's additive amendment of ADR 0012 decision 7. The agent-runtimes delta adds *Failure without its observation*, *Recorded failure matches evidence*, *Evidence failure without a list entry* and *List entry contradicts the evidence*. Together they cover the scenarios the Required Change asked for: `pass` evidence, different text, and a `fail` with no list entry. D8 also adds a transition note: the new evidence row and the checker change land together. That avoids a red CI on the existing 0.99.1 evidence.

**M3. The proposal does not name its departure from the backlog rule "qualified session injection when supported".** **Resolved.**
The proposal's What Changes now has *Delivery is not gated on qualification*. It quotes the backlog requirement and its "qualified session injection when supported" wording, and states that this change offers the entry to every ACP session instead. It gives D8's reasons: *connected* is shown only from an observed call (ADR 0005 decision 5), and gating would withhold the entry from the versions that need observing before they can be qualified.

No new Critical or Moderate finding was introduced by the edits.

### Suggestions

Round 1 suggestions S1-S5 are reported as applied in the Rebuttals. They were not part of the re-check scope and are carried forward without a resolution check:
- **S1.** Unknown notifications are ignored, and only requests get `-32601`.
- **S2.** From `notStarted`, a later authentication returns to `notYetUsed`. This is visible in D6's transitions and in the agent-tool-access scenario *Adapter never starts the bridge*.
- **S3.** `KUMIKO_UNIT` is in the `kumiko` entry's `env`.
- **S4.** The secret is redacted from the adapter stderr tail before it is sent to the desktop.
- **S5.** The endpoint access scenario is testable in CI through the ACL read-back and the socket modes.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **(C1) design.md D2 and the Resource Bounds row for Windows pipe instances.** Specify host-cancellable Windows endpoint I/O, state that `WindowsPipeReader`/`WindowsPipeWriter` are not reused, name the close paths, and add the never-closing-client Windows test. **Status: applied** (D2; Resource Bounds row "Windows connection workers"; spec *Endpoint connection held open by a client*).
2. **(M1) design.md D6 and Flow & State Gaps.** The grant records authentication from the pending slot on, the first-turn-end check reads the grant flag, and a spec scenario covers authentication during `session/new`. **Status: applied** (D6 `everAuthenticated`/`everCalled`; Flow & State Gaps first bullet; spec *Bridge authenticated during session creation*).
3. **(M2) design.md D8 and D10, and specs/agent-runtimes/spec.md.** Define the checker rule and the cell that holds the text, the verdict, the extended grammar, ADR 0013's amendment of ADR 0012 decision 7, and the mismatch scenarios. **Status: applied** (D8 bullets 1-5; D10; agent-runtimes scenarios *Failure without its observation*, *Recorded failure matches evidence*, *Evidence failure without a list entry*, *List entry contradicts the evidence*).
4. **(M3) proposal.md.** State that delivery is not gated on qualification, unlike the backlog's "qualified session injection when supported", and give the reason. **Status: applied** (proposal What Changes, *Delivery is not gated on qualification*).

<!-- yes (applied, and re-checked by the reviewer - only the reviewer sets it) | no (outstanding) | n/a (any other verdict) -->
CHANGES_APPLIED: yes

## Rebuttals

Author, round 1:
- C1 fixed: design D2 now specifies overlapped, host-cancellable Windows endpoint I/O (stop event, `CancelIoEx`, wait, `DisconnectNamedPipe`, `CloseHandle`, join), states that `WindowsPipeReader`/`WindowsPipeWriter` are not reused, names the close paths, and plans the never-closing-client test; Resource Bounds adds a Windows connection-worker row; spec adds *Endpoint connection held open by a client*.
- M1 fixed: D6 and Flow & State Gaps record `everAuthenticated`/`everCalled` on the grant from the pending slot on, and the first-turn-end check reads the grant; spec adds *Bridge authenticated during session creation*.
- M2 fixed: D8 states the checker rule (`observed: "<text>"` in Notes, match against `toolDeliveryFailures`), the verdict (QUALIFIED with an accepted failure, printed), the extended source grammar and the transition; D10 has ADR 0013 record the additive amendment of ADR 0012 decision 7; agent-runtimes spec adds three checker scenarios.
- M3 fixed: proposal What Changes states that delivery is not gated on qualification and why.
- S1 applied (notifications never answered), S2 applied (`notStarted` → `notYetUsed` on later authentication, spec and diagram), S3 applied (`KUMIKO_UNIT` in the entry env), S4 applied (secret redacted from stderr tails), S5 applied (endpoint access scenario asserts the ACL read-back and the socket modes).
