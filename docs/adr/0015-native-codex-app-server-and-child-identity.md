# ADR 0015: Native Codex App Server and child identity

Status: Accepted, 2026-11-10

## Context

M2 needs Codex conversations and a foundation for later child-conversation
inspection. The reviewed `codex-app-server-session` design D1-D7 selects direct
App Server integration, preserving shared session lifecycle and authorization.
The installed minimum candidate is Codex 0.166.0. Contract research and real
provider observations are separate; see
[the research record](../qualification/codex-app-server.md).

## Decision

1. A narrow Dart runtime driver maps native stdio JSON-RPC to the shared
   AgentService/AgentSession contract. Claude remains ACP; OMP remains future
   native RPC. Extract only wire mechanics concretely shared by both drivers.
   No Node/Python SDK sidecar, Codex ACP wrapper or generic plugin framework.
2. One contained App Server serves one root conversation and its native child
   threads. UnitManager and the ledger own launch and settlement. Reserve the
   existing channel/unit, revalidate the immutable target, and retain cleanup
   ownership until all descendants settle. No shared multi-root process.
3. Admit installed native Codex versions at or above 0.166.0, without pinning,
   exact-version admission lists or evidence-based feature disabling. Resolve
   the native executable by file-only detection or explicit profile. Never run
   npm during detection or scan another application's private installation.
   A separate ledgered UnitManager probe uses `--version` in the owner-only
   host profile directory, resolution-essential environment and no tool grant.
   Settle it before App Server launch. Unknown, below-minimum or inconsistent
   identity fails before thread creation. Compare initialization version when
   present. Save `codex-app-server`, the verified exact executable version and
   native thread ID; Continue and fresh recovery filter profiles by runtime
   kind. Preserve Claude records and an existing global default; on an empty
   store prefer detected Claude, otherwise Codex.
4. Initialize before creating/resuming threads. Register correlation before
   observable writes and handle events racing responses. Only native terminal
   events prove completion; a write failure is terminal even after a response.
   Malformed core initialize/thread/turn/message/command/file/approval contracts
   fail the run. Unsupported optional steering, questions, elicitation, history
   paging and child metadata disable only that feature with a visible reason.
   Unknown optional events are tolerated; unknown privileged requests are denied.
5. Preserve native offered approval choices and fence answers by run, thread,
   turn and request. Retire requests on cancellation, completion, close or loss.
   Ordinary Send remains idle-only. Explicit Steer requires the sequenced live
   run/turn identity and shares revision-guarded draft removal/admission. Refusal
   preserves the draft; admitted inputs are never retried automatically.
6. Stop atomically admits pending-interaction cancellation replies and native
   interrupts before Stopping. Saturation refuses busy without partial writes.
   Address the root and known active child turns. Aggregate unknown/error/
   interrupted/finished into the existing four Stop outcomes; timeout remains
   unconfirmed and Stopping, with late outcome reported honestly. Stop never
   substitutes containment killing; explicit close settles the whole unit.
7. Saved panes launch nothing. Explicit Continue revalidates the original target
   and compatible runtime, prepares a fresh grant and resumes native history.
   Bound paging and snapshot/live merge, deduplicate thread-qualified item IDs,
   and fail unavailable on oversized/untrustworthy history. Never replay prompts
   or persist transcripts in Kumiko.
8. Deliver MCP configuration only through a proven private stdin request, with
   credentials confined to `mcp_servers.kumiko`'s entry environment. No secret
   in parent environment, argv, persisted config or logs. Read effective config
   first; existing or unprovably absent `kumiko` conflicts refuse delivery.
   Unsupported safe delivery leaves chat available and tools visibly unavailable.
   Bind pending grants to the created native thread within the existing creation
   deadline; revoke on failure without repeating thread creation. Connected still
   requires a successful host tool call. Authorization and immutable target
   checks remain per call. Scan runtime-written and host profile files for a
   run-secret canary after fixture and separately approved real runs; a match
   refuses that version/configuration path without printing the secret.
9. Preserve authoritative root/child/parent IDs and thread-qualified item keys.
   Never infer relationships from names or reassign unknown-child content to the
   root. The Codex driver owns a bounded child registry; AgentSession alone
   publishes a sequenced delegated summary (active children, waiting requests,
   incomplete visibility). Close, quit and Stop read this control state even
   without transcript credit. Incomplete visibility keeps warnings conservative.
   Root tools remain scoped to the immutable root; keep the four-connection
   grant cap, reporting additional child tools unavailable separately. No full
   child browser or targeted child controls in this change.
10. Record exact-version/OS observations independently of admission. Required
    observations: launch/streaming, tool activity, command approval, Stop,
    close/descendants, Kumiko tool call and auth-required with observed signature
    or explicitly unverified. Recovery, steering, questions and child attribution
    are separate optional observations. Checker outcomes are PASS, INCOMPLETE or
    FAIL, never Codex QUALIFIED/ACCEPTED. A recorded tool-delivery failure disables
    that exact version's tools with its reason; a later observed call wins.
    Missing evidence never disables compatible runtimes. M2 close requires real
    Windows evidence for the then-installed version. Fixtures prove no provider
    behavior; provider calls/auth experiments require separate approval.

## Bounds

Shared ADR 0002/0012 admission, line, relay, credit, control-priority, stderr,
transcript, unit and settlement limits remain authoritative. No duplicate
unbounded native buffers. Additional limits:

| Resource | Limit and refusal |
|---|---|
| Version probe | One per start; 4 KiB combined retained output; 5 s; counts toward unit/start admission; oversize/saturation refuses |
| Native requests | 32 per run within existing aggregate native write budget; busy before mutation; startup/history 60 active seconds; steer/answer acknowledgements 10 s |
| Foreground turn | One per root; further input requires explicit supported Steer |
| Early correlation | 64 messages/256 KiB charged to relay; fail flood; 5 s after response deadline |
| Child registry | 64 children; shared identity bound; overflow marks visibility incomplete and withholds excess content |
| Unknown-child attribution | 32 messages/256 KiB charged to relay, 5 s; notice and withhold, never reassign |
| Pending interactions | 16 including children, within control bytes; native unavailable/cancel and visible capacity refusal |
| Bridge clients | Existing four authenticated connections per root grant; further child bridges refused busy |
| History/child refresh | One read in flight/root, at most 50 items/page when supported, shared line cap and startup/history deadline |
| Deduplication | 4096 thread-qualified keys/root; oldest eviction with visible truncation; snapshot boundary prevents replay |

Native responses share stdout with transcript output: stalled credit may delay
remote completion, while local Stop admission and acknowledgement stay independent.

## Limited supersession

Accepted ADR files remain unchanged. This decision supersedes ADR 0004's Codex
through ACP/runtime-family choice only; immutable targets and Claude remain in
force. It refines ADR 0012's initialization/process language and supersedes its
exact-version admission/feature gating for Codex only. It refines ADR 0005
decision 2 and ADR 0013 decisions 7/8/12 for private native configuration and
thread-start binding, preserving entry-only isolation. It amends ADR 0014
decision 1 to include known active children in close/quit affected work; its
terminal activity and draft rules remain unchanged. It explicitly departs from
parked direction D6 and Codex ACP wording in D7, leaving that parked change intact.

## Consequences

Kumiko owns native compatibility and narrow mappings, gaining SDK independence
and durable child attribution. Driver replacement has medium reversal cost;
root identity or process sharing has high reversal cost. ACP Codex, external SDK
sidecars and a shared App Server were rejected because they add translation or
runtime dependencies, or weaken root containment. Child browsing needs a separate
reviewed change. Windows observations do not prove Linux/macOS behavior.
