# Kumiko Roadmap

Strategy: [openspec/strategy.md](strategy.md) · Architecture: [openspec/architecture.md](architecture.md)

Status is derived: a change is done when it is archived on main, and a milestone is done when its changes are done and its exit criteria pass. Each milestone is a slice of the agreed product scope ([`document-kumiko-direction`](changes/document-kumiko-direction/proposal.md)). Milestones sequence that scope; they do not reduce it.

## Now: M1 - Local development loop (walking skeleton)

**Outcome:** On Windows, Linux and macOS, a user launches Kumiko with no account, server or network backend. They:
- open a terminal in Personal running their chosen shell;
- open a local checkout;
- work there with Claude Code through a structured ACP chat session that can call a Kumiko tool;
- quit and reopen to get the layout and saved conversation back, honestly labelled, with no process claimed to have survived.

The milestone proves the riskiest assumptions first: the child host and its process cleanup, the multiplexed protocol, PTYs on three OSes, ACP adapter behaviour and MCP tool delivery.

**Exit criteria:**
- CI builds the desktop app with its bundled host for Windows, Linux and macOS from main. The dependency audit finds no analytics, crash-report or remote-logging package. (agent)
- First launch on each OS opens Personal with no account, project, server or network prompt, and a terminal can be opened at once. (user, per OS)
- Terminals run the user's shell from an argv profile: PowerShell and Nushell on Windows, bash on Linux, fish or zsh on macOS. (user, per OS)
- The adopted terminal engine passes the daily-driver bar on each OS. Results are recorded per OS in the `host-terminals` change, and an engine that fails any item is not adopted (ADR 0006). (user for interactive items, agent for scripted ones, per OS)
  - Fullscreen TUIs: vim, lazygit, htop or btop, and tmux running inside the terminal, all with correct rendering, keyboard input including modifiers, function and navigation keys, and mouse reporting.
  - Colour: 256 colours and 24-bit true colour render correctly.
  - Input: bracketed paste works, and CJK IME composition commits the right text.
  - Unicode: wide characters and emoji take correct widths.
  - Throughput: `cat` of a 100 MB file completes without the UI freezing, and Ctrl+C interrupts it promptly.
  - Resize: a rapid resize storm leaves the shell and the running TUI consistent.
  - Conformance: a vttest subset (cursor movement, screen features, character sets) passes, with the chosen subset named in the change.
  - Selection, copy and scrollback search work.
- With one terminal saturating output and another terminal's consumer stalled, Stop, permission replies, resize and close still complete, and other channels keep flowing (ADR 0002). (agent)
- In an opened checkout, a Claude Code ACP session streams a reply, shows tool activity, raises a permission request the user answers, and can be stopped mid-turn. The Stop result reported is the actual one. (user, per OS)
- An existing agent session keeps its original checkout as its target after the user focuses another workspace or project (ADR 0004). (agent: automated test; user: observed once)
- The Claude Code session calls a read-only Kumiko tool, or the UI reports Kumiko tools unavailable for that adapter version with the observed failure. A call with a wrong or missing session secret is rejected (ADR 0005). (agent)
- Closing a working agent asks for confirmation and closing an idle one does not. Closing a terminal with running processes warns about process loss. Cancel keeps everything running. (user)
- Quit and reopen restores the tab and split layout. Agent tabs show *saved, not running* and continue through the qualified resume path, or show *resume unavailable*. Terminals restore arrangement only, with no programs re-run. (user, per OS; agent for the store round-trip)
- Killing the desktop leaves no host, agent or shell process. Killing the host abruptly ends with every unit cleaned, or its workspace *cleanup unresolved* and refusing new launches. Two simultaneous launches yield one host (ADR 0001). (agent, per OS)

**Changes** (in order; each about one PR):
1. `scaffold-desktop-and-host` - Dart workspace (`domain`, `host_protocol`, `host`, `desktop`). Desktop launches the child host and runs the `hello` handshake. Framing with fair scheduling and credit (ADR 0002). Profile lock and process ledger with reconciliation (ADR 0001). CI builds on three OSes and runs the dependency audit.
2. `local-store-and-workbench-shell` - SQLite binding probe and follow-up ADR. Host-owned store with migrations (ADR 0003). Personal working set, a minimal tab and split workbench, opening a checkout as a workspace, and layout save and restore.
3. `host-terminals` - terminal engine spike against the daily-driver bar and follow-up ADR (ADR 0006). The lead candidate is flutter_alacritty and the fallback is xterm.dart. If both fail the bar, the change escalates to the user with the observed results: fork the widget, or build our own widget on `alacritty_terminal`. Host PTYs (ConPTY and POSIX) from argv shell profiles. Terminal channels, close-loss warnings and layout-only reopen.
4. `claude-acp-chat-session` - ACP adapter and normalized session model with qualified capabilities (ADR 0004). Chat, tool activity, permission requests, Stop, close confirmation, saved session records, resume or a visible *resume unavailable*, and immutable targets. Prerequisite: change 2. It can run in parallel with change 3.
5. `kumiko-tool-delivery` - host tool service, `mcp-bridge` and per-user endpoint, per-session secret and per-call authorization, and one read-only tool. Connected status only after a successful call (ADR 0005). Prerequisite: change 4.
6. `app-exit-and-reopen` - whole-app exit with individual and bulk decisions for working agents and terminals. Unsent drafts kept locally per conversation. Reopen and crash-recovery presentation, including *cleanup unresolved*. The full M1 exit-criteria walk on three OSes. Prerequisites: changes 3 and 5.

## Next: M2 - Daily-driver workbench

Kumiko becomes usable as the primary agent environment. M2 adds:
- Codex via ACP and OMP via native RPC behind the same session model;
- the right-side Git panel with workspace-aware SCM (D5) and the Sessions history surface;
- the files tree and lightweight source-first editor with explicit Save, clean refresh and recovery drafts (D10);
- quick-open, Open in, and local diff review feeding revision requests into chat (D16-D19);
- the personal read-only chat agent (D54) with host-enforced read-only operation checks.

Main risk retired: one session model across two runtime families, and read-only role enforcement that holds against runtime built-ins, not just Kumiko's buttons.

## Later

- M3 - Local planning and documents: solo projects, configurable tasks with arbitrary-depth subtasks, views, milestones and roadmap, and app-owned Markdown documents in the local store, using shared `domain` rules (D31-D36, D11, D49-D52).
- M4 - Team server and collaboration: backend ADR (Serverpod candidate), deployment, identity and onboarding, invitations and access, shared projects, documents and human chat, and capability negotiation in both upgrade orders (D2, D13, D26, D27, D41-D45).
- M5 - Integrations and attention: GitHub/GHES and Jira connections, linked external work and per-destination publication, the Needs attention inbox and notifications, and usage statistics (D12, D17, D21, D37).
- M6 - Distribution and operations: telemetry-free release builds, consented updates, ZIP backups and replacement restore, bounded diagnostics and local export, and project archive and delete (D22-D25, D46-D48, D53, D55).

## Done
