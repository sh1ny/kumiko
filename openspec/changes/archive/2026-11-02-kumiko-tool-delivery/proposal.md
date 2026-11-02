# Proposal

## Why

Roadmap milestone **M1 - Local development loop (walking skeleton)**, change 5. M1 has to prove that Kumiko can give a running agent its own tools, the last risky assumption in the walking skeleton (ADR 0005). Sessions start today with an empty `mcpServers` list (`packages/host/lib/src/agent/acp/acp_client.dart:260`), so no agent can reach Kumiko at all.

Exit criteria this change advances:
- *The Claude Code session calls a read-only Kumiko tool, or the UI reports Kumiko tools unavailable for that adapter version with the observed failure. A call with a wrong or missing session secret is rejected (ADR 0005). (agent)* This change delivers it in full.
- *Killing the desktop leaves no host, agent or shell process ... (ADR 0001).* This change adds a new process kind, the bridge. It runs inside the agent's contained unit and exits when its host or its adapter goes.
- *Stop, permission replies, resize and close still complete under saturation (ADR 0002).* Tool traffic travels on its own endpoint and must not delay desktop control.

Prerequisite `claude-acp-chat-session` is done (archived on main).

## What Changes

- **Host tool service.** The host runs one MCP tool service for its whole lifetime. It listens on a **per-user local endpoint**: a named pipe on Windows whose access list admits only the current user and rejects remote clients, and a Unix domain socket inside the owner-only profile directory on Linux and macOS. The endpoint is removed when the host exits. If it cannot be created, the host still starts and sessions show Kumiko tools as unavailable with the reason.
- **`mcp-bridge` mode.** The bundled host executable gains a `--mcp-bridge` mode, a thin relay between the MCP stdio its adapter speaks and the host endpoint. It is launched by the adapter, so it is a descendant inside the session's contained unit. It exits when its stdin closes or the endpoint goes away.
- **Delivery.** `session/new`, `session/load` and `session/resume` carry one stdio MCP entry, `kumiko`, whose command is the bridge. No repository or runtime configuration file is written or changed (D14, D15).
- **Per-session secret.** Each live session run (start or Continue) gets a fresh random secret, passed only through the MCP entry's environment. It is never stored and never written to the repository. The secret maps to exactly one live session and is revoked when that run ends. A connection with a wrong, missing or revoked secret is rejected before any MCP traffic.
- **Per-call authorization.** Every tool call is checked in the host against the session's role, owner and target. A tool the role does not allow is absent from the list and rejected if called anyway. M1 has the `coding` role only.
- **One read-only tool,** `kumiko_session_info`. It returns the calling session's Kumiko session id, role, runtime, and target workspace path. It reads host memory only and changes nothing.
- **Honest status.** Each chat pane shows one Kumiko tools status: *not yet used*, *connected* (only after an authenticated call succeeded in this session run), *not started by the adapter* (the first turn ended and no bridge for the session had authenticated), or *unavailable* with its reason. The reason is either an endpoint failure or a recorded failure for that exact adapter version. The status travels on the existing agent control path; no protocol version bump.
- **Delivery is not gated on qualification.** The backlog's *Automatic connection uses supported native mechanisms* says "qualified session injection when supported"; this change offers the entry to every ACP session instead. *Connected* is shown only from an observed call (ADR 0005 decision 5), so an ungated entry claims nothing. Gating would also withhold the entry from exactly the versions that need observing before they can be qualified.
- **Qualification.** The Claude ACP qualification records a `kumiko tool call` item per OS, and the checker requires it for every listed adapter version. The qualified list can mark an exact adapter version's tool delivery as failed, with the failure it observed, so the UI reports that failure for that version.
- **ADR.** A new ADR records the endpoint, bridge handshake and tool contract details that later tool changes must follow. ADR 0005 is not superseded.

Out of scope: write tools, project or task tools (M3+), the read-only chat role and its enforcement over runtime built-ins (D54, M2), additive native repository registration (D15 fallback, not qualified), team grants (M4), Codex and OMP delivery (M2).

## Capabilities

### New Capabilities
- `agent-tool-access`: the host-owned Kumiko tool service as agents see it: delivery into ACP sessions, authentication by per-session secret, per-call authorization, the read-only session tool, and the honest Kumiko tools status. Source: backlog `document-kumiko-direction` `agent-tool-access` requirements *Kumiko tool authority is authenticated and scoped*, *Tool operations respect the session role* and *Automatic connection uses supported native mechanisms*, and decisions D14 and D15. The parts this change delivers are carried over; the project, team and registration parts stay in the backlog.

### Modified Capabilities
- `agent-runtimes`: tool delivery becomes per-version qualification evidence. The qualification records a Kumiko tool call per OS, and a recorded failure for an exact adapter version is reported for that version. This is an added requirement; existing requirements are unchanged.
- `desktop-host-protocol`: agent control messages carry each session's Kumiko tools status in the per-session state sequence, and tool traffic never uses the desktop connection. These are added requirements.

## Impact

- **Host** (`packages/host`): new tool service, endpoint and bridge mode (`host_main.dart` dispatch beside `--unit-exec`); `AgentService` mints and revokes secrets and builds the MCP entry; `AcpClient` sends a non-empty `mcpServers`; `qualified_adapters.dart` gains tool-delivery data.
- **process_containment**: Windows named-pipe server and client over FFI with an owner-only security descriptor. `dart:io` Unix domain sockets cover Linux and macOS but not Windows.
- **host_protocol**: an additive `tools` field on agent state and on the start and Continue results.
- **Desktop**: the chat pane shows the Kumiko tools status.
- **Tooling and docs**: `tool/qualify_claude_acp.dart`, `tool/check_qualification.dart`, `docs/qualification/claude-agent-acp.md`, a new ADR, and the `openspec/architecture.md` index.
- **Dependencies:** none added. MCP is spoken by a small built-in JSON-RPC subset (`initialize`, `tools/list`, `tools/call`, `ping`), so the dependency audit is unchanged.
- **Security:** this adds the one listening surface ADR 0005 allows. It is tested per OS for owner-only access.
