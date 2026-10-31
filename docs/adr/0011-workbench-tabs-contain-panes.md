# ADR 0011: Workbench tabs contain panes

- **Status:** accepted (2026-10-31)
- **Date:** 2026-10-30
- **Source:** change `host-terminals` design D11 (user decision 2026-10-30); amends ADR 0009 decisions 2 and 3

## Context

ADR 0009 stores a layout whose leaves are tab groups, each with its own tab strip, and whose tabs are views. The user tried the release build with terminals and rejected that model: a split creates an empty group that can never be closed, and a terminal cannot fill the central area without a group's tab strip around it.

User decision (2026-10-30): "Tabs contain panes, not the other way around. I can have a tab with a few panes inside, not a pane with a few tabs inside... I want to have a terminal open on the whole free real estate." Later the same day: "we still have the two bars to the side, but in the middle we have terminals OR whatever other window we open (chat UI over ACP, tasks, editor, ...) and they can all occupy a full tab or that tab can be split in panes and have another thing in the pane." The user chose to make this change inside `host-terminals`, not as a separate change.

User decision (2026-10-30), on stored layouts: "There is no actual used by anyone previous builds so irrelevant, we can be destructive right now."

User decision (2026-10-30), on focus after a close: "you go to the next tab or nowhere if there's no more tabs". With no tabs the central area shows an empty state with one prominent **New terminal** and its shortcut. The shortcut is user-confirmed (2026-10-30): **Ctrl+Shift+T** on Windows and Linux, **Cmd+T** on macOS.

## Decision

1. **Tabs contain panes.** The central area is a strip of tabs. Each tab is a split tree whose leaves are panes. A pane hosts exactly one view for its whole life. There are no empty panes, no paneless tabs, and a split always has two children. Zero tabs is valid.
2. **View kinds are an open set.** Today: terminal, workspace overview and *unsupported view*. Later kinds (chat over ACP, tasks, editor) are examples only. The model, the operations and the codec name no kind; any kind fills a one-pane tab or shares a split tab with any other. The one terminal-specific rule, the default content of a split, belongs to the desktop, which supplies the new pane's view.
3. **Layout format 2.** `{format, tabs: [{id, root, focusedPane}], activeTab, recent, sidebar: {collapsed, selected}}`. A pane is ADR 0009's tab shape `{id, kind, workspace, item, state}` with `type: pane`, and the pane id is the view's id. `activeTab` is null if and only if there are no tabs, otherwise it names a tab; each `focusedPane` is a pane of its own tab; `recent` lists pane ids without duplicates or unknown ids and may omit panes; `sidebar.selected` is the workspace new tabs bind to, or null for Personal. Ids are unique across tabs, splits and panes. Bounds: 128 tabs, 16 panes per tab, 128 panes, 256 KiB document, 4 KiB `state` and `item`, 64 B ids and kinds, ratio 0.1 to 0.9.
4. **Focus follows tree and strip order, not history.** Closing a focused pane focuses its sibling's first pane in tree order. Closing the active tab activates the tab to its right, else to its left, with that tab's own focused pane, else no tab. Closing an inactive tab, or a pane of one, changes no window focus. `recent` serves only workspace selection.
5. **Store v4 discards format 1 layouts.** The step sets the Personal `working_set` row's `layout` and `layout_format` to null in one transaction, keeping the row and its revision, and touches nothing else. No format 1 decoder is kept, nothing is converted, and no notice is shown. The host accepts format 2 only; a format 1 save is refused `layout-invalid`.
6. **Older builds.** The store version moves to 4, so an older build's host refuses the store as newer, leaves it unmodified, and its desktop shows the store error. It never reaches the restore path, where an older desktop would start from an empty layout and its first save would replace a format 2 layout (ADR 0009 decision 6).
7. **Amendments to ADR 0009.**
   - Decision 3 (tab shape): the tab shape becomes the pane shape inside tabs. The fields and their rules are unchanged.
   - Decision 2 (conversion): an authorized exception. Store v4 discards format 1 layouts instead of converting them, by the user decision above. The rest of decision 2 holds: a format change ships with a store schema version bump, the step runs in one transaction with the version change, and the store's refusal of a newer version keeps older builds out.
   - ADR 0009's other decisions stay in force: the desktop-authored host-validated snapshot, unknown kinds passing through, revision-guarded saves, and the reporting of an invalid stored layout.

## Rejected alternatives

- **Keeping tab groups** and adding terminals to them. The user tried it and rejected it.
- **The group stopgap:** close a group when it empties and hide the strip of a lone group. It removes the empty-group symptom but keeps panes that contain tabs, and every later view kind would be built on it.
- **Converting format 1 layouts** (each group's tabs become one-pane tabs, with a notice that the split arrangement could not be kept), or making the group tree one tab. Rejected by user decision: there are no released builds or users of format 1, so a frozen decoder, the conversion and a notice are not worth the code.
- **Format 2 with no store version bump**, letting the decoder refuse format 1 at load. An older build would reach the restore path, and its first save would overwrite a format 2 layout. It also breaks ADR 0009 decision 2.
- **Focus after a close from the most recently used pane**, or from a complete focus history. Rejected by user decision: tree and strip order are predictable and need no history.
- **Dropping `recent`.** Kept: selecting a workspace returns to where the user last worked in it, for at most 128 ids.
- **A separate change for the layout.** The user chose this change.

## Consequences

- The domain model, operations and codec are pure and fully tested; the desktop workbench is rebuilt around tabs and panes, with view state in controllers keyed by pane id so a move restarts nothing.
- Later view kinds register a `kind`, `item` and `state` and need no model, protocol or schema change.
- A pane limit (16 per tab, 128 per document) replaces the group limit and reuses format 1's numbers, so neither the document nor the view count grows.
- Format 1 layouts are lost once, on the first start after the upgrade.

## Reversal cost

Medium: the format is stored data, so reversing it needs another format and a migration, and the desktop workbench is rebuilt around it. Until this change merges, no shipped build writes format 2.
