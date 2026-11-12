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

The owner-approved attempt-6 follow-up plans complete object-valued native decision details in the existing bounded preview, retaining exact responses and explicit answers. It also plans an explicit manifest-selected changed-artifact audit mode, covering caches and changed regular files under otherwise unclassified native-home directories without silently widening legacy scans. Protected auth/config entries remain unread and incomplete when changed. Existing byte/metadata limits and all six incomplete attempt records remain authoritative. This amendment and its external review authorize no implementation or real native-home inspection/walk.

After attempts 7 and 8 showed that the owner's normal native home exceeds the inherited 4096-entry inventory bound and contains links, the owner chose to keep qualifying against that home (2026-11-12). A separate changed-artifacts-v2 selection admits up to 65,536 entries and accounts for unchanged native-home links as no-follow metadata. It discloses the unchanged-link and concurrent-writer limits, and v1 keeps its recorded meaning.

Attempt 9 then stopped only on two Unix-domain sockets in that home. A changed-artifacts-v3 selection records Windows AF_UNIX sockets as metadata without opening them; v2 keeps its recorded meaning.

Attempt 10 then passed launch, streaming and tool activity, but stayed incomplete on 5 removed entries and an unmatched command approval. A changed-artifacts-v4 selection counts removed non-protected entries instead of failing on them, and the helper's approval refusal names which match check failed, without content.

Attempt 12 (Codex 0.166.0) completed the normal-home audit with 0 canary matches; its approval failed only the command check. A study of Codex 0.165 source suggests the approval command is a shell-quoted join of Codex's PowerShell wrapper argv. The helper also accepts exactly that wrapper around the approved command, with the shell taken from a registry-trusted PowerShell install, and nothing looser; attempt 13's diagnostic records whether that explanation holds.

## Release Notes

Native Codex sessions and more accurate terminal input qualification.

### Added

- Codex startup and continuation refuse missing peer capabilities before launching a process.
- Codex launcher and runtime profile editing preserve the selected runtime kind, including compatible profile selection for Continue without changing the global default.
- Native approvals show their complete bounded request details and offered choices; structured questions and explicit Steer preserve run identity and drafts.
- Saved Codex conversations restore bounded native history without replaying prompts; unsafe or unavailable recovery retains the saved identity with its reason.
- Root-scoped Kumiko tools use private MCP entry configuration, fresh grants and native-thread binding; configuration conflicts keep tools unavailable.
- Delegated Codex work retains child identity, participates in Stop and close/quit warnings, and reports uncertain outcomes without claiming completion.

### Fixed

- Terminal input qualification measures host-owned retained bytes against the existing 576 KiB limit, separately from OS buffering, while preserving byte-order checks.
- Host diagnostics and clipped native output redact known run secrets, including boundary fragments, while preserving normal streaming order.
- Native startup failures retain bounded redacted stderr and exit details; qualification failures explicitly record an incomplete audit when no session is available.
- Qualification manifests declare exact startup arguments and retain native approval configuration.
- Qualification audits support an explicitly approved larger preset with chunked scanning and conservative byte accounting; existing limits remain the default.
- Private Kumiko MCP configuration preserves unrelated native entries during start and Continue.
- Qualification timeouts retain earlier observed streaming and tool activity without promoting incomplete privacy audits.
- Ordinary command approvals with omitted decision lists offer native one-shot choices; unavailable decision lists are declined visibly without ending the run.
- Object-valued native command decisions use bounded indexed labels and complete preview details, preserving exact responses and refusing any loss of displayed scope.
- Qualification manifests can explicitly select bounded changed-artifact coverage; legacy selection remains the default and protected or unaccounted changes remain incomplete.
- A changed-artifacts-v2 qualification selection covers larger native homes with unchanged links, with explicit detector limits.
- A changed-artifacts-v3 qualification selection also accounts for Unix-domain sockets in the native home without opening them.
- A changed-artifacts-v4 qualification selection counts removed non-protected native-home entries instead of failing on them.
