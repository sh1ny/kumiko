# Proposal

## Why

M2, Daily-driver workbench (Windows), needs Codex sessions with streaming, tools, explicit approvals, Stop and truthful saved-conversation recovery. The owner chose native Codex App Server over stdio on 2026-11-10 so future subagent inspection can use native child-thread identities and events without an ACP translation dependency.

## What Changes

- Support installed Codex 0.166.0 or newer without pinning or an exact-version allowlist. Add a focused Dart App Server client behind Kumiko's shared session contract; continue using the installed Codex runtime, native authentication and history.
- Expose Codex in the workspace launcher and runtime profile editor. Preserve Claude ACP behavior and existing saved records.
- Support native thread creation, prompt turns, approvals/questions, Stop, explicit steering, history restoration and per-run Kumiko MCP delivery.
- Preserve subagent identity, parentage and attributed activity in the host/desktop contract. The full child-conversation browser and direct child controls remain future work; this change must not flatten child activity into the parent's reply or approve it invisibly.
- Replace the planned `codex-acp-session` roadmap entry with `codex-app-server-session`. This explicitly departs from parked direction D6 and the Codex ACP wording in D7 and ADR 0004; Claude stays ACP, OMP stays native RPC.
- During apply, record ADR 0015 and update the architecture, without editing accepted ADR files. Generalize only the ACP-specific contracts needed by this integration.

## Capabilities

### New Capabilities

- `codex-sessions`: Native Codex session behavior, steering, runtime-specific questions, child attribution and minimum-version compatibility and version-specific evidence.

### Modified Capabilities

- `agent-runtimes`: Runtime-kind-specific launch, detection, compatible profile selection and evidence-based native capability claims.
- `agent-sessions`: Codex launcher and shared turn/recovery behavior while preserving every existing Claude scenario.
- `agent-tool-access`: Native Codex per-run MCP delivery with unchanged host authorization and secret lifetime.
- `app-exit`: Include known active delegated work in whole-app quit confirmation.
- `desktop-host-protocol`: Additive Codex controls and attributed child events with capability negotiation.

## Impact

Touches `packages/host/lib/src/agent/`, the domain runtime profile, host-protocol DTO/event codecs, desktop agent launcher/controller/chat/profile editor, and qualification tooling/tests. Existing process containment, workspace admission, draft worker and tool bridge remain authoritative. No Node/Python SDK sidecar, ACP Codex wrapper, runtime installer, provider sign-in manager or transcript store is introduced.

Sources: parked `document-kumiko-direction` agent-sessions and agent-tool-access requirements; decisions D4-D7, D14-D15, D20, D28-D30 and D37. Original ACP-specific intent is amended explicitly here, not silently rewritten in the parked backlog. No requirement is added for the later personal read-only role or full subagent UI.

This request produces planning only. Real provider requests and qualification require the existing explicit approval process; implementation completeness cannot be substituted for real Windows evidence.

## Release Notes

Native Codex sessions and more accurate terminal input qualification.

### Added

- Codex startup and continuation refuse missing peer capabilities before launching a process.

- Codex launcher and runtime profile editing preserve the selected runtime kind, including compatible profile selection for Continue without changing the global default.
- Native approvals show their complete bounded request details and offered choices; structured questions and explicit Steer preserve run identity and drafts.

- Saved Codex conversations restore bounded native history without replaying prompts; unsafe or unavailable recovery retains the saved identity with its reason.
- Root-scoped Kumiko tools use private MCP entry configuration, fresh grants and native-thread binding; configuration conflicts keep tools unavailable.

### Fixed

- Terminal input qualification measures host-owned retained bytes against the existing 576 KiB limit, separately from OS buffering, while preserving byte-order checks.
