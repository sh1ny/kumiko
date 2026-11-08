# ADR 0014: App exit decisions, terminal activity and local drafts

- **Status:** accepted (2026-11-07)
- **Date:** 2026-11-07
- **Source:** change `app-exit-and-reopen` design D1 to D5; direction D7 and D29; user decisions 2026-11-02 (per-item Stop in the exit dialog; idle terminals close without a warning); ADR 0001, ADR 0002, ADR 0003, ADR 0004, ADR 0008 and ADR 0012
- **Relation:** amends ADR 0003's single-store wording and ADR 0008 decision 3's WAL rule, for the draft store only. Both files are unchanged; the main store keeps WAL with `synchronous=FULL`.

## Context

M1 needs quitting to be safe for running work. Before this change the desktop always answered `exit` to a quit, so running agent turns and terminal programs ended without a word. Terminals warned on close whenever a shell was live, even at its prompt. Composer text lived only in desktop memory, so a quit or a crash lost it. The host recorded `closed_cleanly` as "no live units at exit", which is also true after a desktop kill whose units settled, so the next launch could not say that the last run ended badly.

The answers have to hold together. One rule must decide whether a terminal is busy, for pane close, tab close and the exit list alike. Drafts are user data that cannot be recreated, but a sent prompt's text must not survive in a profile file (D29). Draft storage is optional and user-paced, so it must never delay reconciliation, Stop or desktop-loss cleanup, which ADR 0001 relies on.

## Decision

### Exit decision (D1)

1. **The desktop owns the exit decision.** A desktop exit coordinator runs inside Flutter's cancellable `onExitRequested`. It collects the affected items (agent sessions running a turn, awaiting a permission reply, stopping or sending; busy or unknown-activity terminals; chat panes whose latest draft is not stored after the quit flush), shows one exit dialog, performs per-item stops through the existing `agent/close` and `terminal/close` messages without removing panes, and answers `exit` or `cancel`.
2. **The host learns only that it is a quit.** On `exit` the desktop flushes layout and drafts (one shared 2 s quit flush), sends `app/quit`, then closes the connection as before. The host's only new duty is to record `exit_kind = 'quit'` (decision 17). The host already ends every unit when the connection closes (ADR 0001), and an exit the OS requires bypasses the callback and relies on exactly that.
3. While the dialog is open it follows live state: agent state changes and one `terminal/activity` poll per second. An item that becomes idle or ends leaves the list. A failed Stop keeps its item in the coordinator's own failed set, with the error and *cleanup unresolved*, and polls never remove it. When the list empties, one final activity read runs before quitting. A second quit request while the coordinator is collecting or deciding answers `cancel` and keeps the open dialog.

### Terminal activity (D2)

4. **Busy means the unit holds a process besides its shell, read on demand.** `terminal/activity` reads, per named terminal, the processes of its contained unit. Every live process other than the unit's leader makes the terminal busy; zombies are excluded. The result is `busy`, `idle`, `ended` (unknown id) or `unknown` (missing evidence or past the deadline). Busy results carry up to three image basenames, ascending pid order, each cut to 64 bytes on a character boundary, never arguments.
   - **Windows:** the process id list of the unit's job object.
   - **Linux:** processes whose session (`/proc/<pid>/stat`) equals the unit pid.
   - **macOS:** processes whose `getsid` equals the unit pid.
5. **Expected shell identity is fixed before spawn (POSIX).** The unit's pid survives `execve`, so `exec vim` would otherwise read idle. The host fixes the expected leader image before the spawn, from the profile executable it resolves for `execve`, with symlinks resolved: device and inode on Linux, canonical path on macOS. On each read the leader's current image (`/proc/<pid>/exe`, `proc_pidpath`) is compared with it: a different image is busy and named by its image, an unreadable one is `unknown`. An image observed after start is not used, because nothing pauses the shell before the host could read it, and a startup file may already have run `exec`. Windows has no `exec`, so the leader is always the shell.
6. **One rule everywhere, read on demand.** Pane close, tab close and the exit list all use this rule through one batched request per decision. Each request runs in one off-isolate read under a 1 s deadline, with one read in flight per host; a further request is answered `busy`, which the desktop treats as `unknown`. `unknown` warns as *may be running programs*. Idle and ended terminals close without a warning.
7. **Stated limits.**
   - **Close race.** A terminal read as idle can start a program between the read and its close; that program ends with the shell. The window is one activity round-trip. This is accepted.
   - **Script executables.** A profile whose executable is a script runs its interpreter as the leader image, so the terminal reads busy at its prompt and the warning names the interpreter. This is the safe direction and is accepted; the M1 walk records it per shell.
   - **Resident helpers.** Shells that keep helper processes (for example Nushell plugins, or an `ssh-agent` started by a profile) read busy at their prompt. The warning names the helper. Evidence of this in the M1 walk is what would reopen decision 4.
   - **Escapees.** A process that leaves its unit (a POSIX descendant that starts its own session, or anything outside the job on Windows) is not seen by the activity read, as it is not contained by ADR 0001. Detecting escapees is out of scope; OS-provided grouping is tracked in issue #9.
   - **Console host (Windows), measured outside the unit.** The bundled `OpenConsole.exe` is not in the unit's job. Measured on 2026-11-07 on Windows 11 (10.0.26300) by `packages/process_containment/test/unit_processes_test.dart` ("an idle PowerShell unit lists only its shell; the console host is not in the unit job"): the idle `powershell.exe -NoLogo -NoProfile -NoExit` unit's job listed only the shell's pid, and the `OpenConsole.exe` started for its pseudo-console was a child of the host process and not in the job (`IsProcessInJob` false). No console host pid is excluded from the read. The test keeps asserting this, so a ConPTY change that moves the console host into the job fails it rather than turning every idle Windows terminal busy.

### Drafts (D3)

8. **Drafts are host-stored per session.** A session with a saved record has at most one draft: `draft(session_id TEXT PRIMARY KEY, text TEXT NULL, bytes INTEGER NOT NULL, revision INTEGER NOT NULL, updated_at TEXT NOT NULL)` in the draft store (decision 12). There is no foreign key across files; the host checks that the session record exists in the main store before every save. A NULL `text` is a tombstone that keeps the revision floor. Empty text removes the draft. Drafts are never sent automatically, moved to another session, or written to the host log. The M2 history deletion must delete a session's draft row with its record. Panes with no saved record keep text in memory only, marked *Draft not saved*.
9. **One writer per session, revision-guarded.** A session's draft has one writer: its single desktop link. The host already refuses a second open of a saved session, and the desktop keeps at most one link per session id. Each link keeps a monotonic revision that every composer edit raises. `agent/draftSave(text, revision)` is refused `stale-revision` unless the revision is above the stored one; the refusal, `agent/draftLoad` and each save acknowledgement carry the stored revision. A link is *synced* once it has learned the stored revision (a new session is synced at 0) and then raises its counter above it. On `stale-revision` the link re-saves its *current* text once above the floor; a load that arrives after the user typed only raises the revision and never replaces the composer text.
10. **Saves follow the layout saver.** A per-link saver has 500 ms quiet, 2 s maximum dirty age, one save in flight plus one coalesced text and a 10 s deadline; at most 8 draft requests are in flight across links, and restore loads at most 8 drafts at a time. Saves flush on pane close (before `agent/close`) and in the quit flush. A link whose latest revision is not stored after a flush is *unsaved* and is named by pane close and the exit list; no loss is silent apart from a desktop kill or an OS-required exit, which lose at most the edits since the last successful save. When the draft store becomes available again the host sends `agent/draftStoreReady`, and the desktop saves each unsaved link once.
11. **Submission contract: removal commits before dispatch.** `agent/prompt` from Send carries `draftRevision` (the revision being sent) and `draftSynced`; Retry carries neither and removes nothing. For a send with `draftRevision = r`, the host validates the request, commits the draft change, then dispatches:
    - If the link was unsynced, or the stored revision is ≤ r, the text is removed, leaving a tombstone at revision max(stored, r). Newer text from a synced link stays.
    - A failed commit refuses the prompt `store-error`, and no answer within the draft deadline refuses it `draft-unavailable`, both before dispatch, so nothing runs and sending again is safe.
    - On any refusal of a prompt that carried `draftRevision`, the desktop raises the link above r and saves the composer text again, so it is stored even if the removal committed.
    - **Submission guard.** From Send until the prompt's result arrives, the link sends no save of the submitted snapshot; edits typed after Send save normally. On acceptance the composer is cleared only if unchanged since Send.

### Draft store (D4)

12. **A separate, host-owned `drafts.sqlite`.** Drafts live in `<profile>/drafts.sqlite`, not in the main store. The host is its sole writer, and it is opened only under the profile lock from ADR 0001, like the main store. It has its own `PRAGMA user_version` migrations (draft schema v1), applied transactionally. **This amends ADR 0003**: local state is no longer a single store file; it is the main store plus the draft store, both host-owned, both under the lock, both private by construction.
13. **Rollback journal, so a committed removal leaves no copy.** The draft store opens with `journal_mode = DELETE`, `synchronous = EXTRA` and `secure_delete = ON`, reads all three back after opening, and disables drafts if any differs. Secure delete zeroes replaced and freed cell content; the rollback journal with the old page images is deleted at commit; `EXTRA` also syncs the directory after that delete, which `FULL` does not guarantee in DELETE mode. Once a removal or overwrite commits, no file under the profile holds the old text, and there is no WAL to checkpoint and no purge to carry. A crash mid-transaction leaves a hot journal holding the current draft, which the next open rolls back. **This amends ADR 0008 decision 3 for the draft store only**: the main store keeps WAL with `synchronous=FULL`.
14. **A bounded worker isolate owns the connection.** One draft worker isolate in the host holds the only connection. It is spawned after the main store is open and reconciliation has started; startup, reconciliation, Stop, permission replies and desktop-loss handling never await it, and the control isolate never runs a draft SQLite call. The worker runs one operation at a time. The host admits at most 16 pending draft operations and answers `draft-unavailable` at once past that. Each operation has a 5 s host-side deadline; on timeout the host answers `draft-unavailable` and marks the store *not responding*, answering further operations `draft-unavailable` at once until the stuck operation returns, which clears it and sends `agent/draftStoreReady`. At host exit the worker is not awaited.
15. **Unavailable storage disables drafts, never the host.** A draft store that cannot be opened, migrated or verified disables drafts with a visible reason on every chat pane. Everything else starts. While drafts are disabled or *not responding*, a send carrying `draftRevision` is refused `draft-unavailable` before dispatch, because its removal cannot be confirmed; Retry still dispatches.
16. **Exclusive reset.** While drafts are disabled, chat panes offer **Reset draft storage** behind a confirmation that every stored draft will be lost. `agent/draftReset` is refused `draft-store-in-use` unless drafts are disabled, so it can never discard a working store. The host reserves the reset synchronously before its first await; while reserved, another reset is refused `draft-store-in-use` and every draft operation is answered `draft-unavailable`. Under the reservation the host stops the old worker and waits for it to exit, deletes `drafts.sqlite` and its journal, and starts exactly one successor on a fresh file; only that successor, once open and verified, ends the reservation and sends `agent/draftStoreReady`. A failed exit wait, delete or open ends the reservation with drafts still disabled and the reset refused with the reason.

### Previous exit (D5)

17. **The previous exit is a recorded kind.** Store v6 adds `host_instance.exit_kind TEXT NULL CHECK (exit_kind IN ('quit'))`. The host writes `'quit'` when it finishes only if it received `app/quit` and the close reason was the input closing. Any other end leaves it NULL. `closed_cleanly` is unchanged.
18. **Snapshot before reconciliation.** When the host takes the lock, before reconciliation starts, it reads the immediately previous instance row (the highest id below its own) and keeps `{kind: quit | unexpected | none, openedAt}` as an immutable in-memory snapshot, because reconciliation deletes instance rows without units. `app/previousExit` returns the snapshot. An unreadable row gives `none`, a host log entry and normal startup. The desktop asks once, for its first host connection, and shows *Kumiko did not close normally last time* when reconciliation has finished, with counts from `cleanup/state`; never after a quit, on first launch or after Restart host.

### Bounds

| Flow | Bound | At the bound |
|---|---|---|
| `terminal/activity` | ≤ 64 terminal ids per request; 1 s deadline; 1 read in flight per host | `invalid-params` above 64; unread ids `unknown`; a second request `busy` |
| Exit dialog poll | 1 activity request per second while open | — |
| Program names | ≤ 3 per terminal, ≤ 64 B each | Extra processes counted, not named |
| Draft text | ≤ 256 KiB encoded JSON string contents (UTF-8 and escaping counted) | `draft-too-large`; stored draft unchanged |
| Stored drafts total | ≤ 32 MiB of `bytes` across rows | `draft-cap`; other drafts unchanged |
| Draft worker | 1 operation at a time; ≤ 16 pending operations; 5 s host deadline per operation | `draft-unavailable` at once past 16 or while *not responding* |
| Desktop draft saves | ≤ 8 in flight across links; one in flight plus one coalesced per link; 10 s per save; quit flush 2 s shared with layout | Newer text replaces the coalesced one |

## Rejected alternatives

- **D1: A host-driven exit.** The desktop would ask the host to prepare an exit and the host would enumerate units and drive the stops. The host has no panes or titles, so the list would need mapping back to views, and a host state machine would carry a purely UI decision.
- **D2: The PTY foreground process group (`tcgetpgrp`).** It misses background jobs and has no ConPTY equivalent, which would mean two rules.
- **D2: Host-pushed activity changes.** Continuous polling of every terminal costs process-table scans and control traffic all the time, for information needed only at close and exit.
- **D2: The marker scan.** It walks every process environment under a 10 s pass bound, far too slow for an interactive close.
- **D2: Observing the shell's image after start.** By the time the host reads it, a startup file may already have run `exec`.
- **D3: Drafts in the layout document's pane `state`.** Pane state is ≤ 4 KiB, and a draft is session-scoped and must outlive its pane's close.
- **D3: A desktop-written draft file.** It breaks ADR 0003's host-only writing and the rule that a refused second launch writes nothing to the profile.
- **D4: Drafts in the main store with a WAL purge.** A synchronous checkpoint misreported prompt results and blocked control; a background checkpoint contended for the main store's locks, did not own automatic checkpoints, and its startup purge could block reconciliation.
- **D4: Draft calls on the control isolate.** A stalled open, hot-journal recovery or commit would hold reconciliation, Stop and desktop-loss cleanup.
- **D4: Switching the main store to a rollback journal.** It contradicts ADR 0008 and costs ledger and layout write throughput for a property only drafts need.
- **D4: Encrypting drafts with a local key.** The key lives in the same profile, so the text stays recoverable.
- **D5: Reusing `closed_cleanly`.** It is true after a desktop kill whose units settled, which is exactly the case to report.
- **D5: A desktop "running" marker file.** The desktop would write into the profile, and a refused second launch would touch it.

## Consequences

- Idle terminals now close without a warning, and *New session* starts with an empty composer while the old session keeps its draft. Both are user-visible changes stated in the change proposal.
- The profile holds a second database file. Backups (ADR 0003) must read both stores through the host.
- Each draft commit syncs the journal, the database and the directory. Saves are debounced, human-paced and off the control isolate. Measured in change `app-exit-and-reopen` task 4.4 on Windows 11 with a local NTFS disk, through the real worker (rollback journal, `synchronous=EXTRA`, `secure_delete=ON`): 30 saves of 4 KiB at rising revisions, each followed by the removal commit of a send, awaited one at a time. A save took a median of 5.2 ms (p95 5.5 ms, max 5.6 ms) and a removal a median of 5.3 ms (p95 5.6 ms, max 5.7 ms); in a full-suite run on the same machine the median stayed near 6 ms with a worst case of 24 ms. A save acknowledged while a saturated terminal and a stalled agent session competed for the host took 15 to 25 ms at worst of 20. All are far under the 100 ms bound that would reopen decision 12. The figures are one Windows machine; the unit test `measured: draft save and removal latency` prints them on every platform and fails above a 100 ms median, and Linux and macOS are not yet measured here.
- Power-loss durability rests on SQLite's documented `EXTRA` contract. Tests assert the effective settings and hot-journal rollback; a real power cut is not exercised.
- Any later feature that stores user text which must disappear on send or discard (file recovery drafts included) should follow decisions 12-13 or record why not.

## Reversal cost

- D1: low. It is desktop-internal apart from one additive notification.
- D2: medium. It defines user-visible warning behaviour; the M1 walk's resident-helper evidence would reopen it.
- D3: medium. It is a stored table with a revision contract on the protocol, but additive and owned by one service.
- D4: medium. It is a second database file with its own schema and one worker isolate, but additive. Folding drafts back into the main store would need a replacement for the no-copy-after-removal property.
- D5: low. It is an additive nullable column.
