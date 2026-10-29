# Proposal

## Why

After `scaffold-desktop-and-host`, Kumiko starts a host and shows its status, but there is no workbench: nowhere to open a checkout, no tabs or splits, and nothing a later change can put a terminal or chat into. This is change 2 of **M1 - Local development loop (walking skeleton)**. It builds the workbench frame that `host-terminals` and `claude-acp-chat-session` fill. It also stores layout through the host, so later tab kinds get save and restore for free.

It advances these M1 exit criteria:
- **First launch opens Personal** (user, per OS): no account, project, server or network prompt. This change delivers the Personal working set and the empty workbench; "a terminal can be opened at once" lands with `host-terminals`.
- **Quit and reopen restores the tab and split layout** (agent for the store round-trip, user per OS): this change delivers layout save and restore for the tab kinds that exist now. Agent and terminal tab states (*saved, not running*, layout-only) build on it in changes 3, 4 and 6.
- **An existing agent session keeps its original checkout** (ADR 0004): this change makes a tab's workspace binding immutable under focus, navigation and tab moves, with automated tests. The session-level test lands with `claude-acp-chat-session`.

## What Changes

- **Store schema v2** on the change-1 store core (ADR 0003): workspaces and working sets with their layout. The v1 ledger is kept unchanged by the migration.
- **Workspaces.** The user opens a local directory (a checkout, or any directory) as a workspace. The host resolves its canonical path and directory identity. Opening the same directory again, by any path, focuses the existing workspace. Saved workspaces are checked again on every start: a missing one shows as *unavailable* and keeps its tabs. A workspace under *cleanup unresolved* shows that state. A workspace with no open tabs can be removed from Personal.
- **Personal working set.** First launch opens Personal directly, with no prompt. Personal holds the opened workspaces and a tab and split layout. Project working sets come with projects in M3 or later. The schema allows them, but this change creates none.
- **Minimal workbench.** A left sidebar with Personal and its workspaces, collapsible. A central area of tab groups in horizontal and vertical splits, with tabs movable between groups. Each group has a labeled, click-opened **+** launcher that opens a view in that group, in the group's workspace context. Opening an item that is already open focuses it. This change ships one view kind, **Workspace overview** (path, identity and availability state). Terminal and chat views join the launcher in changes 3 and 4. There is no right sidebar until M2 gives it tools.
- **Immutable tab bindings.** A tab's workspace is fixed when the tab is created. Focusing another workspace, selecting it in the sidebar, or moving or splitting the tab never changes it (ADR 0004 groundwork).
- **Layout save and restore.** The desktop sends debounced layout snapshots, and saves once more on quit. The host validates and stores them. Reopening restores groups, splits, tabs, the active tab per group, the focused group and the sidebar state. A manually closed tab stays closed. A failed save is shown, never silent. A saved layout that cannot be restored is reported, with an empty Personal layout in its place. A tab of an unknown kind is kept as an *unsupported view* rather than dropped.
- **Protocol:** new capability-gated control methods for loading and saving layout and for opening, listing and removing workspaces (ADR 0002 additive change, no version bump).
- **New ADR (written during apply):** the workbench layout document. It is a desktop-authored, host-validated, versioned snapshot per working set, which later tab kinds extend.

## Capabilities

### New Capabilities
- `workbench-layout`: the Personal working set, tab groups and splits, the per-group launcher, focus-existing, immutable tab workspace bindings, sidebar collapse, and layout save and restore with visible failure. Carries from `document-kumiko-direction` `workbench-layout`: "Personal work does not require a project", "Tab groups and splits remain independent", "Each tab group provides a labeled click launcher", "Opening an existing item focuses it by default", "Direct workspace navigation activates its parent context" (no projects yet, so Personal is the parent), "Sidebars collapse independently without changing work" (left sidebar only) and "App reopening restores the open layout and saved session identities" (layout part only). Decisions D7, D28, D30, D41.
- `execution-workspaces`: opening a local directory as a workspace, identity-based de-duplication, failed opens, availability on restore, the cleanup-unresolved state on the workspace, and removal. Carries "Work begins in the selected checkout" (the selected-checkout part) from `document-kumiko-direction` `execution-workspaces`, with D4 and D30 (projectless directories).

### Modified Capabilities

None. The schema-v2 migration follows the existing `local-store` requirements unchanged.

## Impact

- **Code:**
  - `domain`: layout model, operations, bounds and codec (pure).
  - `host_protocol`: new message types and the capability.
  - `host`: migration v2, workspace and layout services, and off-isolate directory resolution.
  - `desktop`: the workbench UI, its controller and the directory picker.
- **Dependencies:** `file_selector` (Flutter first-party) for the native directory picker, which must pass the dependency audit.
- **Planning files during apply:** ADR 0009 (layout document), and `openspec/architecture.md` (index row, new resource-bound rows, state row detail).
- **Not in this change:**
  - terminals, agent sessions and their tab states;
  - close confirmations for running processes, whole-app exit decisions and drafts (changes 3-6);
  - projects and project working sets (M3);
  - the right sidebar and its tools (M2);
  - multiple windows, and restoring window size or position;
  - SCM identity of a checkout (M2, D5);
  - creating worktrees.
