# ADR 0004: Qualified runtime adapters, immutable session targets and honest recovery

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D5, D6, D7, D20, D28, D30; user decision 2026-10-28 (Claude Code via ACP first)

## Context

Kumiko drives existing runtimes:
- Claude Code and Codex through ACP adapters;
- OMP through its native RPC.

These runtimes differ in streaming, questions/approvals, interruption, resume and tool delivery. Adapter versions change those features, for example ACP v2 `session/resume` versus older `session/load`. The reviewed direction requires several things:
- capabilities are claimed only when qualified;
- navigation never retargets an existing session;
- close and stop are distinct;
- reopening restores saved conversations via the runtime's own resume, never by resubmitting work.

## Decision

1. **Adapters live in the host**, one per runtime family: `acp` (stdio JSON-RPC subprocess per the ACP transport) and later `omp-rpc`. Each adapter maps its runtime onto a normalized **session model**:
   - messages and streamed chunks;
   - tool-call activity;
   - permission and question requests;
   - turn state (idle or working);
   - stop result;
   - exit.

   Richer runtime-specific controls stay adapter capabilities rather than being forced into the common model.
2. **Capabilities are evidence-based.** An adapter reports a capability (for example `resume`, `interrupt`, `kumiko-tools`, `model-select`) only when two things hold: the runtime advertised it during initialization, and that runtime/adapter version is on the qualified list kept with the adapter. Unqualified versions run with only the advertised features that are on the safe baseline. Their other features show as unavailable, never as working.
3. **Session identity.** A Kumiko session record holds:
   - a Kumiko session id;
   - owner (local user);
   - runtime kind, adapter and version;
   - native session id;
   - role (coding, or read-only chat later);
   - **execution target**: host and absolute workspace path, plus SCM workspace identity when present.

   The target is fixed at creation. Focus changes, project switches and layout changes never alter it. Moving work to another workspace means a new session.
4. **Stop versus close.** Stop asks the runtime to interrupt the current turn and reports the actual result. Unsupported interruption is reported as unsupported, never replaced by killing the process. Closing a working session requires user confirmation in the desktop and then terminates its process. Closing an idle one does not. Either way the saved session record and native history remain.
5. **Recovery.** On reopen, the desktop restores layout from the store (ADR 0003). Each restored agent tab shows a *saved, not running* state. Continuing uses the adapter's qualified resume path with the original native session id and target, and never replays prompts or tool calls. If resume is unavailable or fails, the tab says so and keeps the saved record. A lost host connection marks open sessions *stopped or unknown*, never *running*. A session that ADR 0001's reconciliation leaves *termination unconfirmed* is not resumed or relaunched. Its target workspace is *cleanup unresolved*, and no new session or terminal launches against that workspace until the condition is resolved.
6. Native runtime setup (credentials, models, skills, hooks, MCP entries) stays the runtime's own (D14, D20). Adapters launch the user's installed runtime and never copy its secrets.

## Rejected alternatives

- **One protocol for all runtimes** (for example wrapping OMP in ACP). It hides real capability differences and makes false claims likely.
- **Sessions that follow the focused workspace.** Rejected explicitly in the reviewed direction (source-control M1 finding).
- **Kumiko-side transcript replay for "resume".** It replays side effects and loses the runtime's own context.

## Consequences

- Each adapter needs a qualification suite runnable against a real runtime install. It cannot be mocked away, and results are recorded per version.
- The session model must allow capability gaps: the UI is built against capabilities, not runtime names.

## Reversal cost

High for session identity, target immutability and recovery semantics. Medium for adapter internals.

## Qualification in M1

On all three OSes, Claude Code via its ACP adapter must demonstrate:
- launch in a selected checkout, streaming chat, tool activity and a permission request;
- Stop, and close with confirmation;
- reopen through resume, or a visible *resume unavailable*.

The target-immutability test passes in automated form.
