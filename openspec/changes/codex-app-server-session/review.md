# Review

## Metadata

- **Round:** 8.
- **Prior round:** Round 7 returned APPROVE_WITH_CHANGES; its focused recheck recorded all required planning changes applied.
- **Reviewer:** Codex, fresh-context, read-only adversarial design reviewer.
- **Files reviewed:** `AGENTS.md`; change `design.md`, `specs/agent-tool-access/spec.md`, `tasks.md`, `proposal.md` and `review.md`; qualification record’s ninth-attempt section; `native_home_audit.dart`, `windows_find_data.dart`, `tool_file_audit.dart`; qualification helper selection, disclosure, binding and counter handling. Supporting repository socket implementation/tests were also inspected.
- **Method:** Repository reads only. No modifications, builds, tests, native Codex execution, provider calls or native Codex home access.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. The governing requirement still excludes v3.**

- **Evidence:** `openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:92` permits wider coverage **only** for manifests naming v1 or v2. Its bound enumeration at `:108` likewise omits v3. The new socket scenario at `:120` expressly permits v3, and baseline refusal at `:110` already includes it.
- **Consequence:** Implementing the socket scenario violates the requirement’s governing selection restriction. The requirement also leaves v3’s metadata ceiling implicit despite explicitly enumerating the other wider modes.
- **Required correction:** Admit v3 in the governing requirement and bound enumeration, with the narrow socket exception and inherited v2 storage limits stated consistently. Preserve the earlier selections’ meanings.

**M2. Windows socket acquisition coverage can be skipped without establishing the exception’s real behavior.**

- **Evidence:** `openspec/changes/codex-app-server-session/tasks.md:462` requires acquisition through the real find-data path, but `:464` qualifies the real Windows socket fixture with “where the platform allows binding one.” Unlike the link acquisition requirement at `:434`, it does not expressly prohibit satisfying acquisition coverage with injected records alone.
- **Grounding:** The existing observation operation reads link target text (`packages/host/lib/src/agent/codex/native_home_audit.dart:263`). Socket support must bypass that operation while retaining real find-data verification. The repository’s existing Unix socket creation path is selected only outside Windows (`packages/host/lib/src/agent/tools/tool_endpoint.dart:42`); its stale-socket fixture is likewise POSIX-only (`packages/host/test/it/tool_endpoint_test.dart:130`).
- **Consequence:** A test using an unsuitable binding API could skip on the target Windows machine while injected observations pass. That would leave the exact filesystem classification and acquisition behavior motivating v3 unverified.
- **Required correction:** Specify an owned Windows AF_UNIX fixture strategy, including a test-only native binding helper if necessary. Distinguish unsupported OS/filesystem capability from unsupported test API. A skipped acquisition fixture must leave Windows acquisition coverage explicitly unverified rather than turn the entire socket row green.

### Suggestions

**S1. Make socket acquisition stability explicit.**

- **Evidence:** `design.md:165` requires immediate re-observation for links, while the socket-specific acquisition contract at `:172` lists unavailable, failed and non-AF_UNIX observations without explicitly mentioning instability.
- State that socket acquisition also rejects differing immediate observations, without reading a target, and add deterministic tag/type/metadata-change cases to `tasks.md:462`. This would remove ambiguity when adapting the existing target-reading operation.

**S2. Add v3 host-boundary cases to the scenario map.**

- **Evidence:** `tasks.md:89` maps sockets only to inventory and helper tests; `:468` nevertheless requires v3 echo and binding validation. Existing binding coverage remains green at `:86`.
- Add v3 preparation/result echoes, once-only binding, baseline refusal and release denial to the host integration coverage. Inventory and helper tests cannot establish that the host accepts and preserves the new selection correctly.

The socket exception is otherwise coherent within the stated persistence detector. A verified socket endpoint is not regular-file content to scan; IPC traffic is outside this filesystem-content audit. Counting socket churn therefore need not make the audit incomplete. The design explicitly retains protected-name refusal and rejects transitions to other entry kinds (`design.md:174`), preventing an endpoint classification from excusing an observed regular-file replacement. AF_UNIX tag verification is a suitable classification check within the existing observation-time assumptions; an extension or Dart listing class alone would not suffice.

The amendment also preserves v2/v1/legacy meanings, requires canonical v3 disclosure, and prohibits emitting socket identifiers (`design.md:171`, `:173`, `:177`). No additional false-clean path was established from the reviewed planning text. This assessment does not prove continuous filesystem immutability or runtime implementation correctness.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Reconcile the governing selection restriction and metadata-bound enumeration with v3, explicitly preserving inherited storage limits and earlier selections’ behavior (M1).
2. Define real Windows AF_UNIX acquisition coverage and its fixture strategy. Record unsupported-platform skips as unverified acquisition coverage; injected records alone must not satisfy that coverage (M2).

## Focused Recheck (Round 8 Required Changes)

### Required Change 1 — Applied

The governing requirement now explicitly admits owner-approved v1, v2 and v3 selections, limits socket handling to v3, preserves earlier selections’ meanings and retains byte, file, confinement and no-follow limits (`openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:92`). The bound enumeration explicitly assigns v2 and v3 the 65,536-entry ceiling and retained-string budget (`openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:108`).

The socket scenario makes v3 behave as v2 with the specified socket exception (`openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:121`). The design expressly inherits v2’s entry ceiling and retained-string budget (`openspec/changes/codex-app-server-session/design.md:172`), whose concrete storage limits remain defined at `openspec/changes/codex-app-server-session/design.md:159`. Protected-name refusal and entry-kind transition refusal remain explicit (`openspec/changes/codex-app-server-session/design.md:174`; `openspec/changes/codex-app-server-session/specs/agent-tool-access/spec.md:122`).

### Required Change 2 — Applied

The design specifies a real Windows AF_UNIX socket bound by the test in an owned short temporary folder, identifies a Dart binding strategy and permits a test-only native helper if that API cannot bind it (`openspec/changes/codex-app-server-session/design.md:175`). This provides an alternative to treating an unsupported test API as proof of unsupported machine capability.

The tasks require observation through the real find-data path without reading a target (`openspec/changes/codex-app-server-session/tasks.md:462`) and through real `FsNativeInventoryIo` against the owned socket fixture (`openspec/changes/codex-app-server-session/tasks.md:466`). Both design and tasks explicitly leave Windows acquisition unverified after a binding skip and prohibit injected records alone from satisfying coverage or making the row green (`openspec/changes/codex-app-server-session/design.md:175`; `openspec/changes/codex-app-server-session/tasks.md:468`).

### S1 — Applied

Socket acquisition now reads the find-data record twice immediately, never reads a target, and rejects differing observations as a content-free `linkObservation` error (`openspec/changes/codex-app-server-session/design.md:172`). The tasks explicitly require immediate re-observation cases covering tag, type and metadata changes, alongside missing records and missing reparse-point attributes (`openspec/changes/codex-app-server-session/tasks.md:462`).

### S2 — Applied

The socket scenario map now includes `packages/host/test/it/codex_tools_test.dart` and keeps the socket row red (`openspec/changes/codex-app-server-session/tasks.md:89`). The socket amendment explicitly requires host-boundary coverage for v3 preparation and result echoes, once-only binding, baseline refusal and release denial (`openspec/changes/codex-app-server-session/tasks.md:476`).

No new inconsistency was established in the amended planning text. The existing green rows do not establish v3 completion: the socket row remains red, and the amendment expressly requires its new coverage before completion (`openspec/changes/codex-app-server-session/tasks.md:89`; `openspec/changes/codex-app-server-session/tasks.md:455`). These findings verify planning corrections only; no implementation, runtime behavior or Windows acquisition result was verified.

CHANGES_APPLIED: yes

## Rebuttals