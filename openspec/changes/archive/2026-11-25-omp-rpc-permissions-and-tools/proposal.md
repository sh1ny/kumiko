# Proposal

## Why

M2's Windows daily-driver criterion calls for OMP permission requests and tool activity in the shared chat. The archived `omp-rpc-transport` change starts OMP and streams replies, but it cancels all dialogs, shows only a tool count and exposes no Kumiko tools. Fixtures will check the new behavior here. The owner will check the real Windows runtime in `omp-rpc-qualification` before M2 closes.

## What Changes

- Show supported native OMP approvals in the shared permission card. Offer only OMP's exact one-shot approval and `Deny`; do not grant remembered permissions or answer other dialogs. Explain in the OMP chat that native policy decides when OMP asks, and that Kumiko is not a sandbox.
- Show OMP's reported root tool calls and updates in the existing tool cards. Keep their native display limits and report omissions without inventing results.
- Register the existing Kumiko tool catalog for the root OMP run over private RPC. Check each call against the same host authorization as MCP and the immutable session target. Do not start an MCP bridge or issue a transferable secret. Report registration failure as unavailable and show connected only after a successful call.
- Preserve native settings, provider setup and third-party tool configuration. Keep save/resume, child activity, the read-only agent role, workspace trust and real-runtime qualification out of this change. Steering remains unavailable.

## Decision Making

DECISION_MAKING: autonomous

Source: setting. Owner scope and build gates still apply as directed in the dispatch.

### S1: Native policy, one-shot answers

- Choice: Preserve OMP's policy and offer one-shot approval and denial for recognizable approval requests whose details fit. Decline other dialogs.
- Rejected: Change the runtime's policy or enable native remembered grants, which can persist between sessions.
- Reversal cost: Low for adding supported dialog types; high after granting persistent approval.
- Important: yes (changes behavior the user sees).
- Chosen by: user (owner approval relayed by the coordinator).

### S2: Native host tool delivery

- Choice: Use `set_host_tools` on the private run connection. Keep authorization in the host and do not deliver MCP configuration or a transferable secret to OMP.
- Rejected: Require MCP delivery when OMP's RPC does not provide per-run MCP registration.
- Reversal cost: Medium for delivery; high if independent transports acquire different authorization rules.
- Important: yes (binds the authorization boundary).
- Chosen by: user (owner approval relayed by the coordinator).

### S3: Root session scope

- Choice: Build M2 change 3 only. Preserve the roadmap's separate history, children, read-only role and qualification changes.
- Rejected: Claim real OMP support from fixtures or change child attribution and recovery in this PR.
- Reversal cost: Low; the later roadmap changes retain those decisions.
- Important: yes (binds claims and user-visible scope).
- Chosen by: user (roadmap and owner approval relayed by the coordinator).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `omp-sessions`: One-shot native approvals and root tool cards replace automatic declines and the count-only notice.
- `agent-sessions`: OMP has an explicit exception to the shared rule to offer every native permission option. OMP withdrawal retires a pending card without answering it.
- `agent-runtimes`: OMP remains minimum-version compatible, with approval, activity and tool claims limited to the native contract and observed outcomes.
- `agent-tool-access`: OMP uses authorized private RPC callbacks rather than MCP. The local MCP endpoint and secret requirements still apply to Claude and Codex.
- `desktop-host-protocol`: Keep tool traffic off the desktop connection. Document OMP's private runtime route and the existing same-session backpressure limit without changing the wire.

## Impact

The host's OMP driver, session lifecycle and tool authorization change. The desktop adds OMP approval-policy guidance and reuses the shared cards and controls. No new dependency, protocol method, capability flag, listener or store migration is needed. Claude and Codex keep their existing native behavior and MCP delivery.

Sources: `openspec/changes/archive/2026-11-23-omp-rpc-transport/proposal.md`, `openspec/changes/archive/2026-11-14-codex-app-server-session/proposal.md`, and parked direction D6, D7, D14, D15 and D37. D15 distinguishes native host tools from MCP. This change selects the native alternative for OMP only and records the resulting exception to the per-run MCP rule during apply.

Branch gate: the pinned Specwright 0.39.1 binary reported interface 3 and a clean `feat/omp-rpc-permissions-and-tools` at `23de169`, equal to freshly fetched `origin/main`. Neither local nor remote main held an archive for this change. The branch already existed in the Orca worktree, so the dispatch authorized reusing it without switching another checkout to `main`.
