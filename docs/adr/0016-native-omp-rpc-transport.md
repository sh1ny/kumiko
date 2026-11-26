# ADR 0016: Native OMP RPC transport

Status: Accepted  
Date: 2026-11-22  
Supersedes: OMP-only clauses of ADR 0004 decision 2, ADR 0012 decisions 5–7, and ADR 0005 decision 2 and ADR 0013 decisions 7, 8 and 12 as detailed below. Claude and Codex decisions remain in force.

ADR 0019 amends decisions 1, 2 and 4 for exact OMP Continue, child activity
and shutdown. ADR 0018 amends decision 5 for approval handling and tool delivery.

## Context

M2 needs OMP sessions in the workbench. ADR 0004 assigns OMP its own native
adapter rather than wrapping it in ACP. The `omp-rpc-transport` design uses the
OMP 18.20.1 wire contract for launch, prompt streaming, Stop and shutdown.
Real-runtime qualification is separate from this transport change.

## Decision

1. Run one contained `omp --mode rpc` process per root session over private
   stdio, using the profile arguments unchanged. Speak OMP v1 newline-delimited
   JSON, not JSON-RPC. Require readiness offering protocol 1; do not negotiate
   v2. Share existing line framing and write admission with other native clients,
   but keep OMP correlation and envelope validation in its own client.
2. Require both desktop and host to advertise `agent` and `omp` before probing
   or spawning. Use the shared agent channels and methods, not a new desktop wire.
3. Probe the resolved executable with a separate contained `--version` run in the
   host profile directory, using only the probe environment allowlist. Cap output
   at 4 KiB and execution at 5 seconds; settle the probe and recheck the executable
   before workspace launch. Admit 18.20.1 or newer. This amends ADR 0004 decision 2:
   OMP claims prompt, streaming and Stop from the native contract, not an exact
   version allowlist or ACP advertisement. For ADR 0012 decisions 5–7, real OMP
   qualification evidence is recorded separately in the qualification change and
   is not a runtime admission gate.
4. Select delta updates, read `get_state`, and require a nonempty, bounded
   `sessionId` before saving the immutable target, `omp` runtime kind, exact
   probed version and `omp-rpc` adapter identity. Admission commits the prompt;
   the matching `prompt_result` ends an agent turn. Stop sends native `abort` and
   never kills as a substitute. Close aborts a running turn and ends input before
   waiting for exit and settling containment.
5. Until OMP approvals are mapped, decline each interactive UI request with a
   cancelled response and a bounded notice; display-only requests perform no
   action. Do not override OMP's configured approval mode: it may run tools
   without presenting a request. Do not deliver a Kumiko MCP entry, mint a grant
   or bind one for an OMP run; report tools unavailable. This is the OMP-only
   exception to ADR 0005 decision 2 and ADR 0013 decisions 7, 8 and 12 until OMP
   tool delivery is implemented.

## Consequences

- OMP stays user-installed and user-configured. Kumiko neither writes its files
  nor copies its inherited environment into messages or records.
- Continue, steering and Kumiko tool delivery are unavailable in this change.
  Tool activity is counted, not shown as tool cards.
- A contained version probe adds startup work but rejects incompatible builds
  before running workspace configuration. Changing the minimum requires contract
  evidence for the proposed version; fixtures alone do not qualify real OMP.
