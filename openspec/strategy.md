# Kumiko Strategy

Source record: [`openspec/changes/document-kumiko-direction/`](changes/document-kumiko-direction/proposal.md) (reviewed product direction). This page summarises it; the capability specs and design decisions D1-D55 there remain the detailed reference.

## Purpose

Kumiko is a Flutter desktop environment for agentic software development on Windows, Linux and macOS. It puts existing coding-agent runtimes (Claude Code, Codex, OMP), real terminals, source control and lightweight editing in one workbench. It adds optional shared project planning for teams without turning the user's machine or private work into a server replica.

## Users

- **Solo developer working with coding agents.** Opens Kumiko, works in a local checkout with a real agent and a real terminal immediately, with no account, server or project. Needs a reliable daily-driver workbench and close/reopen behaviour that tells the truth.
- **Small team or company self-hosting coordination.** Shares projects, tasks, milestones, documents and human project chat through an optional self-hosted team server with company sign-in. Needs private development (transcripts, terminals, working copies) to stay on each member's PC.

## Boundaries

- Solo use never requires a Kumiko account, team server, Docker or network backend (D1, D41).
- Shared records require the team server. There is no offline synchronization or hidden mutation queue (D2).
- Private development data never travels through the team server, including to administrators (D29).
- Kumiko does not build an agent runtime, manage AI-provider accounts or billing, or replace native runtime configuration (D6, D14, D20).
- No client telemetry or crash-report collection. Telemetry-free builds omit the capability entirely (D25).
- No process survival after a tab or the app closes in initial scope. Reopen restores layout and supported saved conversations only (D7).
- Freeform human/agent work, not an execution pipeline or autonomous orchestrator (D3).
- Not a full IDE: no debugger, broad LSP framework or extension marketplace.

## Success measures

1. A new user goes from first launch to a working agent session and a real shell in a local checkout on each supported OS, without creating an account, project or server.
2. Close, exit and reopen never report a process as running when it is not, and never lose saved conversations, unsent drafts or unsaved file edits without an explicit user decision.
3. No private development data is reachable through any team-server API, export or administrator surface. This is verified by tests at the boundary, not asserted.
4. The author uses Kumiko as their primary agent workbench for ordinary development.

## Tracks

- **Local development loop:** workbench, terminals, agent sessions, recovery.
- **Agent integration:** runtime adapters, Kumiko tools, read-only chat role, usage statistics.
- **Workspace and source control:** files, editor, Git panel, review.
- **Planning and documents:** projects, tasks, milestones, documents, locally first, then shared.
- **Team and operations:** team server, identity, access, integrations, updates, backups, diagnostics.

## Assumptions

- The first milestone targets the local loop. Planning and team collaboration follow in later milestones without reducing the agreed product scope.
- Claude Code via ACP is the first structured runtime. Codex (ACP) and OMP (native RPC) follow (user decision, 2026-10-28).
- Each milestone's exit criteria are demonstrated on all three desktop platforms (user decision, 2026-10-28).
- Dart is the implementation language for the desktop, the execution host and any future team server. Native code is used only where a platform API demands it (PTY, terminal emulation core).
- Licensing of reference applications and selected packages is reviewed before the first distributed release; it does not block development.
