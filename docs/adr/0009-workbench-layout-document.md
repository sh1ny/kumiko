# ADR 0009: Workbench layout document

- **Status:** accepted (2026-10-29)
- **Date:** 2026-10-29
- **Source:** change `local-store-and-workbench-shell` design D1, D7 and D10; ADR 0003 (host sole store writer, debounced layout saves); ADR 0004 (immutable targets)

## Context

The workbench needs its tab and split layout saved through the host and restored on reopen. Later changes add tab kinds (terminals, agent sessions, tools) that must be saved and restored by the same mechanism. The layout carries no authority: a tab bound to a workspace grants nothing, and every launch is still checked by the host. Two shapes were considered: a host-owned model edited through fine-grained protocol operations, and a whole-layout document authored by the desktop.

## Decision

1. **Desktop-authored snapshot, host-validated.** The desktop owns the live layout in memory. Each change produces a whole-layout document for the working set, sent with `workbench/save`. The host decodes and validates it with the shared `domain` codec and bounds, checks that every bound workspace id exists, and stores it in one `working_set` row. The host stays the store's only writer (ADR 0003); the desktop never sends partial edits.
2. **Versioned format, converted only by store migrations.** The document carries a `format` number. A format change always ships with a store schema migration that converts stored documents. The store's refusal of a newer schema version therefore keeps an older build from reading a newer format.
3. **Tab shape.** A tab is `{id, kind, workspace, item, state}`:
   - `kind` names the view kind;
   - `workspace` is a workspace id or null, set when the tab is created and never written by any layout operation (ADR 0004);
   - `item` is the kind's identity key, used to focus an open item instead of opening it twice;
   - `state` is a kind-owned JSON object of at most 4 KiB encoded.
4. **Unknown kinds pass through.** A tab whose `kind` the running build does not know is validated only for the common fields, shown as an *unsupported view*, and re-encoded unchanged on the next save.
5. **Revision-guarded saves.** Each save carries a revision. The host stores it only when the revision is greater than the stored one and answers `stale-revision` otherwise, so a reordered or replayed save never overwrites a newer layout.
6. **Invalid stored layout.** A stored document that fails decode or validation is reported as a restore error at load, the desktop starts from an empty layout, and the next save replaces the row.

## Rejected alternatives

- **Host-owned layout edited through operations (`tab/move`, `group/split`, ...).** Every gesture would become a protocol method with its own error path, the layout would live in two processes with ordering between them, and each new tab kind would need host changes.
- **Normalized `tab_group` and `tab` tables.** The tree with ratios and active and recent tabs maps badly to rows, and every save would rewrite many rows with no query benefit.
- **A closed enum of tab kinds.** After a later build adds a kind, running an older build on the same store would discard the whole layout.
- **Opaque JSON stored without host validation.** A desktop bug could persist an oversized or malformed document that no later build can load.

## Consequences

- New tab kinds extend the document by registering a `kind` with its own `item` key and `state`; they need no protocol or schema change unless the common fields change.
- Kind state stays small (≤ 4 KiB). Terminal scrollback, transcripts and drafts live elsewhere.
- Changing the common document shape needs a `format` bump and a store migration.

## Reversal cost

Medium: the document is stored data. The `format` field and the shared codec make a later conversion one migration step.
