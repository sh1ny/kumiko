# Kumiko Roadmap

Strategy: [openspec/strategy.md](strategy.md) · Architecture: [openspec/architecture.md](architecture.md)

Status is derived: a change is done when it is archived on main, and a milestone closes when its changes are done and its applicable exit criteria pass, with any explicit user-approved deferrals recorded at close. Each milestone is a slice of the agreed product scope ([`document-kumiko-direction`](changes/document-kumiko-direction/proposal.md)). Milestones sequence that scope; they do not reduce it.

## Now: M2 - Daily-driver workbench (Windows)

**Outcome:** The author can use Kumiko on Windows as the primary environment for agent work, source control, light editing and local review. Linux/macOS ports and their qualification follow later; existing cross-platform CI remains useful evidence, not a claim of supported daily use.

**Exit criteria:**
- Codex through native App Server over stdio and OMP through native RPC stream replies, show tool activity, handle permissions and Stop, retain immutable targets, and truthfully expose save/resume support behind the shared session model. (agent: contract tests; user: real runtimes on Windows)
- The Git panel follows the selected workspace, shows changes and diffs, and performs explicitly requested SCM actions with visible failures. Sessions history opens the correct saved conversation. (agent; user: Windows walk)
- Files open in the lightweight editor; Save is explicit, clean files refresh, dirty files are protected from external changes, and recovery drafts survive reopen. (agent; user: Windows walk)
- Quick-open, Open in, and local diff review target the correct checkout; a review revision request reaches the intended chat. (agent; user: Windows walk)
- The personal read-only chat agent cannot mutate through runtime built-ins or Kumiko tools; unsupported enforcement is reported as unavailable. (agent: adversarial boundary tests; user: Windows walk)
- Main CI builds the Windows desktop with bundled host, the dependency audit passes, and the author completes an ordinary development task in Kumiko. (agent for CI/audit; user for daily use)

**Changes** (in order; each about one PR):
1. `codex-app-server-session` - Add and qualify native Codex App Server over stdio against the shared session, permission, Stop, tool-delivery and saved-session contracts. Preserve Claude behaviour and child-thread attribution for future subagent viewing. Owner-approved replacement of the ACP plan, 2026-11-10.
2. `omp-rpc-session` - Add and qualify OMP native RPC behind those contracts, with explicit capability differences. Prerequisite: change 1's shared contract checks.
3. `workspace-git-and-session-history` - Right-side workspace-aware Git/SCM panel (D5), local diffs and Sessions history, preserving immutable session targets.
4. `files-and-source-editor` - Files tree and source-first editor with explicit Save, external-change handling and local recovery drafts (D10).
5. `quick-open-and-review-to-chat` - Quick-open, Open in, and local diff review feeding revision requests to the intended conversation (D16-D19). Prerequisites: changes 3 and 4.
6. `personal-read-only-agent` - Personal chat role with host-enforced operation checks, including runtime built-ins (D54); qualify enforcement or expose the role as unavailable for each adapter. Prerequisites: changes 1 and 2.

## Next: M3 - Local planning and documents

Add solo projects, configurable tasks with arbitrary-depth subtasks, views, milestones and roadmap, and app-owned Markdown documents in the local store. Shared domain rules keep those records independent of the desktop and prepare for later collaboration (D31-D36, D11, D49-D52). Windows is the qualification target; the milestone must preserve the private local development boundary.

## Later

- Linux/macOS ports and qualification - Finish platform-specific integration and the full interactive terminal, shell, real-adapter, tools, lifecycle and recovery walks before claiming support. Retain existing CI coverage and unverified observations; schedule this milestone when port work begins.
- M4 - Team server and collaboration: backend ADR (Serverpod candidate), deployment, identity and onboarding, invitations and access, shared projects, documents and human chat, and capability negotiation in both upgrade orders (D2, D13, D26, D27, D41-D45).
- M5 - Integrations and attention: GitHub/GHES and Jira connections, linked external work and per-destination publication, the Needs attention inbox and notifications, and usage statistics (D12, D17, D21, D37).
- M6 - Distribution and operations: telemetry-free release builds, consented updates, ZIP backups and replacement restore, bounded diagnostics and local export, and project archive and delete (D22-D25, D46-D48, D53, D55).

## Tracked follow-up

- [M1-F1: Windows terminal close latency](../docs/qualification/m1-close.md#m1-f1-windows-terminal-close-latency) - User-approved deferral at M1 close; investigate the recorded 359.3 ms acknowledgement against the unchanged 250 ms bound. This remains open and is not reported as passing.

## Done

- **M1 - Local development loop (walking skeleton), 2026-11-08.** Closed for Windows by explicit user decision; all six changes are archived on main. Learned: the local loop is usable on Windows, while passing automation alone does not qualify other platforms or explain intermittent control latency. Linux/macOS qualification moves to Later; M1-F1 is explicitly deferred, not passed. [Close evidence and decisions](../docs/qualification/m1-close.md).
