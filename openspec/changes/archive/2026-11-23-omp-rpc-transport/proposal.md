# Proposal

## Why

M2 (Daily-driver workbench, Windows) needs OMP to run through its native RPC alongside Claude and Codex. The first exit criterion requires OMP to "stream replies, show tool activity, handle permissions and Stop, retain immutable targets, and truthfully expose save/resume support behind the shared session model".

Kumiko cannot start OMP today. ADR 0004 names `omp-rpc` as its own adapter family and rejects wrapping OMP in ACP.

The owner split the M2 OMP work into four changes (roadmap, 2026-11-14) so that each one is a single reviewable PR. This is the first of them, the transport. It covers:
- launching OMP;
- checking it before spawn;
- talking to it over a bounded client;
- a usable root session that starts, accepts prompts, streams replies and stops.

This advances the exit criterion for streamed replies, Stop and immutable targets. It also gives changes 3–5 a working session to build on.

## What Changes

- **New runtime kind `omp`.** It sits next to `claude-code` and `codex`. Profiles with this kind launch OMP's native RPC mode (`--mode rpc`) over private stdio, with no ACP wrapper and no network listener.
- **Built-in OMP profile.** It is read-only and offered when a native `omp` executable is found on PATH or in the official installer's directory. Windows batch shims are never executed. Another application's private installation is never an automatic discovery root.
- **Version probe before spawn.** A bounded, contained `omp --version` probe runs before the session process is spawned, and the executable is re-checked afterwards. OMP below the minimum version is refused with the version named. The readiness frame must offer RPC protocol version 1, or the start fails visibly.
- **Bounded OMP RPC client.** It speaks OMP's newline-delimited JSON commands, responses and events (not JSON-RPC). It reuses Kumiko's shared line framing, write admission and large-line rules, and caps how many commands may wait for a reply at once.
- **Usable root session:**
  - **Start.** Readiness is checked, then OMP's session identity is read and stored in the saved record.
  - **Prompt.** A prompt is committed to the chat only after OMP admits it.
  - **Streaming.** Reply text and thinking stream in order. The turn ends on OMP's terminal prompt result, not on the admission response.
  - **Errors.** Provider and authentication errors are shown as OMP reports them.
- **Stop.** Stop sends OMP's native abort and reports *Stopped* only when OMP reports the prompt aborted. A refused or late abort is shown and never replaced by killing the process. Close first ends input so OMP can shut down in order, then cleans up the contained process.
- **Fail-closed placeholders for later changes.** Each one is visible, so nothing is lost silently:
  - interactive OMP UI requests, which include tool approvals, are declined with a notice and never granted;
  - tool activity is summarised as a notice;
  - Kumiko tools are reported unavailable for OMP;
  - Continue is reported unavailable for OMP.
- **Desktop and protocol.** Both peers must advertise a new `omp` capability. The launch menu and the runtime profile editor offer OMP. An older desktop is refused before spawn.

**Out of scope:**
- approvals, tool cards and Kumiko tool delivery (change 3, `omp-rpc-permissions-and-tools`);
- save/resume, history restore, child activity and truthful close/quit (change 4, `omp-rpc-history-and-children`);
- real-runtime qualification (change 5, `omp-rpc-qualification`);
- workspace configuration trust (issue #22, as for Codex);
- the composer keys follow-up M2-F1.

## Capabilities

### New Capabilities
- `omp-sessions`: native OMP RPC sessions. Covers launch over private stdio, readiness and the protocol version, session identity, prompt admission versus completion, streamed replies, native Stop, ordered shutdown, and the visible fail-closed handling of OMP requests and features that later changes implement.

### Modified Capabilities
- `agent-runtimes`:
  - profiles gain the `omp` runtime kind;
  - OMP detection becomes a built-in profile under the same native-discovery rules as Codex;
  - OMP capability claims follow a minimum version and the native contract, not the ACP qualified list.
- `agent-tool-access`: the per-run Kumiko MCP entry requirement names the runtime families that deliver it. An OMP run reports Kumiko tools unavailable, with a reason, and keeps no unused grant.
- `desktop-host-protocol`: OMP start requires the `agent` and `omp` capabilities from both peers. Without them it is refused before spawn, while other runtimes stay usable.

## Impact

- **Host** (`packages/host/lib/src/agent/`):
  - a new `omp/` folder holding the client, version probe and runtime driver;
  - OMP detection in `adapter_detector.dart` and the built-in profile in `runtime_profile_service.dart`;
  - in `agent_service.dart`: start gates, probe, launch environment, driver selection and failure mapping;
  - a test fixture mode (`--test-fixture omp-agent`) and test hooks.
- **Protocol** (`packages/host_protocol`): a new `Capability.omp`, plus OMP gate checks next to the Codex ones. There are no new methods or events.
- **Desktop** (`packages/desktop/lib`):
  - OMP launch-menu items and profile-editor kind;
  - a runtime-specific composer hint;
  - peer capability advertisement.
- **Tests:** unit tests for the client and driver, host integration tests against a scripted OMP fixture, and desktop widget tests. No real `omp` is run in CI or by the agent; change 5 owns real-runtime evidence.
- **Dependencies:** none added. OMP stays user-installed and user-configured.
