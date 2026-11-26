# Proposal

## Why

Kumiko can start and stop an OMP chat, but it cannot continue that chat or show the child work OMP reports. M2 change 4 covers same-session Continue, history, and close and quit decisions. Contract tests use scripted RPC peers. The owner will check the installed Windows runtime in `omp-rpc-qualification` before M2 closes.

## What Changes

- Keep the native locator for an OMP chat when OMP supplies it. Continue only the recorded conversation in its original workspace, on explicit request. Do not guess a locator for old records, substitute a new chat, replay a prompt or rerun a tool.
- Restore bounded root history when OMP can return it. If the same conversation can continue without its earlier messages, say what could not be shown. If OMP cannot reopen the exact conversation, keep the saved record and show why Continue failed.
- Show live OMP child activity separately from the parent. Open a read-only subagent chat as a workbench pane. Show that child's messages and tool activity, including history OMP can return, and name any history gaps. Only the parent has Continue. Child panes do not launch processes, send messages, steer work or present approval controls.
- Keep the shared Stop, close and quit controls. Use native evidence to tell when the root or known child work has stopped. A confirmed close or ordinary quit gives OMP a bounded chance to write native history before containment cleanup. Do not call a failed or forced shutdown a save.
- Keep OMP's own settings, provider setup and history. No installed-runtime run, qualification record, right-side Sessions browser, read-only agent role, or changes to Claude and Codex behavior in this PR.

## Decision Making

DECISION_MAKING: autonomous

Source: setting. The dispatch reserves scope changes and build approval for the owner.

### S1: Continue only the recorded conversation

- Choice: Continue the exact saved OMP conversation and read the history OMP returns. Keep old records with no native locator and show why they cannot continue.
- Rejected: Search for old records by title, prefix or most recent session, or substitute another conversation when an exact reopen fails.
- Reversal cost: Medium. An exact legacy lookup could be added if OMP exposes one that respects the original target.
- Important: yes. This sets the user-visible recovery contract.
- Chosen by: user, relayed by the coordinator from Ormy item 92, event `e2665`.

### S2: Open a read-only subagent chat from the parent

- Choice: Show attributed activity and let users open each tracked child in a read-only workbench pane, with native history when available. Keep Stop on the root and use it for known child work when OMP can confirm the result.
- Rejected: Show only a count, put child output in the parent transcript, or give a child its own runtime controls or Continue.
- Reversal cost: Medium. A child with independent launch or recovery would bind a new identity and ownership contract.
- Important: yes. This sets the boundary between a child view and a session.
- Chosen by: user, relayed by the coordinator from Ormy item 92, event `e2665`: "Add a subagent chat view".

### S3: Report what close and quit establish

- Choice: Warn about active or uncertain work. Give OMP its native shutdown path before containment cleanup and report when saving could not be confirmed.
- Rejected: Treat a yielded reply as proof of quiescence, or treat unit cleanup as proof of history persistence.
- Reversal cost: Medium. Close and quit rely on the distinction.
- Important: yes. It affects the user's choice to stop work and what they can expect on reopen.
- Chosen by: user, relayed by the coordinator from Ormy item 92, event `e2665`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `omp-sessions`: exact native Continue, bounded root and child history, attributed live subagent activity, and OMP-specific Stop and shutdown outcomes.
- `agent-sessions`: OMP joins the shared saved-session and delegated-work controls. Its subagent panes are read-only and depend on the parent session.
- `agent-runtimes`: OMP reports Continue, history and child support from the native contract and observed outcomes. The minimum version admission rule remains in place.
- `desktop-host-protocol`: retain run and child attribution for child history and live events. Gate any new reads and keep native locators out of the desktop protocol.
- `app-exit`: include known or uncertain OMP work in the quit decision. Give its native shutdown the ordinary-quit path and distinguish an unconfirmed save from unresolved process cleanup.

## Impact

The host adds OMP recovery metadata, history reads, child tracking and native shutdown handling. The desktop uses the existing chat presentation and layout model for a read-only child pane. No new runtime dependency, listener or qualification gate.

Sources: M2 change 4 in `openspec/roadmap.md`; the archived `omp-rpc-transport` and `omp-rpc-permissions-and-tools` changes; ADRs 0004, 0011, 0014, 0015, 0016 and 0018; parked direction D6, D7 and D29. The right-side Sessions browser stays in M2 change 6. The parked direction stays unchanged.

Branch gate: Specwright 0.39.1 interface 3 reported a clean `feat/omp-rpc-history-and-children` at `bedc763`, equal to local and freshly fetched remote `main`. Neither main ref had an archive with this name. The dispatch authorizes reusing this branch.
