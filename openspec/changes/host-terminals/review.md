# Review

## Metadata

- **Round:** 3
- **Prior round:** Round 2 codex APPROVE_WITH_CHANGES, changes applied and accepted; verdict voided by the user's unproven-Linux/macOS amendment
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** `host-terminals/{proposal.md,design.md,tasks.md,specs/*/spec.md}`; `openspec/{roadmap.md,architecture.md}`; ADRs 0001, 0002, 0003, 0006, 0009; main desktop-host-protocol and workbench-layout specs; direction terminal-sessions spec and design D7/D9/D30; `packages/host_protocol/lib/src/*.dart`; host unit manager, settler, host and store; `packages/process_containment/lib/src/*.dart`; domain layout sources; desktop workbench controller and page; dependency audit; review template; supplied Flutter test architecture skill. Round-2 review read as data. Planning review only; no implementation tests run. **Re-check of Required Changes 1-3:** round-3 review and author's Rebuttals read as data; current `openspec/changes/host-terminals/{design.md,tasks.md}` checked against those requirements, with `packages/process_containment/lib/src/{posix_unit,unit_exec}.dart` and `packages/host/lib/src/unit_manager.dart` consulted as source evidence. No new full review or implementation verification performed.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — The qualification tasks still prescribe incompatible adoption rules.**

[Tasks line 11](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:11) describes the checker as requiring recorded passes for every item, including user items on every OS. Task 1.1 requires ADR 0010 to say “every bar item passes on every OS … otherwise escalate”; task 1.2 defines `pass/fail/unverified` cells. These conflict with task 1.3’s permitted `unproven` state and task 6.6’s provisional adoption.

Following those instructions produces either an ADR that rejects the authorized provisional adoption or an unnecessary escalation despite acceptable Windows and scripted results.

The amendment’s substantive rule is coherent: `unproven` is not a failure or a pass, any actual failure blocks adoption, and M1 remains incomplete until its per-OS bar passes. The remaining task instructions must express that same distinction.

**M2 — Natural exit can strand a confirmed-close tab.**

[D9](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:155) and task 7.4 remove a confirmed-close tab only on `terminal/exited {reason: closed}`. However, [the race rule](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:313) allows natural exit to win and merely treats a subsequent `unknown-terminal` as “already ended.”

If the shell exits while its confirmation dialog is open, the desktop can receive `reason: exited` before or during close. No `reason: closed` notification need follow. The prescribed controller therefore leaves the tab—and potentially its group—open after confirmation.

This is reachable through the existing [independent exit watcher](F:/Dev/Orca/Workspace/kumiko/packages/host/lib/src/unit_manager.dart:168). The lifecycle also omits an `exiting → closing` transition, leaving close during credit-stalled final drainage undefined.

**M3 — POSIX shim startup is mistaken for successful shell execution.**

[D2](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:61) extends the existing shim with PTY setup but adds no launch-result handshake. Today, [spawnPosixUnit](F:/Dev/Orca/Workspace/kumiko/packages/process_containment/lib/src/posix_unit.dart:156) returns after starting the shim and reading its start time. Later, [execve failure](F:/Dev/Orca/Workspace/kumiko/packages/process_containment/lib/src/unit_exec.dart:44) prints to stderr and exits with 126/127.

An existing file that cannot execute therefore follows the successful-open/natural-exit path rather than returning the `spawn-failed{osError}` required by D5 and the test-map row at tasks line 66. PTY setup failures have the same ambiguity. Exit status alone cannot distinguish these failures from a successfully launched shell that exits with the same status.

### Suggestions

None.

### Re-check

The findings above are retained from round 3; the following notes record their disposition against the current planning files.

1. **Required Change 1 — Applied as required.** The [Engine bar description](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:11) distinguishes ADOPTABLE checker success from full QUALIFIED status, restricts `unproven` to Linux/macOS user items, and rejects failures and invalid cells. [Tasks 1.1–1.3](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:99) align the ADR, result cells and checker with that rule. [Task 6.6](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:138) preserves every `unproven` entry and provisional adoption; [task 8.3](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:153) preserves and lists those entries and explicitly prohibits M1 closure before QUALIFIED.

2. **Required Change 2 — Applied as required.** [D9](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:157) retains confirmed-close intent across every exit reason, handles an exit already received during confirmation, and keeps cleanup failure visible. [D5](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:102) requires cleanup confirmation before any `terminal/exited`, including natural exits. The [lifecycle](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:209) and [Flow & State Gaps](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:316) define `exiting → closing`, discard queued output and wake drainage independently of credit. [Task 5.4](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:128) requires the host test for close during stalled final drainage; [task 7.4](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:145) requires controller tests for exit during confirmation and before close acknowledgement, including tab/group removal. These address the race exposed by the existing [exit watcher](F:/Dev/Orca/Workspace/kumiko/packages/host/lib/src/unit_manager.dart:168), with controller and service coverage at the appropriate layers.

3. **Required Change 3 — Applied as required.** [D2](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:62) specifies a structured close-on-exec status pipe carrying setup/exec stage and errno, zero-byte EOF as the execution-success signal, a five-second bound, and settlement before throwing. [D4](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:82) withholds open success until execution is confirmed and releases reservations only after settlement. The [failure table](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/design.md:277), [task 2.2](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:106) and [task 5.2](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:126) carry the mechanism and OS-error mapping into implementation instructions. Containment tests explicitly distinguish setup/exec failure from successful execution followed by exit 126 or 127; the [service test-map row](F:/Dev/Orca/Workspace/kumiko/openspec/changes/host-terminals/tasks.md:66) also distinguishes an unrunnable executable from a program exiting 126. This addresses the existing separation between [shim startup](F:/Dev/Orca/Workspace/kumiko/packages/process_containment/lib/src/posix_unit.dart:156) and [exec failure](F:/Dev/Orca/Workspace/kumiko/packages/process_containment/lib/src/unit_exec.dart:44).

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Unify qualification instructions.** Update tasks’ Engine bar description, 1.1 and 1.2 to use the rule from 1.3: passes everywhere except explicitly listed Linux/macOS user items may remain `unproven`; any adopted-candidate failure blocks adoption. Distinguish checker success from full qualification. Preserve `unproven` entries when completing 6.6/8.3, and explicitly require their passes before M1 closes.

2. **Complete close/exit race handling.** Amend D9, the lifecycle, Flow & State Gaps and task 7.4 so a confirmed-close intent survives natural exit and removes the tab after cleanup is confirmed, regardless of which exit reason wins. Define close while `exiting`, including credit-stalled drainage, and retain visible cleanup failure. Add deterministic controller tests for exit during confirmation and exit before close acknowledgement, plus a host service test for close during stalled final drainage.

3. **Confirm POSIX execution separately from shim startup.** Add a bounded structured setup/exec-result mechanism, such as a close-on-exec error pipe, before reporting open success. Preserve the OS error and settle failed units before releasing reservations. Update D2/D4, failure handling and tasks 2.2/5.2. Add containment/service tests distinguishing setup or exec failure from a successfully executed program that exits with 126/127.

CHANGES_APPLIED: yes

## Rebuttals

- **Required Change 1 (unify qualification): fixed — accepted by reviewer.** tasks.md Engine bar description (ADOPTABLE vs QUALIFIED), 1.1 (adoption rule: any fail blocks; provisional while Linux/macOS user items unproven; full qualification before M1 closes), 1.2 (`pass`/`fail`/`unproven` cells), 1.3 (prints ADOPTABLE or QUALIFIED), 6.6 (keeps every `unproven` entry), 8.3 (ADOPTABLE with entries kept; M1 cannot close until QUALIFIED).
- **Required Change 2 (close/exit race): fixed — accepted by reviewer.** design.md D9 "Confirmed close is an intent that survives any exit reason", D5 (every `terminal/exited` only after confirmed cleanup; `closeFailed` for natural exits too), lifecycle `exiting --> closing`, Flow & State Gaps "Close and exit at the same time" (with the required tests); tasks 5.4 (host test for close during stalled drainage) and 7.4 (controller tests for exit during the dialog and exit before the ack).
- **Required Change 3 (POSIX exec result): fixed — accepted by reviewer.** design.md D2 "Exec-result pipe (POSIX)" (close-on-exec status pipe on the shim's original stdout, JSON `{stage, errno}`, 5 s bound, settle before throwing), D4 (open result only after confirmed execution; settle before releasing the reservation), Failure & Visibility spawn row; tasks 2.2 (with tests distinguishing `SpawnFailed` from a program exiting 126/127), 5.2, test-map row "Executable is not runnable".