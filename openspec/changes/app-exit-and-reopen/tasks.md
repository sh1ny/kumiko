# Tasks

## Test map

Paths are relative to `packages/`. Where an existing test turns red because its fixture now needs a busy terminal, the row is `red` and names the existing test; the task rewrites the fixture.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| app-exit → Quitting with no affected work asks nothing | Quit with idle work | desktop/test/exit_test.dart | quit with idle agent, idle terminal and stored draft exits without a dialog | red |
| app-exit → Quitting with no affected work asks nothing | Activity cannot be read in time | desktop/test/exit_test.dart | activity timeout lists the terminal as may be running programs | red |
| app-exit → The exit dialog lists every affected item | Agent turn and terminal program | desktop/test/exit_test.dart | dialog lists running agent and vim with per-item Stop, bulk and Cancel | red |
| app-exit → The exit dialog lists every affected item | Item finishes while the dialog is open | desktop/test/exit_test.dart | item leaves the list when its work ends; last item quits | red |
| app-exit → The exit dialog lists every affected item | Another quit while the dialog is open | desktop/test/exit_test.dart | second quit request focuses the open dialog | red |
| app-exit → Stopping one item keeps the rest and the layout | Stop items one by one | desktop/test/exit_test.dart | per-item Stop removes only that item; quits when list empties | red |
| app-exit → Stopping one item keeps the rest and the layout | Reopen after stopping items | desktop/integration_test/exit_reopen_test.dart | stopped panes reopen in place with the layout | red |
| app-exit → Stopping one item keeps the rest and the layout | A Stop fails | desktop/test/exit_test.dart | failed Stop keeps the item with error and cleanup unresolved; polls do not remove it | red |
| app-exit → The bulk action states and ends all affected work | Bulk stop and close | desktop/test/exit_test.dart | bulk action states consequences and ends all items | red |
| app-exit → The bulk action states and ends all affected work | Unsaved draft at quit | desktop/test/exit_test.dart | draft-too-large composer listed as unsaved; bulk names its loss | red |
| app-exit → The bulk action states and ends all affected work | Bulk close with an item that cannot be ended | host/test/it/lifecycle_test.dart | unendable unit at quit is cleanup unresolved at next launch | red |
| app-exit → Cancel keeps unresolved work running | Cancel after stopping one item | desktop/test/exit_test.dart | Cancel after one Stop keeps the rest running and the stop done | red |
| app-exit → Cancel keeps unresolved work running | Cancel at once | desktop/test/exit_test.dart | Cancel at once changes nothing | red |
| app-exit → An exit that cannot be cancelled still ends everything | OS-required exit with running work | host/test/it/lifecycle_test.dart | desktop closing input without app/quit ends every unit, no dialog path | red |
| app-exit → An exit that cannot be cancelled still ends everything | Host already lost at quit | desktop/test/exit_test.dart | host lost with every composer stored exits at once | red |
| app-exit → An exit that cannot be cancelled still ends everything | Host lost with an unsaved draft | desktop/test/exit_test.dart | host lost with unsaved text lists Draft not saved: host lost | red |
| app-exit → An exit that cannot be cancelled still ends everything | Host lost while the dialog is open | desktop/test/exit_test.dart | host loss removes process items and keeps draft items | red |
| terminal-sessions → The host reports whether a terminal is busy | Shell at its prompt | host/test/it/terminal_activity_test.dart | idle shell reads idle | red |
| terminal-sessions → The host reports whether a terminal is busy | Program running | host/test/it/terminal_activity_test.dart | child program reads busy with its name | red |
| terminal-sessions → The host reports whether a terminal is busy | Background job | host/test/it/terminal_activity_test.dart | background sleep reads busy | red |
| terminal-sessions → The host reports whether a terminal is busy | Shell replaced by exec | host/test/it/terminal_activity_test.dart | exec replaces leader image and reads busy (POSIX) | red |
| terminal-sessions → The host reports whether a terminal is busy | Startup file runs exec | host/test/it/terminal_activity_test.dart | startup-file exec reads busy against resolved executable (POSIX) | red |
| terminal-sessions → The host reports whether a terminal is busy | Leader image unreadable | host/test/it/terminal_activity_test.dart | injected unreadable leader image reads unknown | red |
| terminal-sessions → The host reports whether a terminal is busy | Process table cannot be read in time | host/test/it/terminal_activity_test.dart | injected slow table read reads unknown at the deadline | red |
| terminal-sessions → The host reports whether a terminal is busy | Unknown terminal id | host/test/it/terminal_activity_test.dart | unknown id reads ended | red |
| terminal-sessions → Closing live terminals warns about process loss | Close a terminal running vim | desktop/test/terminal_test.dart | close of a busy terminal warns naming its program | red |
| terminal-sessions → Closing live terminals warns about process loss | Close a terminal at its prompt | desktop/test/terminal_test.dart | idle terminal closes without a warning | red |
| terminal-sessions → Closing live terminals warns about process loss | Cancel the warning | desktop/test/terminal_test.dart | existing cancel-warning test, busy fixture | red |
| terminal-sessions → Closing live terminals warns about process loss | Close a tab with several terminal panes | desktop/test/terminal_test.dart | 'a close warning naming more terminals than fit…', busy fixture | red |
| terminal-sessions → Closing live terminals warns about process loss | Activity unknown | desktop/test/terminal_test.dart | unknown activity warns may be running programs | red |
| terminal-sessions → Closing live terminals warns about process loss | Move a live terminal | desktop/test/terminal_test.dart | 'after a move the moved pane keeps the keys…' | green |
| terminal-sessions → Closing live terminals warns about process loss | A shell exits cleanly while the warning is open | desktop/test/terminal_test.dart | 'a clean exit while the close dialog is open…', busy fixture | red |
| terminal-sessions → Closing live terminals warns about process loss | A shell ends otherwise while the warning is open | desktop/test/terminal_test.dart | existing ends-otherwise-while-warning test, busy fixture | red |
| terminal-sessions → Closing live terminals warns about process loss | Close an ended terminal | desktop/test/terminal_test.dart | existing close-ended-terminal test | green |
| terminal-sessions → Closing live terminals warns about process loss | Close a terminal that is still starting | desktop/test/terminal_test.dart | starting terminal closes without a warning | red |
| terminal-sessions → Closing live terminals warns about process loss | Program ignores termination | host/test/it/terminal_close_test.dart | 'program ignoring termination: ack within 250 ms…' | green |
| workbench-layout → Closing a pane or tab checks for live work | Close a tab holding live terminals | desktop/test/workbench_test.dart | tab close lists busy terminals only | red |
| workbench-layout → Closing a pane or tab checks for live work | Cancel closing a tab | desktop/test/workbench_test.dart | existing cancel-tab-close test, busy fixture | red |
| workbench-layout → Closing a pane or tab checks for live work | Close a pane holding a live terminal | desktop/test/workbench_test.dart | pane close with busy terminal warns | red |
| workbench-layout → Closing a pane or tab checks for live work | Tab with no live work | desktop/test/workbench_test.dart | tab with idle agent and terminal at prompt closes silently | red |
| workbench-layout → Closing a pane or tab checks for live work | Part of a tab close fails | desktop/test/workbench_test.dart | existing partial-tab-close test, busy fixture | red |
| agent-sessions → Unsent drafts are stored per session | Draft survives quit | desktop/integration_test/exit_reopen_test.dart | composer text returns after quit and reopen | red |
| agent-sessions → Unsent drafts are stored per session | Draft survives a desktop kill | host/test/it/draft_store_test.dart | draft saved by the stand-in desktop survives its kill | red |
| agent-sessions → Unsent drafts are stored per session | Draft survives closing the pane | desktop/test/draft_test.dart | pane close flushes the draft before agent/close | red |
| agent-sessions → Unsent drafts are stored per session | No saved record yet | desktop/test/draft_test.dart | starting link keeps text in memory and shows Draft not saved | red |
| agent-sessions → Unsent drafts are stored per session | Draft too large | desktop/test/draft_test.dart | draft-too-large shows reason and keeps text | red |
| agent-sessions → Unsent drafts are stored per session | Draft storage full | host/test/it/draft_store_test.dart | save past 32 MiB total refused draft-cap | red |
| agent-sessions → Unsent drafts are stored per session | Save fails | desktop/test/draft_test.dart | host-lost save leaves link unsaved and visible | red |
| agent-sessions → Closing with an unsaved draft says it will be lost | Close a pane with a refused draft | desktop/test/draft_test.dart | close confirmation names the unsaved draft; Cancel keeps it | red |
| agent-sessions → Closing with an unsaved draft says it will be lost | Close a pane with a stored draft | desktop/test/draft_test.dart | stored idle draft closes silently and stays stored | red |
| agent-sessions → A restored pane shows its session's draft | Draft returns on reopen | desktop/integration_test/exit_reopen_test.dart | restored pane shows draft before Continue; nothing sent | red |
| agent-sessions → A restored pane shows its session's draft | New session after resume unavailable | desktop/test/draft_test.dart | New session starts empty and the old draft stays | red |
| agent-sessions → A restored pane shows its session's draft | Stored draft cannot be read | desktop/test/draft_test.dart | failed load shows Draft not loaded, stored draft untouched | red |
| agent-sessions → A restored pane shows its session's draft | Typing after a failed load | host/test/it/draft_store_test.dart | failed load then edit at low revision recovers floor via stale reply | red |
| agent-sessions → A restored pane shows its session's draft | Send right after a failed load | host/test/it/draft_store_test.dart | unsynced send removes stored P; kill after ack leaves neither | red |
| agent-sessions → A restored pane shows its session's draft | Send before a slow load returns | host/test/it/draft_store_test.dart | send before held load returns removes P | red |
| agent-sessions → A restored pane shows its session's draft | Load arrives after the user typed | desktop/test/draft_test.dart | late load raises revision and keeps typed text | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Send removes the draft | host/test/it/draft_store_test.dart | canary d1f9 absent from every profile file after ack | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Clearing removes the draft | host/test/it/draft_store_test.dart | empty save tombstones and the text is absent from every file | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Retry with a different draft | desktop/test/draft_test.dart | Retry carries no draftRevision and Q stays | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Stale save while a prompt is being sent | desktop/test/draft_test.dart | guard skips stale re-save of the submitted snapshot | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Edits while a prompt is being sent | host/test/it/draft_store_test.dart | R saved above r survives; P absent from every file | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Prompt refused by the adapter | desktop/test/draft_test.dart | adapter refusal re-saves composer above r | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Removal fails | host/test/it/draft_store_test.dart | injected commit failure refuses the prompt before dispatch | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Removal commits after its deadline | desktop/test/draft_test.dart | draftStoreReady retries the unsaved link without typing | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Send while draft storage is unavailable | host/test/it/draft_store_test.dart | disabled store refuses composer send; P kept for healthy restart | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Reset draft storage | host/test/it/draft_store_test.dart | confirmed reset deletes files, sends draftStoreReady, saves succeed | red |
| agent-sessions → A sent or cleared draft cannot be recovered | Draft storage not responding at send | host/test/it/draft_store_test.dart | held commit refuses send draft-unavailable within the deadline | red |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | Record survives restart | host/test/it/agent_test.dart | 'after a host restart the store holds the same ids…' | green |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | Start fails before a native id | host/test/it/agent_test.dart | 'no record is inserted while session/new is still pending' | green |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | No transcript in Kumiko's files | host/test/it/agent_close_test.dart | existing transcript-absence scan | green |
| agent-sessions → Each session keeps a saved record; transcripts stay in the runtime | An unsent draft is the only stored text | host/test/it/draft_store_test.dart | canary 5b2e found only in drafts.sqlite | red |
| agent-sessions → Closing a running agent asks for confirmation | Close an idle session | desktop/test/agent_test.dart | 'rejected pending prompt restores idle close without confirmation' | green |
| agent-sessions → Closing a running agent asks for confirmation | Cancel closing a running session | desktop/test/agent_test.dart | existing cancel-running-close test | green |
| agent-sessions → Closing a running agent asks for confirmation | Confirm closing a running session | host/test/it/agent_close_test.dart | 'running close cancels permissions before cancel…' | green |
| agent-sessions → Closing a running agent asks for confirmation | Tab with a running agent and a live terminal | desktop/test/workbench_test.dart | 'closing a tab with a running session and a live terminal…', busy fixture | red |
| agent-sessions → Closing a running agent asks for confirmation | Turn ends while the confirmation is open | desktop/test/agent_test.dart | existing turn-ends-while-confirmation test | green |
| execution-host → The host records whether the desktop quit | Normal quit | host/test/it/previous_exit_test.dart | app/quit then input close writes exit_kind quit | red |
| execution-host → The host records whether the desktop quit | Desktop killed | host/test/it/previous_exit_test.dart | killed stand-in desktop leaves exit_kind null | red |
| execution-host → The host records whether the desktop quit | Host killed | host/test/it/previous_exit_test.dart | killed host leaves exit_kind null | red |
| execution-host → An unexpected previous end is shown at the next launch | Reopen after the desktop was killed | desktop/test/cleanup_list_test.dart | notice shows did not close normally with all cleaned | red |
| execution-host → An unexpected previous end is shown at the next launch | Reopen with unresolved cleanup | desktop/test/cleanup_list_test.dart | notice lists unresolved workspaces with Show cleanup list | red |
| execution-host → An unexpected previous end is shown at the next launch | Reopen after a normal quit | host/test/it/previous_exit_test.dart | previousExit after quit reports quit; no notice | red |
| execution-host → An unexpected previous end is shown at the next launch | First launch on a new profile | host/test/it/previous_exit_test.dart | new profile reports no previous instance | red |
| execution-host → An unexpected previous end is shown at the next launch | Restart host after a loss | host/test/it/previous_exit_test.dart | Restart host shows the notice once for the lost instance | red |
| execution-host → An unexpected previous end is shown at the next launch | Reconciliation removes the previous instance row | host/test/it/previous_exit_test.dart | snapshot taken before reconciliation deletes the row | red |
| execution-host → An unexpected previous end is shown at the next launch | Previous exit cannot be read | host/test/it/previous_exit_test.dart | unreadable snapshot logs only and shows no notice | red |
| desktop-host-protocol → Lifecycle, activity and draft methods are capability-gated | Both peers support lifecycle | host_protocol/test/lifecycle_messages_test.dart | lifecycle methods round-trip when both advertise it | red |
| desktop-host-protocol → Lifecycle, activity and draft methods are capability-gated | Host without lifecycle | host/test/it/previous_exit_test.dart | host without lifecycle refuses method-not-available; quit still ends units | red |
| desktop-host-protocol → Activity and draft requests are bounded | Too many terminals | host/test/it/terminal_activity_test.dart | 65 ids refused invalid-params without a table read | red |
| desktop-host-protocol → Activity and draft requests are bounded | Oversized draft | host_protocol/test/agent_messages_test.dart | draft one byte past 256 KiB encoded refused draft-too-large | red |
| desktop-host-protocol → Activity and draft requests are bounded | Unknown session | host/test/it/draft_store_test.dart | draftSave for unknown session refused unknown-session | red |
| desktop-host-protocol → Activity and draft requests are bounded | Draft save under saturated output | host/test/it/draft_store_test.dart | draft save acked within control latency under saturated output | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Draft store stalls at start | host/test/it/draft_store_test.dart | held draft open: reconciliation and launches proceed | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Draft commit stalls | host/test/it/draft_store_test.dart | held commit: Stop and permission reply within control latency | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Desktop lost while a draft commit stalls | host/test/it/draft_store_test.dart | held commit: desktop kill ends every unit within the bound | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Stale save reports the stored revision | host/test/it/draft_store_test.dart | stale-revision reply carries the stored revision | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Store answers again | host/test/it/draft_store_test.dart | released commit clears not responding and sends draftStoreReady | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Reset refused while storage works | host/test/it/draft_store_test.dart | reset on a working store refused draft-store-in-use | red |
| desktop-host-protocol → Draft storage never delays control or cleanup | Second reset during a reset | host/test/it/draft_store_test.dart | concurrent reset refused; one successor; acked save survives restart | red |

## 1. ADR and architecture

- [ ] 1.1 Write `docs/adr/0014-app-exit-decisions-terminal-activity-and-local-drafts.md` covering D1-D5: the desktop owns the exit decision, the busy rule with its close race, script-executable and escapee limits, per-session drafts with the revision, sync and submission-guard contract, the separate `drafts.sqlite` (DELETE journal, `synchronous=EXTRA`, `secure_delete`, worker isolate, reset), which amends ADR 0003's single-store wording and ADR 0008's WAL rule for drafts only, and `exit_kind` with the pre-reconciliation snapshot. Each decision gets its rejected alternatives and reversal cost. Verify: the file exists with `Status: accepted`, and `openspec validate app-exit-and-reopen --strict` passes.
- [ ] 1.2 Update `openspec/architecture.md`: an ADR index row for 0014; state rows for stored drafts (draft store, host-owned) and the previous-exit snapshot; bound rows for drafts (256 KiB each, 32 MiB total, ≤ 16 pending worker operations, 5 s deadline), activity (64 ids, 1 s) and the exit poll (1 s). Verify: the rows are present and cite ADR 0014.

## 2. Unit process listing and terminal activity

- [ ] 2.1 Write a failing `process_containment` test (`test/unit_processes_test.dart`) listing an idle PowerShell unit's processes on Windows. Settle whether `OpenConsole.exe` is in the unit job: if it is, exclude the console host pid captured at pseudo-console creation, and record the finding in ADR 0014. Verify: the idle unit lists only its shell.
- [ ] 2.2 Implement unit process listing (Windows `JobObjectBasicProcessIdList`; POSIX session members via `getsid` / `/proc/<pid>/stat`) and image names (`QueryFullProcessImageNameW`, `/proc/<pid>/comm`, `proc_name`), plus the expected leader identity resolved before spawn (device and inode on Linux, `proc_pidpath` on macOS). Verify: `unit_processes_test.dart` passes on the CI OS matrix.
- [ ] 2.3 Add `terminal/activity` to `host_protocol` (64-id bound, busy/idle/unknown/ended, ≤ 3 names, no arguments) with message tests. Write the failing `host/test/it/terminal_activity_test.dart` rows (Shell at its prompt … Unknown terminal id, Too many terminals), then implement the host terminal-service activity read: 1 s deadline, one read in flight per host, test faults for an unreadable image and a slow table. Verify: those map rows are green.

## 3. Busy-terminal close rule on the desktop

- [ ] 3.1 Replace the synchronous `warnsOnClose` with `Future<Map<String,String>> warningsFor(List<String> paneIds)` across `ViewCloser`, `WorkbenchController.requestClose`, the agent and terminal controllers and `profiles_dialog.dart`. Terminals query `terminal/activity` and name programs; unknown activity warns *may be running programs*; a starting terminal closes silently. Rewrite the busy fixtures in `terminal_test.dart`, `workbench_test.dart` and the agent-and-terminal tab test. Verify: the terminal-sessions and workbench-layout map rows are green, and the rows marked green still pass.

## 4. Draft store on the host

- [ ] 4.1 Write failing host tests for the draft store worker: `drafts.sqlite` opened after reconciliation starts; draft schema v1; `journal_mode=DELETE`, `synchronous=EXTRA` and `secure_delete=ON` read back and verified; a hot journal rolled back on open; ≤ 16 pending operations; 5 s deadline; *not responding*; `draftStoreReady`. Verify: they fail for the missing worker.
- [ ] 4.2 Implement the draft worker isolate and `AgentService` integration: `agent/draftSave` (stored revision in acknowledgements and `stale-revision` replies, `draft-too-large`, `draft-cap`, `unknown-session`), `agent/draftLoad`, `agent/draftReset` (synchronous reservation, old-worker exit before delete, one successor, `draft-store-in-use`) and `agent/draftStoreReady`, with protocol types and capability gating. Verify: the draft rows in `draft_store_test.dart` for bounds, stalls, reset and stale replies are green.
- [ ] 4.3 Implement the prompt send order: validate, then commit the draft change (removal when unsynced or when stored ≤ r; tombstone at max(stored, r)), then dispatch. A failed commit is refused `store-error` and a deadline or disabled store is refused `draft-unavailable`, both before dispatch; Retry sets neither field. Add the profile-file canary scan helper (all files under the profile, including the stores, journals and host logs). Verify: the canary, removal, unsynced-send and disabled-store rows are green.
- [ ] 4.4 Measure draft save and removal latency (`EXTRA`: journal, database and directory syncs) on the Windows dev machine and in CI, and record it in the ADR 0014 evidence and the architecture bound row. Verify: the numbers are recorded; a cost above 100 ms per save reopens D4.

## 5. Drafts on the desktop

- [ ] 5.1 Write failing `desktop/test/draft_test.dart` rows, then implement `DraftSaver` (500 ms quiet, 2 s maximum age, one in flight plus one coalesced, 10 s deadline, ≤ 8 across links), revision sync, the submission guard, re-save after a refusal, the `draftStoreReady` retry, one link per session id, restore through `draftLoad` (≤ 8 at a time, late loads never replace typed text), *New session* starting empty, unsaved-draft close confirmations, *Draft not saved* / *Draft not loaded* reasons, and the **Reset draft storage** action with its confirmation. Verify: every `draft_test.dart` row is green.

## 6. Previous exit

- [ ] 6.1 Store v6 migration adding `host_instance.exit_kind`, with a `migrations_test.dart` case. Then write the failing `previous_exit_test.dart` rows, add `app/quit` and `app/previousExit` with the `lifecycle` capability (`lifecycle_messages_test.dart`), and implement: write `exit_kind` in `_finish` only after `app/quit` plus an `inputClosed` close; snapshot the previous instance at lock time, before reconciliation. Verify: the execution-host and capability rows are green.
- [ ] 6.2 Show the previous-exit notice in `workbench_page.dart` / `cleanup_list_view.dart` (*Kumiko did not close normally last time*, the cleanup outcome, *Show cleanup list*). Verify: the `cleanup_list_test.dart` rows are green.

## 7. App exit coordinator

- [ ] 7.1 Write the failing `desktop/test/exit_test.dart` rows, then implement `ExitCoordinator` and the exit dialog in `main.dart` / the workbench. Collect affected items (agents, busy or unknown terminals, unsaved composers after the quit flush); poll activity every 1 s; per-item Stop; failed Stops kept; the bulk action stating consequences; Cancel; a second quit focusing the dialog; the layout frozen during exit; host-loss handling; a ≤ 2 s quit flush shared with the layout; `app/quit` before closing. Verify: every `exit_test.dart` row is green.
- [ ] 7.2 Update the desktop integration quit and reopen tests to expect the cancellable dialog when work is running, and add `desktop/integration_test/exit_reopen_test.dart` (stopped panes reopen in place, drafts return on reopen). Verify: these pass locally on Windows and in CI.

## 8. Kill test, M1 walk and integration checks

- [ ] 8.1 Extend `host/test/it/lifecycle_test.dart`: a stand-in desktop opens a real terminal running a child program and a fake-ACP agent session and is killed; assert that no host, shell, child or adapter process remains. Add the OS-required-exit and unendable-unit rows. Verify: the test passes on all three CI OSes.
- [ ] 8.2 Write `openspec/changes/app-exit-and-reopen/m1-walk.md`. List every M1 exit criterion per OS with its result, verifier, date and evidence. Run the Windows user items with the user. Record the Linux and macOS user items `unverified` (user decision, 2026-11-02), and record the script-executable and resident-helper shells, plus the fact that no real power cut was tested. Verify: every criterion has a row, and none reads pass without evidence.
- [ ] 8.3 Integration check: run the full test suites (`dart test` in each package, `flutter test` and the integration tests for the desktop) and `openspec validate app-exit-and-reopen --strict`. Confirm every test-map row is green. Verify: CI is green on all three OSes.
