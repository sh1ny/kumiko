# ADR 0018: OMP approvals and private host tools

Status: Accepted  
Date: 2026-11-25  
Supersedes: ADR 0016 decision 5 for OMP approval handling and tool delivery only. Refines ADR 0005 decisions 1–3 and 5, ADR 0012 decision 2, and ADR 0013 decisions 4, 7, 8, 12, 16 and 18–20 for OMP only.

ADR 0019 amends decisions 2 and 4 for run-scoped identities and the additive
history and child-view peer gate. The private root-only binding is unchanged.

## Context

ADR 0016 connects one contained OMP root process to one Kumiko run. It leaves native approval settings intact, declines dialogs and omits Kumiko tools. M2 change 3 brings supported approval requests and root tool activity into the existing chat and connects authorized Kumiko tools. Direction D15 distinguishes OMP RPC host tools from MCP server registration.

## Decision

1. Keep the native policy and profile arguments. Only a recognized approval on an admitted root turn can show a card. Kumiko sends the exact one-shot or denial value selected by the user. It declines general dialogs and incomplete requests, never sends remembered approval choices, and never opens URLs for the runtime. An approval card is not policy enforcement or a sandbox. OMP may run tools without a prompt under its native policy.
2. Reuse the shared permission controls and normalized cards. Cancel outstanding choices before or alongside Stop; the native prompt result settles Stop. Close owns containment. A withdrawal retires its choice without answering it. OMP permission tokens and card ids are unique per Kumiko session id only because each OMP run gets a new session id. Scope both identities per run before adding OMP Continue.
3. Register the existing role-scoped Kumiko tools using `set_host_tools` on private OMP stdio. No MCP entry, bridge, transferable secret, listener or configuration write. The host checks every call against the active connection binding, local owner, role, immutable target, catalog and arguments using the same authorization as MCP. An active binding, not an MCP grant, supplies liveness for ADR 0013 decision 16. Registration failure leaves chat usable and tools unavailable; registration alone does not mean connected. A successful authorized result in the current run is required. Failure, Close or exit revokes the binding.
4. Keep the bounded relay and desktop priority control. When a run's event queue is full, unread OMP approvals and callbacks behind its output wait for credit in that same run. Do not drop transcript events or add a separate callback transport. Desktop control and unrelated runs remain serviceable. The existing `agent` and `omp` capabilities suffice.
5. Keep native minimum-version admission. Fixture tests check Kumiko's implementation, not that the installed runtime works. Change 5 records real Windows observations. This decision adds no exact-version gate, history or child controls, or read-only role enforcement.

## Consequences

Claude and Codex retain the MCP endpoint, grants and status rules. OMP can use host tools even if the MCP endpoint is unavailable, and never reports that a bridge failed to start. OMP runtime configuration, provider setup and native approvals remain outside Kumiko's authority.
