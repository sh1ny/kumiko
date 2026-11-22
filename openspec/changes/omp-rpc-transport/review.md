# Review

## Metadata

- **Round:** 3
- **Prior round:** round 2 REVISE, Moderate 1 open
- **Reviewer:** cross-model CLI (codex, Orca worker)
- **Reviewed:** proposal.md, design.md and all four capability specs in openspec/changes/omp-rpc-transport; main agent-runtimes, agent-sessions, agent-tool-access, desktop-host-protocol and codex-sessions specs; openspec/architecture.md and roadmap.md; ADRs 0002, 0004, 0005, 0012, 0013 and 0015; host agent runtime_driver.dart, agent_session.dart, agent_service.dart, native_io.dart, codex/codex_client.dart, codex/version_probe.dart, adapter_detector.dart and runtime_profile_service.dart; host_protocol messages.dart and agent_events.dart; desktop agent_controller.dart, workbench_page.dart, runtime_profiles_dialog.dart and agent_transcript.dart; installed dart-add-unit-test and flutter-add-widget-test skills. `openspec context --json` resolved the local root with no referenced stores or unresolved references. External OMP wire documentation was not supplied; this review assesses the stated contract against repository evidence, not real-runtime compatibility.

- **Round 2 scope:** Re-checked only Required Changes 1-3 and Suggestion 1 against edited design.md and specs/omp-sessions/spec.md and the author rebuttals; no implementation verification or wider review performed.

- **Round 3 scope:** Re-checked only the remaining Moderate 1 / round 2 Required Change 1 against design.md D1, Resource Bounds, Flow & State Gaps and the matching omp-sessions spec scenarios and author rebuttal; earlier accepted findings remain accepted.

## Findings

### Critical (blocking)

None.

### Moderate

1. **A late abort acknowledgement can turn an unconfirmed Stop into a killed session.** Design D1 and State & Ownership remove command correlation on deadline; Failure & Visibility and the malformed-frame scenario require every response with no waiting command to fail the session and terminate its unit. But Flow & State Gaps says a late abort response is ignored, and the Stop spec requires a late abort to remain Stopping without termination. Concrete sequence: abort k3 times out at ten seconds, its pending entry is removed, then its success response arrives before prompt_result. The general response rule now kills the process instead of permitting the late terminal result. The existing Codex client explicitly tolerates unmatched responses (codex_client.dart around line 346), so sharing framing does not supply the necessary policy. Specify how issued-but-expired abort IDs remain distinguishable from truly unsolicited IDs, with bounded retention, and how a turn result preceding the abort acknowledgement retires correlation. Cover both orderings in fixture tests.

   **Round 2 re-check: not resolved.** D1 and the Retired command ids row explicitly fail a response after its ID falls out of the 32-entry FIFO. A delayed abort acknowledgement can therefore still kill a healthy session: let its prompt_result settle the turn, let that abort expire, complete enough subsequent turns with expired aborts to evict its ID, then deliver its acknowledgement. Neither the design nor the spec bounds how late an acknowledgement may arrive. The revised Stop scenario promises no termination after the deadline without this exception, and the malformed-frame scenario now speaks of never-issued IDs while D1 also kills formerly issued IDs. The window fixes the immediate race but preserves the original failure after eviction. Distinguish previously issued IDs permanently with bounded state (for example, validate the generated monotonic ID range using an issued high-water mark), or supply another bounded policy that never turns an issued late abort acknowledgement into a protocol failure; add an eviction-boundary fixture.

   **Round 3 re-check: resolved.** D1 now classifies a non-waiting response using the generated per-client k<n> range and one issued high-water mark, rather than an evicting ID window. Previously issued abort acknowledgements remain harmless regardless of intervening command count or elapsed time, while never-issued IDs still fail. The resource row records constant-size ownership, Flow & State Gaps requires all three race fixtures including delivery after more than 32 subsequent commands, and the malformed-frame and late-abort spec scenarios match that policy. This resolves the remaining design finding; fixture execution belongs to implementation.

2. **The delta-deduplication map has no actual memory bound.** D4 retains flags for each messageId/contentIndex until turn end, while Resource Bounds justifies this using transcript bounds. Those bounds belong to the desktop: agent_transcript.dart retains at most 2,000 entries/8 MiB and evicts old content; they neither limit the number of messages in a live native turn nor evict driver keys. The host's bounded event relay likewise limits queued bytes, not cumulative identities. An extended tool loop emitting many short assistant blocks can therefore grow the driver map indefinitely while the desktop continuously drains and evicts. Define a key-count and encoded-identity-byte limit, release completed-message state where contract-safe, and specify a visible overflow policy that preserves the no-duplicate guarantee. Test more identities than the limit during one turn while output is consumed.

   **Round 2 re-check: resolved.** D4 now releases flags at message_end, limits open messages to 64, content indexes to 256 per message and encoded message IDs to 4 KiB, and fails visibly instead of evicting flags. The resource row and Too many open messages scenario make the host-side overflow behavior assertable independently of desktop eviction.

3. **The promised provider-key secrecy is not implemented by the cited redaction path.** The OMP configuration spec requires an inherited provider key to appear in no desktop message, record or log, while D8 inherits the environment and D3/D5 use existing redaction. AgentService._secretsFor (around lines 404-410) supplies only current/recent Kumiko grant secrets to redactToolSecrets; OMP deliberately has no grant. Thus an OMP notice, error, approval title or startup stderr tail echoing an inherited provider credential is forwarded with that credential intact. This is a concrete gap in the new provider-key scenario, independent of later MCP delivery. Define the host-private source of known OMP credential values and a bounded redaction policy across streamed chunks, notices, errors and stderr, without publishing the values; alternatively explicitly narrow the spec to a guarantee the design can enforce. Include a synthetic provider-key canary in fixture output and verify the agreed guarantee across those paths.

   **Round 2 re-check: resolved by narrowing the guarantee.** D8 explicitly limits the promise to Kumiko not copying the inherited environment into its outputs and acknowledges that runtime-emitted text receives only existing grant-secret redaction. The revised requirement and non-echoed provider-key canary scenario test that narrower, enforceable promise. This acceptance does not claim provider-key echoes are redacted.

### Suggestions

1. **Make ADR supersession explicit.** The planned ADR 0016 should explicitly amend ADR 0004 decision 2 and the applicable ADR 0012 qualification wording for OMP minimum-version compatibility, plus ADR 0005/0013's universal tool-entry language for the temporary no-entry/no-grant behavior. ADR 0015's exceptions are expressly Codex-only. Listing the new choices without identifying the amended clauses leaves contradictory in-force instructions for later OMP work.

   **Round 2 re-check: resolved.** The ADR section explicitly names the OMP-only amendments to ADR 0004 decision 2, ADR 0012 qualification wording and ADR 0005/0013 per-run tool-entry rules for ADR 0016 to record during apply.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

All three round 1 Required Changes have been applied and re-checked by the reviewer. Moderate 1 was resolved in round 3; Moderate 2, Moderate 3 and Suggestion 1 were accepted in round 2. No open items remain.

CHANGES_APPLIED: yes

## Rebuttals

Author, round 1; reviewer responses from round 2:

- Moderate 1 / Required Change 1: author reports fixed; **reviewer objection:** the 32-ID FIFO still fails legitimate late acknowledgements after eviction; see the round 2 note above.
  - design.md D1 adds a retired-id window: the 32 most recent retired command ids, FIFO. Late responses to retired ids are dropped; only ids that were never issued or have fallen out of the window fail.
  - Flow & State Gaps "Stop and the result race" covers both orders and names the fixture tests.
  - Resource Bounds gains a "Retired command ids" row.
  - omp-sessions spec: the "Malformed frame after start" scenario is reworded, and a new scenario "Abort acknowledged after its deadline" is added.
- Moderate 2 / Required Change 2: fixed; **accepted by reviewer**.
  - design.md D4 releases a message's flags at `message_end`, with bounds of ≤ 64 open messages, ≤ 256 content indexes and `messageId` ≤ 4 KiB. Overflow fails the session instead of evicting, which preserves the no-duplicate guarantee.
  - The Resource Bounds row is replaced.
  - omp-sessions spec gains the scenario "Too many open messages".
- Moderate 3 / Required Change 3: fixed by narrowing the guarantee to what can be enforced; **accepted by reviewer**.
  - design.md D8 adds "Secret scope": Kumiko never copies the inherited environment into records, logs or desktop messages. OMP's own output text is shown as OMP wrote it, after the existing redaction, as for Claude. Per-value redaction of inherited variables is deliberately not built.
  - omp-sessions requirement "OMP configuration and sign-in stay native" is reworded accordingly. Its "User-configured provider" scenario now uses a canary that OMP receives but does not echo.
- Suggestion 1: adopted; **accepted by reviewer**. design.md ADRs now says ADR 0016 amends, for OMP only, ADR 0004 decision 2, ADR 0012's qualification wording, and ADR 0005/0013's per-run tool entry.

Author, round 2:

- Moderate 1 / Required Change 1 (round 2): fixed; **accepted by reviewer in round 3**.
  - design.md D1 replaces the 32-id FIFO with an issued high-water mark, one integer per client. A response for any `k<n>` with `n` at or below the highest issued counter is dropped harmlessly however late it arrives. Only ids never issued, or malformed ones, fail.
  - The Resource Bounds row is replaced with "Issued-id high-water mark".
  - Flow & State Gaps requires a fixture that delivers the old acknowledgement after more than 32 later commands have been issued and settled.
  - omp-sessions spec: "Malformed frame after start" now reads "a response whose id Kumiko never issued", and "Abort acknowledged after its deadline" covers delivery after many later commands.
