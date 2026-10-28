# ADR 0003: Host-owned local SQLite store, private by construction

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D1, D7, D22, D23, D29, Proposed Defaults (local persistence); user decision 2026-10-28

## Context

Solo work needs durable local state with no server:
- workbench layout and Personal/project working sets;
- saved agent-session records;
- unsent drafts and file recovery drafts;
- later, solo projects, tasks and documents.

D29 keeps private development data on the user's PC by construction, not by a privacy flag. D7 and D10 require recovery to survive UI failure. The design record proposed SQLite with shared pure domain rules; the exact package was left open.

## Decision

1. Local durable application state lives in **SQLite** database files in the per-user application data directory of the OS.
2. **The execution host is the sole writer.** The desktop reads and changes state only through the ADR 0002 protocol, so a UI crash never leaves a half-written store, and one process owns migrations. Sole ownership is enforced, not assumed. A host opens or migrates the store only while it holds the per-user exclusive lock from ADR 0001; without the lock it does neither. A second instance therefore never writes layout, drafts or session records, and never races a running instance's migrations.
3. **Schema versioning:** each database records its schema version. The host applies forward migrations in a transaction at startup. A failed migration stops startup with a visible error and leaves the previous file usable. The host never silently resets or recreates a store.
4. **Separation of private and shared state:** the local store is never a replica of team-server data (ADR 0007). Nothing in it is synchronized, indexed or uploaded by Kumiko. Saved agent sessions reference the runtime's native history; they do not copy transcripts unless a later change decides to, and any copy stays local.
5. **Package selection is deferred to an M1 probe.** The probe compares candidate Dart SQLite bindings in a `dart compile exe` host on Windows, Linux and macOS: bundled native library, WAL behaviour, migration support, licence. The storage change records the choice as a follow-up ADR, without editing this one.
6. Domain rules for records that exist both locally and on a team server live in the pure `domain` package (ADR 0001), so both stores enforce the same rules through their own operation paths.

## Rejected alternatives

- **JSON/flat files per concern.** Fine for layout alone, but corrupt-on-crash risk, no transactions and a forced rewrite once solo planning lands in M3.
- **Desktop writes the database directly.** Two writers, migrations racing between processes, and recovery depending on the UI process that may have crashed.
- **Embedding the team-server stack (Serverpod with a local database) for solo use.** It contradicts D1. Server-side storage features are not a serverless embedded store.

## Consequences

- Layout and draft writes cross IPC. Their frequency must be bounded (debounced layout saves) in the change that adds them.
- Backups (D22, D47) later read this store through the host, never by copying a live file without a consistent snapshot.

## Reversal cost

Medium for the engine choice before solo planning records exist, high after. Sole-writer and private-by-construction are high reversal cost.
