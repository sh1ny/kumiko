# Review

## Metadata

- **Round:** 8
- **Prior round:** Round 7 REVISE (codex): C1 disabled draft storage dispatches sends without removal, so an earlier stored draft can return after a healthy restart. Escalated to the user (seventh consecutive REVISE); the user chose to refuse composer sends while removal cannot be confirmed, add a confirmed Reset draft storage action, and run round 8.
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** `app-exit-and-reopen` proposal, FULL design and all six delta specs; corresponding main-spec MODIFIED requirements; architecture and ADRs 0001–0004, 0006, 0008, 0009, 0011 and 0012; direction D7 and cited agent-sessions, workbench-layout and terminal-sessions specs; cited desktop lifecycle, workbench, agent, terminal, view-closer and layout-saver paths; host lifecycle, ledger, store, cleanup and prompt acceptance; containment sources; protocol prompt definitions and launcher lifecycle.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. Concurrent resets can delete the replacement store after it becomes usable.**

D4 offers Reset in every chat pane and admits `agent/draftReset` whenever drafts are disabled. It defines no reset-in-progress reservation. Reset crosses asynchronous worker-stop and worker-start boundaries, so checking “disabled” at entry does not serialize resets.

Concrete ordering:

1. Two confirmed reset requests arrive while drafts are disabled; both pass admission.
2. Reset A stops the old worker, deletes the files and opens replacement worker A.
3. A publishes `agent/draftStoreReady`; the desktop saves composer text and receives successful acknowledgements.
4. Reset B resumes its already-admitted deletion against the same paths.

On platforms permitting deletion of an open file, B can unlink the working replacement database. Worker A can retain its connection while B creates another worker and file. Confirmed saves can disappear on restart, and two workers can hold competing authority. On platforms refusing deletion, the second reset can instead report failure after the first has already restored service.

The existing cleanup service explicitly reserves operations before awaiting (`cleanup_service.dart`, `_busy`); this new destructive operation needs equivalent ownership. The `draft-store-in-use` check alone does not establish D4’s claim that reset “can never discard a working store.”

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. In D4, require the host to reserve a single reset operation synchronously before its first await. Refuse another reset while that reservation exists. Keep draft operations unavailable throughout replacement; confirm the old worker has exited before deleting files or opening its successor. Publish `agent/draftStoreReady` only from the replacement owned by that reset.
2. Add a protocol scenario holding the first reset across worker replacement while a second reset arrives: the second is refused, exactly one replacement worker becomes authoritative, and a save acknowledged after readiness survives host restart.

CHANGES_APPLIED: yes

## Rebuttals

- **Round 1 C1 — Resolved.** Retry omits draft ownership; the submission guard distinguishes submitted snapshots from subsequent edits.
- **Round 1 C2 — Resolved.** Expected POSIX executable identity is established before spawn; replacement or unreadable images warn.
- **Round 1 M1 — Resolved.** The immutable predecessor snapshot precedes reconciliation.
- **Round 1 M2 — Resolved.** Failed Stop items survive polling independently; durable cleanup owns recovery.
- **Round 1 M3 — Resolved.** Failed persistence requires explicit loss confirmation, including during host loss.
- **Round 1 M4 — Resolved for the reported checkpoint failure.** The separate rollback-journal store replaces best-effort WAL purging.
- **Round 2 C1 — Resolved.** Removal failure refuses dispatch; later persistence failures cannot turn executed work into a prompt rejection.
- **Round 2 M1 — Resolved.** Shell identity no longer depends on post-start observation.
- **Round 2 M2 — Resolved.** Unsaved-draft items remain independent of host availability.
- **Round 2 M3 — Resolved.** Secure overwrite removes historical draft content while preserving newer text.
- **Round 2 M4 — Resolved.** Draft SQLite calls have a separate execution owner, bounded admission and retained timeout ownership.
- **Round 3 C1 — Resolved.** Reconciliation does not await draft readiness.
- **Round 3 M1 — Resolved.** Draft storage shares neither the main store’s locks nor its automatic checkpoints.
- **Round 3 M2 — Resolved.** Removal commits before adapter dispatch; transaction failure refuses execution.
- **Round 4 C1 — Resolved.** Worker isolation covers stalled draft opening and commits.
- **Round 4 M1 — Resolved at the design-contract level.** Verified `synchronous=EXTRA` establishes the specified durability boundary; real power-cut testing remains explicitly unverified.
- **Round 4 M2 — Resolved.** Authoritative revision replies recover the floor; late loads preserve local edits.
- **Round 5 C1 — Resolved.** The submission guard suppresses re-saving the submitted snapshot while acknowledgement is pending.
- **Round 5 M1 — Resolved.** `agent/draftStoreReady` triggers bounded recovery saves after availability returns.
- **Round 6 C1 — Resolved.** Unsynced sends remove the stored row unconditionally and retain the maximum revision floor.
- **Round 7 C1 — Resolved.** Disabled storage now refuses composer sends before dispatch and preserves composer text. Retry remains limited by the existing authentication-retry eligibility and represents a previously accepted prompt; omitting draft removal preserves unrelated composer text. Reset requires explicit loss confirmation and refuses a working store, but concurrent reset ownership needs the edits above.
- **Round 8 M1 — Resolved.** D4 now requires synchronous exclusive reset reservation, unavailable draft operations throughout replacement, confirmed old-worker exit before deletion or successor startup, and readiness only from the owned successor; the protocol scenario refuses a concurrent reset, permits exactly one replacement worker, and requires acknowledged saves to survive host restart.