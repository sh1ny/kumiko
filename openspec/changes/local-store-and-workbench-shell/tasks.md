# Tasks

## Test map

Test locations:
- `domain`: `packages/domain/test/layout_test.dart` (pure model, operations, bounds, codec).
- Host: `packages/host/test/store/migrations_test.dart` (migration), and `packages/host/test/it/workbench_test.dart` / `workspace_test.dart` (the real host executable through the desktop stand-in, with test faults from `tool/kumiko_host_test.dart`).
- Desktop: `packages/desktop/test/workbench_test.dart` (widget tests over the scripted `HostLink` and a fake `FolderPicker`), and `packages/desktop/integration_test/workbench_reopen_test.dart` (real app and bundled host).

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| workbench-layout → First launch opens Personal without prompts | Fresh profile | packages/desktop/integration_test/workbench_reopen_test.dart | fresh profile opens Personal with one empty group and no prompt | red |
| workbench-layout → First launch opens Personal without prompts | Host still reconciling | packages/desktop/test/workbench_test.dart | workbench and layout show while the host reconciles | red |
| workbench-layout → Tab groups split and tabs move without changing their binding | Move a tab to another group | packages/domain/test/layout_test.dart; packages/desktop/test/workbench_test.dart | move keeps tab id and workspace binding; dragging a tab to another group keeps its binding | red |
| workbench-layout → Tab groups split and tabs move without changing their binding | Close the last tab of a split group | packages/domain/test/layout_test.dart | closing the last tab of a split group removes the group and its split | green |
| workbench-layout → Tab groups split and tabs move without changing their binding | Split at the group limit | packages/domain/test/layout_test.dart; packages/desktop/test/workbench_test.dart | split refused at 16 groups; split action reports the group limit | red |
| workbench-layout → Each tab group has a labeled click launcher | Open a view from an unfocused group | packages/desktop/test/workbench_test.dart | + in an unfocused group opens the view there bound to that group's context | red |
| workbench-layout → Each tab group has a labeled click launcher | Launcher in a group with no workspace context | packages/desktop/test/workbench_test.dart | launcher without context marks workspace-needing kinds and offers Open folder | red |
| workbench-layout → Each tab group has a labeled click launcher | Tab limit reached | packages/domain/test/layout_test.dart; packages/desktop/test/workbench_test.dart | open refused at 128 tabs; launcher reports the tab limit | red |
| workbench-layout → Opening an open item focuses it | Overview already open in another group | packages/domain/test/layout_test.dart | open-or-focus focuses the existing item tab in another group | green |
| workbench-layout → Opening an open item focuses it | Item's tab was closed | packages/domain/test/layout_test.dart | open-or-focus after close creates a tab in the launcher's group | green |
| workbench-layout → Workspace selection focuses existing work without retargeting | Workspace with open tabs | packages/domain/test/layout_test.dart | select workspace focuses its most recent tab and keeps all bindings | green |
| workbench-layout → Workspace selection focuses existing work without retargeting | Workspace with no tabs | packages/domain/test/layout_test.dart | select workspace without tabs sets the focused group context only | green |
| workbench-layout → A tab's workspace binding never changes | Binding after rearrangement and restore | packages/domain/test/layout_test.dart; packages/host/test/it/workbench_test.dart | no operation changes a tab's binding (all ops); binding survives save, host restart and load | red |
| workbench-layout → A tab's workspace binding never changes | Bound workspace becomes unavailable | packages/desktop/test/workbench_test.dart | tab bound to an unavailable workspace keeps its binding and shows unavailable | red |
| workbench-layout → The left sidebar collapses without changing work | Collapse and expand | packages/desktop/test/workbench_test.dart | collapsing and expanding the sidebar keeps groups, tabs and focus | red |
| workbench-layout → The left sidebar collapses without changing work | Collapsed state survives reopen | packages/domain/test/layout_test.dart; packages/desktop/test/workbench_test.dart | codec round-trips sidebar state; collapsed sidebar is restored from load | red |
| workbench-layout → Layout is saved through the host and restored on reopen | Quit and reopen | packages/desktop/integration_test/workbench_reopen_test.dart | quit and reopen restores groups, split, ratio, tabs and focus | red |
| workbench-layout → Layout is saved through the host and restored on reopen | Closed tab stays closed | packages/host/test/it/workbench_test.dart | a closed tab is absent after save, host restart and load | red |
| workbench-layout → Layout is saved through the host and restored on reopen | Desktop killed after a change | packages/host/test/it/workbench_test.dart | saved layout survives killing the desktop stand-in | red |
| workbench-layout → Layout is saved through the host and restored on reopen | Desktop killed during continuous changes | packages/desktop/test/workbench_test.dart | continuous changes are saved at least every 2 s (fake clock) | red |
| workbench-layout → A failed layout save is visible | Store write fails | packages/host/test/it/workbench_test.dart; packages/desktop/test/workbench_test.dart | injected save failure returns store-error and keeps the stored revision; Layout not saved notice with reason | red |
| workbench-layout → A failed layout save is visible | Host does not answer a save | packages/desktop/test/workbench_test.dart | save without answer fails after 10 s and frees the slot | red |
| workbench-layout → A failed layout save is visible | Retry succeeds | packages/desktop/test/workbench_test.dart | Retry stores the layout and clears the notice | red |
| workbench-layout → A layout that cannot be restored is reported, not hidden | Invalid saved layout | packages/host/test/it/workbench_test.dart; packages/desktop/test/workbench_test.dart | invalid stored layout loads as restoreError with workspaces; empty layout with restore notice | red |
| workbench-layout → A layout that cannot be restored is reported, not hidden | Unknown view kind | packages/domain/test/layout_test.dart; packages/desktop/test/workbench_test.dart | unknown kind round-trips unchanged; unsupported view tab names the kind | red |
| execution-workspaces → A local directory opens as a workspace | Open a checkout | packages/host/test/it/workspace_test.dart; packages/desktop/test/workbench_test.dart | open returns canonical path and identity; picked folder appears and becomes group context | red |
| execution-workspaces → A local directory opens as a workspace | Directory is not a repository | packages/host/test/it/workspace_test.dart | plain directory opens as a workspace | red |
| execution-workspaces → A local directory opens as a workspace | Picker cancelled | packages/desktop/test/workbench_test.dart | cancelled picker adds nothing | red |
| execution-workspaces → Opening a directory that is already open focuses its workspace | Same directory through another path | packages/host/test/it/workspace_test.dart | link or junction to an open directory returns it as existing | red |
| execution-workspaces → Opening a directory that is already open focuses its workspace | Same path, directory replaced | packages/host/test/it/workspace_test.dart | replaced directory at the same path keeps the id and updates identity | red |
| execution-workspaces → A failed open is reported and adds nothing | Directory vanished before resolution | packages/host/test/it/workspace_test.dart | missing path is refused target-unavailable and adds no row | red |
| execution-workspaces → A failed open is reported and adds nothing | Resolution does not answer | packages/host/test/it/workspace_test.dart | hung resolution is refused resolve-timeout while control keeps answering | red |
| execution-workspaces → A failed open is reported and adds nothing | Workspace limit | packages/host/test/it/workspace_test.dart | 65th open is refused workspace-cap | red |
| execution-workspaces → Saved workspaces are checked again on every start | Directory missing at reopen | packages/host/test/it/workspace_test.dart | load returns checking then workspace/changed unavailable for a missing directory | red |
| execution-workspaces → Saved workspaces are checked again on every start | Older check finishes after a newer one | packages/host/test/it/workspace_test.dart | older resolution finishing last is not applied | red |
| execution-workspaces → Saved workspaces are checked again on every start | Check finishes after its timeout | packages/host/test/it/workspace_test.dart | late completion after timeout changes nothing | red |
| execution-workspaces → Saved workspaces are checked again on every start | Directory back | packages/host/test/it/workspace_test.dart | Check again after restore reports available | red |
| execution-workspaces → Cleanup-unresolved state is shown on the workspace | Unresolved workspace at startup | packages/host/test/it/workspace_test.dart; packages/desktop/test/workbench_test.dart | workspace record counts unresolved groups; sidebar badge opens filtered cleanup list | red |
| execution-workspaces → Cleanup-unresolved state is shown on the workspace | Unresolved units from a replaced directory | packages/host/test/it/workspace_test.dart | cleanup/list workspace filter pages old identities at the same path | red |
| execution-workspaces → Cleanup-unresolved state is shown on the workspace | Cleanup confirmed | packages/desktop/test/workbench_test.dart | cleanup-only list update clears the badge with an unchanged seq | red |
| execution-workspaces → A workspace without open tabs can be removed | Remove an unused workspace | packages/host/test/it/workspace_test.dart | remove deletes the row only and the directory is untouched | red |
| execution-workspaces → A workspace without open tabs can be removed | Removed workspace was a group's context | packages/host/test/it/workspace_test.dart; packages/desktop/test/workbench_test.dart | remove clears stored contexts at the next revision; in-memory context cleared | red |
| execution-workspaces → A workspace without open tabs can be removed | Removal during a check | packages/host/test/it/workspace_test.dart | check in flight at removal publishes nothing | red |
| execution-workspaces → A workspace without open tabs can be removed | Workspace still has tabs | packages/host/test/it/workspace_test.dart; packages/desktop/test/workbench_test.dart | remove refused workspace-in-use; Remove disabled while tabs are bound | red |

Mechanical checks (no scenario row): `dart analyze --fatal-infos` / `flutter analyze` clean, `dart run tool/audit_dependencies.dart` passes with `file_selector`, `openspec validate local-store-and-workbench-shell --strict`, and the release-contract test still shows no `test.*` capability and the new `workbench` capability.

## 1. ADR and architecture

- [x] 1.1 Write `docs/adr/0009-workbench-layout-document.md` (Status: accepted, today's date) recording design D1, D7 and D10: a desktop-authored snapshot validated by the host, the `format` version converted only by store migrations, the tab shape (`kind`, immutable `workspace`, `item`, `state` ≤ 4 KiB), unknown-kind passthrough, and revision-guarded saves. Add its row to the in-force index in `openspec/architecture.md`, the new resource-bound rows (layout document, groups and tabs, workspaces, resolver slots and timeout, save debounce, dirty age and deadline), and the layout detail in the state-ownership row. Verify: the files render and the index lists 0009.

## 2. Layout model in `domain`

- [x] 2.1 Write failing `packages/domain/test/layout_test.dart` for the domain rows of the test map: split and group limit, move, close-last-tab, open-or-focus, select workspace (with and without tabs), tab limit, binding immutability across every operation, `clearContext`, sidebar state, codec round-trip including unknown kinds, and validation bounds (document 256 KiB, `state` 4 KiB, string lengths, ratio 0.1-0.9, dangling context repair). Verify: `dart test` in `packages/domain` fails on missing symbols.
- [x] 2.2 Implement the layout model, operations, bounds constants, validation and JSON codec in `packages/domain/lib/src/layout/` and export them from `domain.dart` (no `dart:io`). Verify: `layout_test.dart` passes; flip the domain rows green.

## 3. Store schema v2 and protocol messages

- [ ] 3.1 Write failing tests: a migration test in `packages/host/test/store/migrations_test.dart` (v1 store with ledger rows migrates to v2, keeps every `unit` and `host_instance` row, and creates `workspace`, `working_set` and the `personal` row with a NULL layout; a failed v2 step leaves v1), and message round-trip tests in `packages/host_protocol/test/workbench_messages_test.dart` for every new message and error reason. Verify: they fail.
- [ ] 3.2 Add the v2 migration step to `schemaMigrations` (design D3). Add the `workbench` capability, the six methods with their `methodCapability` entries, the `workspace/changed` notification, the message classes (records carry `seq` and `cleanup: {groups}`, responses carry `cleanupRevision`), the `workspace` filter on `CleanupListParams`, and the new error codes to `host_protocol`. Verify: both tests pass, and `dart analyze --fatal-infos` is clean.

## 4. Host workspace service

- [ ] 4.1 Add test faults in `host_faults.dart`, reachable only through `tool/kumiko_host_test.dart`: resolve delay or hang per path, a hook that releases a hung resolution, layout save failure, and layout save hang. Extend the release-contract test so the release host still rejects them and advertises `workbench`. Write failing `packages/host/test/it/workspace_test.dart` for every host row of `execution-workspaces`: open, link or junction dedupe (a symlink on POSIX, a junction on Windows), replaced directory, missing path, timeout while a control round-trip still answers, cap 65, load with `checking` followed by `workspace/changed`, reversed completion, late completion after timeout, Check again, cleanup count and the filtered `cleanup/list` over old identities, remove, removal during a check, and `workspace-in-use`. Verify: they fail against the current host.
- [ ] 4.2 Implement `WorkspaceResolver` (`Isolate.run`, 4 slots, 5 s timeout, `busy`, all-slots-hung completion as *unavailable: host busy resolving folders*), the `WorkspaceService` (D4 match and refresh, the D5 sequence and `appliedSeq` rules, the cap), `Ledger.unresolvedGroupsFor` with its count variant, and the `cleanup/list` workspace filter. Wire the `workspace/*` methods into `Host._onRequest` and advertise `workbench` from every host. Verify: `workspace_test.dart` passes on the local OS; flip its rows green after CI passes on Windows, Linux and macOS.

## 5. Host workbench service

- [ ] 5.1 Write failing `packages/host/test/it/workbench_test.dart`: save then load across a host restart (bindings, closed tab absent); save survives killing the desktop stand-in; `stale-revision` for an equal or lower revision; injected save failure keeps the stored revision; an invalid stored row loads as `restoreError` with workspaces; a dangling context is repaired at load; a binding to an unknown workspace is refused `layout-invalid`; an oversized document is refused; `workspace/remove` clears stored contexts and raises the revision in one transaction, and refuses when a tab binds the id. Verify: they fail.
- [ ] 5.2 Implement `WorkbenchService` (`workbench/load` and `workbench/save` with `domain` validation, the revision guard and the context repair) and the transactional remove (D11). Verify: `workbench_test.dart` and the remove rows of `workspace_test.dart` pass; flip their rows green after CI passes on three OSes.

## 6. Desktop workbench

- [ ] 6.1 Add `file_selector` to `packages/desktop/pubspec.yaml` behind a `FolderPicker` interface, and extend `HostLink`, `launcher_link.dart` and `test/support/fake_host.dart` with the new methods, the `workspace/changed` stream and `cleanupRevision`. Request the `workbench` capability, and map a host without it to the incompatible phase. Verify: `dart run tool/audit_dependencies.dart` passes, `flutter analyze` is clean, and the existing desktop tests still pass.
- [ ] 6.2 Write failing `packages/desktop/test/workbench_test.dart` for every desktop row of the test map, using a fake clock for the debounce (500 ms), dirty age (2 s) and deadline (10 s). Verify: they fail.
- [ ] 6.3 Implement `WorkbenchController` (domain operations, applying records by `seq` and cleanup by `cleanupRevision`, and the remove flow with flush and `clearContext`), `LayoutSaver` (the D6 state machine, revisions, late responses), and the UI: left sidebar with Personal, workspaces, availability, cleanup badge, Check again, Remove and collapse; split tab groups with drag to move and resizable ratios; the per-group + launcher; Workspace overview and unsupported-view tabs; and the save and restore notices. `KumikoApp` shows the workbench once connected and keeps the host-status page for the other phases. Hook the flush into `onExitRequested` before `shutdown()`. Verify: `workbench_test.dart` passes; flip its rows green.

## 7. Integration

- [ ] 7.1 Write and pass `packages/desktop/integration_test/workbench_reopen_test.dart`: on a fresh temporary profile, the workbench shows Personal with no prompt. Open a temporary folder, arrange tabs in two split groups and quit through the app's exit path. A second app launch on the same profile restores groups, split direction and ratio, tabs, active tabs and the focused group. Add it to CI next to `launch_test.dart`. Verify: CI passes on Windows, Linux and macOS; flip the two integration rows green.
- [ ] 7.2 Full check: `dart analyze --fatal-infos`, `flutter analyze`, all package tests, the dependency audit, and `openspec validate local-store-and-workbench-shell --strict`, all passing in CI on three OSes, with every test-map row green. Verify: a green CI run link is recorded in the task commit.
