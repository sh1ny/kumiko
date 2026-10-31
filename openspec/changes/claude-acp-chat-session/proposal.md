# Proposal

## Why

After `host-terminals`, Kumiko has a tabbed workbench with real shells, but no structured agent. This is change 4 of **M1 - Local development loop (walking skeleton)**. It delivers Claude Code as a structured chat session through its ACP adapter (ADR 0004). It also qualifies the riskiest runtime assumptions of M1: whether the adapter streams, reports tool activity, raises permission requests, interrupts and resumes, and in which versions.

It advances these M1 exit criteria:
- **In an opened checkout, a Claude Code ACP session streams a reply, shows tool activity, raises a permission request the user answers, and can be stopped mid-turn. The Stop result reported is the actual one** (user, per OS).
- **An existing agent session keeps its original checkout as its target after the user focuses another workspace or project** (ADR 0004). Agent-verified by an automated test; user-verified by observing it once.
- **Closing a working agent asks for confirmation and closing an idle one does not** (user). The terminal half shipped with `host-terminals`.
- **Quit and reopen ... agent tabs show *saved, not running* and continue through the qualified resume path, or show *resume unavailable*** (user, per OS). The store round-trip is agent-verified.
- **With one terminal saturating output and another's consumer stalled, Stop, permission replies ... still complete** (agent, ADR 0002). `host-terminals` left Stop and permission replies to this change.
- **Killing the desktop leaves no ... agent process; killing the host cleans every unit** (agent, per OS, ADR 0001). Adapter processes become contained units under the existing ledger.

**User decisions (2026-10-31):**
- **Adapter launch:** the adapter is launched from a user-editable **runtime profile**, an argv like a shell profile, with a detected default. Kumiko bundles and installs nothing.
- **Session target:** an agent session needs a selected workspace (checkout). Personal with no workspace does not start one.
- **Permission mode:** sessions run in the adapter's default (Manual) permission mode. There is no mode picker in this change.
- **Continue on reopen:** Continue uses ACP `session/load` where qualified, so the earlier conversation is shown. It falls back to `session/resume` with a visible note, and otherwise shows *resume unavailable*.

## What Changes

- **Runtime profiles.**
  - A runtime profile is an executable, an argument list (never a command string) and environment overrides for the Claude Code ACP adapter (`@agentclientprotocol/claude-agent-acp`).
  - The host detects an installed `claude-agent-acp` on PATH and in well-known install directories, so a desktop started from the Dock or a launcher still finds it. The built-in profile runs the absolute `node` path plus the adapter script.
  - The user can add, edit and remove profiles and choose a default. On Linux and macOS that can be `npx -y @agentclientprotocol/claude-agent-acp@<version>`. On Windows, where `npx` is a batch file, it is `node.exe` with npm's `npx-cli.js`.
  - A missing executable, a missing Node or a batch-file executable is reported with its reason. Kumiko never installs or substitutes an adapter.
  - Profiles live in the local store (schema v5).
- **ACP adapter in the host.**
  - Each session runs its own adapter process as a contained unit, kind `agent`. It is recorded in the ledger before spawn, follows the unit cap and the workspace *cleanup unresolved* gate, and is cleaned on close, desktop death, host exit and reconciliation.
  - The host speaks newline-delimited JSON-RPC (ACP protocol version 1) over the adapter's piped stdio.
  - Windows units gain piped stdio inside containment, which does not exist today.
  - The host reads the adapter's output continuously and tolerates unknown update variants.
  - Kumiko never handles provider credentials. A missing Claude Code login is reported as a native requirement, with the hint to sign in from a terminal.
- **Normalized session model with qualified capabilities (ADR 0004).**
  - The model covers:
    - user and agent messages, streamed as chunks;
    - thought chunks;
    - tool activity (title, kind, status, locations, text and diff content, bounded);
    - the plan;
    - permission requests;
    - turn state (idle, running, waiting for approval, stopping);
    - the stop result;
    - exit.
  - The adapter name and version from `initialize`, checked against a qualified-versions list kept with the adapter, decide which capabilities are claimed:
    - **Baseline:** prompt, streaming, tool activity, permission requests and cancel.
    - **Qualified only:** load and resume.
  - An unqualified version runs the baseline and shows the rest as unavailable.
- **Chat panes.**
  - The + launcher gains **Claude Code**, which opens a chat pane in a new tab, bound to the selected workspace, with the default runtime profile.
  - The pane shows:
    - the streamed reply;
    - tool activity cards;
    - the plan;
    - permission requests with the adapter's own options, answered only by an explicit choice;
    - a status of *Running*, *Idle*, *Waiting for approval*, *Stopping*, *Failed* or *Ended*.
  - Prompts are text only. Send is disabled while a turn runs.
- **Stop.** Stop sends ACP `session/cancel` and reports the real outcome:
  - *Stopped*;
  - *Finished before Stop* when the turn ended on its own;
  - *Stop not confirmed* past the deadline, in which case the turn stays shown as running.

  Stop never kills the process.
- **Close.** Closing a running agent asks "Are you sure you want to stop the running agent?" (direction wording). Cancel keeps it running. Confirm cancels the turn, answers pending permissions as cancelled and terminates the adapter's process tree. Closing an idle agent asks nothing. Either way the saved session record and the runtime's native history remain. A tab close names running agents and live terminals in one confirmation. Moving a pane never warns.
- **Saved session records and immutable targets.**
  - The host stores one record per session (schema v5) holding:
    - the Kumiko session id;
    - the runtime kind, adapter and version;
    - the native session id;
    - role `coding`;
    - the execution target: host, absolute workspace path and its directory identity.
  - The target is fixed at creation. Sidebar selection, tab moves and focus never change it.
  - Transcripts stay in Claude Code's own history and are never copied into Kumiko's store.
- **Honest reopen.**
  - Restored agent panes show *saved, not running* with **Continue**. Nothing launches until the user asks.
  - Continue starts the adapter with the original target and native session id. Through `session/load` it replays the saved conversation for display, never re-running a prompt or tool. Through `session/resume` it continues with "earlier messages not shown".
  - It shows *resume unavailable* with the reason when:
    - the version is unqualified;
    - the capability is not advertised;
    - the history is missing;
    - the target is missing or changed;
    - the workspace has *cleanup unresolved*.
  - Host loss marks open sessions *stopped or unknown*, never running.
- **Protocol:** a new `agent` capability.
  - Control methods are capability-gated and cover runtime profiles and agent start, continue, attach, prompt, stop, permission reply, close and release, plus their notifications.
  - Transcript events travel on one host-allocated, credit-controlled data channel per session.
  - Turn state, permission requests and stop results are control messages, so they are never queued behind transcript data.
  - This is an additive ADR 0002 change with no version bump.
- **Qualification.**
  - A scripted fake ACP agent (a test fixture) drives the automated tests on all three OSes in CI.
  - A qualification suite runs against the real adapter on the user's machine for each OS. It covers launch, streaming, tool activity, a permission request, Stop, close, and load and resume. Results are recorded per adapter version in `docs/qualification/claude-agent-acp.md`, a stable path that later changes extend. CI checks that the qualified-versions list matches it.
  - **Assumption (precedent of 2026-10-29, `host-terminals`):** the change may finish on Windows user results, with Linux and macOS items recorded `unproven`, never counted as passed, and required before M1 closes.
- **New ADR (written during apply):** ADR 0012, agent session transport and qualification. It covers one adapter process per session, transcript events on a per-session data channel with state and requests on control, runtime profiles, and the qualified-versions list with its baseline.

## Capabilities

### New Capabilities
- `agent-sessions`: Claude Code chat sessions through the ACP adapter.
  - It covers:
    - the normalized session model;
    - chat streaming and tool activity;
    - permission requests;
    - turn status;
    - Stop with its actual result;
    - close confirmation for running agents;
    - agent processes as contained units;
    - saved session records with immutable targets;
    - reopen as *saved, not running*, then Continue through qualified load or resume, or *resume unavailable*;
    - host loss shown as *stopped or unknown*;
    - native authentication reported, never managed;
    - transcripts kept in the runtime's own history.
  - It carries from `document-kumiko-direction` `agent-sessions`:
    - "Existing runtimes share a capability-aware interface" (Claude Code part);
    - "Private coding conversations remain local" (storage boundary; no team server exists yet);
    - "Agent tab close depends on running work" (tab close; whole-app exit is change 6);
    - "Live session ownership is independent of layout";
    - "Sessions history resumes the original conversation" (resume part; the Sessions surface is M2);
    - "Stop interrupts current work without deleting the session";
    - "Recovery preserves saved history without replay guarantees" (host restart part; crash-recovery presentation is change 6, backup restore is M6).
  - It also carries `agent-tool-access` "AI provider accounts remain native" and "Native agent setup is preserved", and decisions D4, D5, D6, D7, D14, D20, D28, D29, D37 and D46.
- `agent-runtimes`: runtime profiles for the ACP adapter and how runtime capabilities are claimed.
  - Runtime profiles cover detection of an installed adapter, user argv profiles, the default profile, validation, and missing-executable and batch-file failures.
  - Capability claims follow the qualified-versions list and the safe baseline (ADR 0004 decision 2).
  - Carries D6 and D20.

### Modified Capabilities
- `desktop-host-protocol`: adds per-session agent event channels (host-allocated, one host-to-desktop data channel under credit), agent and runtime-profile control messages under a new `agent` capability, and control responsiveness for Stop and permission replies under saturated output. Existing requirements are unchanged.
- `workbench-layout`: adds the **Claude Code** launcher entry, which needs a workspace, and chat panes saved with the layout. The existing close requirement already covers every view that warns, so it is unchanged; the agent close rules live in `agent-sessions`.

## Impact

- **Code:**
  - `process_containment`: piped stdio for Windows units (three pipes, inherited through the handle list, under job containment). The POSIX unit already has pipes.
  - `host_protocol`: the `agent` capability, the runtime-profile and agent messages, the normalized event types and their bounds.
  - `domain`: the runtime profile model and validation (pure).
  - `host`:
    - store migration v5 (`runtime_profile`, `agent_session`, the default-runtime setting);
    - adapter detection;
    - the ACP client (newline-delimited JSON-RPC, tolerant of unknown variants);
    - the agent service (process per session, normalization, event channel relay with backpressure, Stop, permissions, close, load and resume);
    - the qualified-versions list;
    - a scripted ACP fixture for tests.
  - `desktop`:
    - the chat view kind and its controller;
    - the Claude Code launcher entry;
    - the runtime profile editor;
    - the permission request UI;
    - Stop and close;
    - the *saved, not running* and *resume unavailable* states;
    - *stopped or unknown* on host loss.
- **Dependencies:** none added to the app. Users need Node ≥ 22 and the adapter installed (or reachable through `npx`) to use Claude Code. CI uses only the Dart fixture.
- **Migration:** store v5 is additive. Builds before v5 refuse the upgraded store, as they do today for a newer store.
- **Planning files during apply:**
  - ADR 0012 and its index row;
  - `openspec/architecture.md`: the agent session events row with real numbers, the session record and runtime profile state rows, and the agent unit in the component table;
  - the qualification results in `docs/qualification/claude-agent-acp.md`.
- **Not in this change:**
  - Kumiko tools and the `mcp-bridge`: sessions start with no Kumiko MCP server (change 5);
  - whole-app exit decisions, unsent drafts and crash-recovery presentation (change 6);
  - Codex and OMP (M2);
  - the Sessions history surface (M2);
  - permission-mode, model or effort pickers and slash-command discovery (M2 "Supported native controls are surfaced");
  - image or file attachments and Ask agent drafts;
  - the read-only chat role (M2);
  - agent tool shells shown as terminals.
