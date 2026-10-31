# ADR 0012: Agent session transport and qualification

- **Status:** proposed
- **Date:** 2026-10-31
- **Source:** change `claude-acp-chat-session` design D1, D4, D5, D10, D11, D13 and D15; user decision (2026-10-31), argv profiles with no bundled adapter; ADR 0001, ADR 0002 and ADR 0004

## Context

ADR 0004 places runtime adapters in the host and allows capabilities only from evidence for the adapter version in use. Agent sessions need a transport that does not let a streamed reply or history replay delay Stop, permission replies or close. The execution ledger and workspace cleanup gate (ADR 0001) must still identify one session's process tree. Later runtimes must follow the same contract, not infer it from an archived change.

The user installs Node (at least version 22 for the Claude adapter) and the adapter. Kumiko does not bundle an adapter or manage provider sign-in. Automated fake-agent tests prove Kumiko's behaviour, not the behaviour of any real adapter version.

## Decision

1. **One contained adapter process per session.** Start through `UnitManager.launch(kind: 'agent', target: <workspace path>)`. The existing ledger, unit cap, cleanup gate and settlement apply. Closing a session terminates its contained unit, including tool descendants; a crash affects that session only. Do not use the adapter's multi-session process support.
2. **Transcript data and control are separate.** Reserve one host-to-desktop data channel per start or Continue (ADR 0002). After `agent/attach`, send normalized newline-delimited JSON events: `user`, `agentText`, `thought`, `tool`, `toolUpdate`, `plan`, `notice`, `replay{start|end}` and `turn{stopReason}`. State (`agent/state`), permission requests and resolutions, Stop results, turn end, exit and close failure travel on channel 0. Control is never queued behind data, so transcript backpressure cannot consume the pending-control allowance or delay other sessions' control.
3. **The host owns the ACP boundary.** Runtime-profile and agent methods are additive desktop-host protocol methods, gated on `Capability.agent`, with no protocol version bump. Start and Continue return the event channel and normalized adapter/capability information; attach starts event delivery. Prompt, Stop, permission reply, close and release are control requests, with state and asynchronous results on control. Do not tunnel raw ACP to the desktop.
4. **Runtime profiles are argv, not shell commands.** Profiles reuse the shell-profile argument and environment validators, add `runtimeKind`, omit `cwd`, and always execute in the session's target workspace. There is no bundled adapter.
   - Use absolute executable paths as supplied. Resolve bare names on the host's `PATH`, then the well-known directories below.
   - On Windows, try the `PATHEXT` extensions in order. The first match must be an `.exe`; refuse `.cmd` or `.bat` with the batch-file reason and do not continue to a later `.exe`. Refuse absolute `.cmd` and `.bat` paths too.
   - Search macOS `/opt/homebrew/bin`, `/usr/local/bin`; Linux `/usr/local/bin`, `~/.local/bin`; both POSIX systems `~/.npm-global/bin`, `~/.volta/bin` and the newest `~/.nvm/versions/node/*/bin`; Windows `%APPDATA%\npm`, `%ProgramFiles%\nodejs`. These follow `PATH`, including when a GUI launcher supplies a minimal environment.
   - Detect the installed `claude-agent-acp` shim off-isolate at host start, capped at two seconds. Resolve its package script (`lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js` below the POSIX install root, following the bin symlink; `node_modules\@agentclientprotocol\claude-agent-acp\dist\index.js` beside the Windows shim). Require the script to exist. Find `node` / `node.exe` beside the shim first, then on the search path. The built-in read-only, memory-only profile uses absolute Node plus absolute script, prepending Node's directory to its own `PATH` override.
   - A POSIX user profile may use `npx -y @agentclientprotocol/claude-agent-acp@<version>`. On Windows use `node.exe <nodejs dir>\node_modules\npm\bin\npx-cli.js -y @agentclientprotocol/claude-agent-acp@<version>` instead of the batch shim.
5. **Qualified capabilities are exact-version data.** `packages/host/lib/src/agent/qualified_adapters.dart` contains exact `(adapterName, version)` pairs with their qualified extra capabilities (`load`, `resume`). A run must both advertise a capability in `initialize` and match that exact list entry to claim it. An adapter that completes ACP protocol 1 initialization gets only the safe baseline without such evidence: prompt, streaming, tool activity, permission requests and cancel. A missing version is unqualified. Other protocol versions are refused.
6. **Qualification evidence survives the change.** Real per-version, per-OS observations live in `docs/qualification/claude-agent-acp.md`. `tool/qualify_claude_acp.dart` and the user record real runs: launch, streaming, tool activity, permission request, Stop, close with confirmation, load, resume, the observed authentication-required code and message, and macOS Finder/Dock detection and launch. The fenced document template is not evidence. No list entry is added before its evidence exists.
7. **CI checks the claims on every OS.** `tool/check_qualification.dart` parses the qualified source and evidence. Every listed pair needs baseline, authentication and macOS Finder/Dock evidence; load and resume are required only when claimed. Checked items must pass on Windows; only user-verified Linux/macOS items may be `unproven`. Authentication `pass` requires the observed code and message. Missing evidence, checked failures, blank results, unknown items/OSes and duplicate sections fail with pair/OS/item diagnostics. Unclaimed load/resume failures or `unproven` do not block other claims. A missing or unparseable qualified source fails. An empty list prints **NO CLAIMS (no adapter qualified)** with exit 0, never ACCEPTED or QUALIFIED. Nonempty claims print **ACCEPTED** while allowed unproven items remain (listing each), and **QUALIFIED** only when every checked item passes. Unproven is never counted as passed; M1 close requires QUALIFIED.

## Runtime profile implementation

`RuntimeProfileDefinition` in `domain` shares the shell-profile field validators and encoded-size bounds without introducing a working-directory field. Store v5 persists user profiles and native session references; built-ins remain in host memory. Profile deletion does not cascade into saved native records.

`RuntimeProfileService` owns `runtime/*` and `default_runtime`. A missing stored default remains selected but unavailable, with `defaultReason`; detection never silently replaces that choice. Only an unset default may select the detected built-in. Detection has one overall two-second deadline and runs outside the host event loop. `ExecutableResolver` preserves Windows first-match refusal and uses the shared native `access(X_OK)` helper on POSIX.

## Protocol implementation

`host_protocol` owns the runtime/agent control DTOs and `AgentEvent` codec. Events are UTF-8 newline-delimited JSON; use `encodeAgentEvent` to apply encoded-size bounds, and one `AgentEventDecoder` per received channel. Register the inbound channel before sending `agent/attach`, and grant its initial credit only after attach succeeds. Existing reservation and credit primitives provide the handshake without another transport abstraction.

`RpcException.data.reason` remains the outer protocol error reason. Continuation failures carry their separate subreason as `resumeReason`. Permission display fields are clamped within the 64 KiB encoded notification bound without changing opaque option identifiers. Metadata that cannot fit even after display clamping is refused as `invalid-params`; the host must surface unusable adapter input as a visible session failure, not silently drop or automatically answer the request.

## Rejected alternatives

- **Share one adapter process per runtime profile.** Sessions share a process tree, so close cannot terminate just one session's tools; a crash ends every session and the ledger target no longer names one workspace (ADR 0001).
- **Send transcript events as control notifications.** There is no per-session control credit. A chatty session or large replay could exhaust the 4 MiB pending-control bound, lose the peer and delay unrelated sessions and terminals.
- **Tunnel raw ACP to the desktop.** This creates a second ACP client and prevents the host from resolving permissions on close or desktop loss; adapters belong in the host (ADR 0004).
- **Execute Windows batch shims through `cmd.exe /d /s /c`.** Arbitrary argv cannot be quoted safely through that boundary (the BatBadBut class); the existing shell-profile contract is argv only.
- **Qualify semver ranges.** Adapter load/resume behaviour can change within a minor release. A range would claim unobserved behaviour (ADR 0004 decision 2).
- **Run the real adapter in CI, or substitute a fake to qualify it.** Real runs require provider sign-in or an API key and spend tokens. Fakes only prove Kumiko's protocol and state-machine handling.
- **Leave these decisions only in the change design.** Later runtime adapters need the same durable transport and qualification contract.

## Consequences

- Each live session consumes its own contained process unit and event channel. Transcript backpressure remains local while control stays responsive.
- Users maintain their adapter and Node installation; detection and editable profiles expose unavailable executables rather than silently substituting another launch path.
- Capability claims and evidence evolve together. An empty qualified list makes no qualification claim; Linux/macOS user observations may permit provisional acceptance but cannot close M1 until they pass.
- The checker is an offline audit of recorded evidence and source, not a provider call or a substitute for the real qualification run.

## Reversal cost

Medium for process sharing (agent service and ledger kinds) and the normalized event/control contract (both desktop and host). Low for argv resolution, exact-version host data and the qualification record/checker. Writing this ADR has low reversal cost; replacing its transport contract later needs a superseding ADR.
