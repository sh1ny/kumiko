# Proposal

## Why

This change finishes M1 (*Local development loop*). It is the last of M1's six changes. It serves these exit criteria:
- closing a working agent asks and an idle one does not;
- closing a terminal with running processes warns;
- Cancel keeps everything running;
- quit and reopen restore the layout, with agents *Saved, not running* and terminals layout-only;
- killing the desktop or host leaves no process, or *cleanup unresolved*.

It then runs the full M1 exit-criteria walk.

Today quitting Kumiko never asks. `onExitRequested` always answers `exit` (`packages/desktop/lib/main.dart:105-113`), so a running agent turn or a vim session is ended silently. Unsent chat text exists only in memory (`agent_controller.dart:38`) and is lost when a pane closes or the app quits. A terminal warns whenever its shell is alive (`terminal_controller.dart:551-555`). Taken over to whole-app exit, that rule would prompt on almost every quit, which breaks D7's rule that an idle, saved working set closes without unnecessary prompts. Nothing tells the user when the previous session ended by a crash: `host_instance.closed_cleanly` is written but never read, and a killed desktop with settled units is still recorded as clean (`host.dart:505`).

## What Changes

**Whole-app exit.** A window close or Quit that can be cancelled now collects the affected work: agents running a turn, and terminals running a program besides their shell.
- With none, Kumiko flushes and quits without asking.
- Otherwise one exit dialog lists each item, and each has its own **Stop**. The dialog also offers **Stop processes and close** for all of them, and **Cancel**.
- Stops already done are never rolled back by Cancel. The app quits once nothing unresolved is left.
- Exit preserves the open layout: it never marks panes closed.
- An exit the OS does not allow to be cancelled skips the dialog. The host still ends every process.

**Busy terminals.** The host reports whether a terminal's contained unit holds a live process other than its shell, with up to three program names. Pane close, tab close and app exit all use this one rule.
- **Changed behaviour:** a terminal idle at its prompt now closes without a warning.
- A terminal whose activity cannot be read in time warns as *may be running programs*.

**Unsent drafts.** The composer text of each saved agent session is stored by the host in the local store:
- saved while typing (bounded), on pane close and on quit;
- restored with the pane on reopen;
- removed before a sent prompt reaches the agent, or when the composer is cleared, so the text cannot be recovered from Kumiko's files.

A draft is never moved to another session. **Changed behaviour:** *New session* after *resume unavailable* now starts with an empty composer, and the old draft stays with its old record.

**Previous-exit notice.** The desktop tells the host when a close is a quit. On the next launch, a session that did not end through Quit (desktop killed, host crashed) shows *Kumiko did not close normally last time*. The notice also gives the cleanup outcome: all processes cleaned, or the *cleanup unresolved* workspaces with *Show cleanup list*.

**Protocol (additive).**
- `app/quit` and `app/previousExit` under a new `lifecycle` capability;
- `terminal/activity` under `terminal`;
- `agent/draftSave`, `agent/draftLoad`, `agent/draftReset` and the `agent/draftStoreReady` notification under `agent`; `agent/prompt` gains an optional `draftRevision`.

**Storage.**
- Store v6 adds `host_instance.exit_kind`.
- Drafts live in a separate host-owned `drafts.sqlite` (draft schema v1). It uses a rollback journal (no WAL) with secure deletion and `synchronous=EXTRA`, so a committed removal leaves no copy of the text in any file, even after a power loss. A worker isolate owns it, so a stalled draft store never delays control or cleanup. The main store keeps WAL (ADR 0008).

**M1 walk.** A recorded walk of every M1 exit criterion:
- Windows user items and all agent items run in this change.
- Linux and macOS user items are recorded *unverified* (user decision, 2026-11-02). M1 cannot close until they pass.
- A kill-desktop test now covers a real shell and a fake agent adapter, not only test units.

## Capabilities

### New Capabilities

- `app-exit`: what quitting the whole app does to running agents and terminals. It covers the affected-item list, per-item and bulk decisions, Cancel, flushing before the quit, an exit that cannot be cancelled, and that the layout is preserved. Sources: direction "App exit resolves affected work per item", "Bulk exit states process and file-discard consequences" (file parts deferred to the M2 editor), D7.

### Modified Capabilities

- `terminal-sessions`:
  - "Closing live terminals warns about process loss" now warns only for a terminal running a program besides its shell, or whose activity is unknown, and names those programs.
  - A new requirement defines that busy rule and its bounds.
- `workbench-layout`: "Closing a pane or tab checks for live work" has scenarios that assume an idle live shell warns. They are restated for the busy rule.
- `agent-sessions`:
  - New requirements on unsent drafts. Sources: direction "Unsent conversation drafts remain local and scoped", D7.
  - "Each session keeps a saved record; transcripts stay in the runtime" gains the draft exception, and the rule that a sent or cleared draft cannot be recovered.
- `execution-host`: a new requirement that a previous exit other than Quit is shown at the next launch with its cleanup outcome. Source: direction "Recovery preserves saved history without replay guarantees" (crash-recovery presentation part).
- `desktop-host-protocol`: a new requirement that the lifecycle, terminal-activity and draft methods are capability-gated and bounded.

## Impact

- **Desktop:**
  - `main.dart` (exit callback);
  - a new exit coordinator and dialog;
  - `workbench_controller.dart` (layout freeze during exit, collecting affected items);
  - `terminal_controller.dart` (busy query);
  - `agent_controller.dart` and `agent_pane_view.dart` (draft persistence);
  - `profiles_dialog.dart` (warning lists program names);
  - `cleanup_list_view.dart` and `workbench_page.dart` (previous-exit notice).
- **Host:**
  - `store/store.dart` (v6 migration) and a new draft store (`drafts.sqlite`, its own migrations, opened under the profile lock);
  - `ledger.dart` (`exit_kind`);
  - `host.dart` (quit notice, previous exit);
  - terminal service (activity);
  - agent service (drafts).
- **process_containment:**
  - list a unit's processes: the Windows job's process-id list, and the POSIX session through `getsid` over the process table;
  - read process image names.
- **host_protocol:** new methods, the `lifecycle` capability, and message types.
- **Tests:**
  - widget tests (exit dialog, drafts);
  - integration quit and reopen tests, which now expect a cancellable dialog when work is running;
  - host integration tests (activity, drafts, secure deletion, previous exit, real-unit kill-desktop);
  - CI is unchanged in shape.
- **Planning files during apply:**
  - a new ADR 0014 (exit decisions, busy rule, local drafts);
  - `openspec/architecture.md` (index row; state rows for drafts and previous exit; bound rows for drafts, activity and exit);
  - the M1 walk record.
- **Not in this change:**
  - unsaved file edits and their Save/Don't Save/discard decisions (M2 editor);
  - the Sessions history surface where a closed session's draft is reachable again (M2);
  - shared-project drafts (M4);
  - removing a workspace that has bound views;
  - processes that escape their unit (issue #9);
  - automatic host respawn.
