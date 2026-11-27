# OMP RPC qualification on Windows

[The observation record](omp-rpc-windows.json) covers exact executable versions, not an allowlist. Read the results with `mise run audit`. CI and default tests only validate the record and exercise scripted peers. They do not launch real OMP or contact a model provider. Do not infer qualification for another version, Linux or macOS, or use this record to close M2 on its own.

## Prepare without starting OMP

1. Get the owner's approval to build. Run the local gaming guard before a build, full analysis or full tests. Wait if a game is running. Do not start a provider session during preparation.
2. Build on Windows from a known Kumiko revision. From the repository root, run `mise run build:host`. In `packages/desktop`, run `mise exec -- flutter build windows --release`. From the root, bundle that host with `mise exec -- dart run tool/bundle_host.dart --skip-build`. Use `packages/desktop/build/windows/x64/runner/Release/kumiko.exe` and its own bundled `host/bin/kumiko_host.exe`. Record the source revision and check the two executable identities in the private plan. Do not use a fixture host.
3. Create a disposable, ordinary directory outside all real projects. Give it two synthetic workspaces, A and B, a fresh `LOCALAPPDATA` base, native session storage, an OMP overlay, and a private place for the approval plan and local notes. Make the runtime's working directory the selected scratch workspace. Launch the desktop as a direct child of the operator's process with this absolute `LOCALAPPDATA`; do not change the user's environment or profile. Keep its process handle. The host, OMP version probe and native process inherit the redirect unless an explicit profile environment override applies to the native process.
4. Identify the installed native executable with `--version`; this is not a runtime test. Check the actual launch environment and version-matched source before approval. Resolve native config, authentication, cache, remote storage, root session and child artifact locations with non-secret metadata. The scratch attempt must use the same native sign-in resolution as the owner's normal OMP without copying any credentials, and must keep the root and child journals in scratch. The provider can refresh its existing sign-in. Do not sign in, write the owner's settings, or inspect credential contents. If the safe inputs or locations cannot be established, stop here.
5. Create a qualification-only runtime profile in the scratch desktop. Use an absolute native `omp.exe`, `--mode rpc`, an exact model matching the approved account for both root and child, and an explicit `--session-dir` and `--config` pointing to scratch. Check the installed version's supported flags against the [Continue argument rules](../../docs/adr/0019-omp-history-child-view-and-shutdown.md). Use a per-run overlay and verified native switches to disable unrelated tools, extensions, context files, skills, rules, prewalk, fallback, background provider features, telemetry, memory and remote session storage. Preserve native approval behavior; select a native policy for this profile that asks for the planned synthetic operation. Inspect the exact root tool selection, the child's restricted tool set and depth, and the model route. Do not assume the root's tool limit or model selection pins the child. Never call a scratch workspace or an approval mode a sandbox.
6. Freeze a private plan with an attempt identifier, exact version, executable and build identities, absolute scratch targets, redirected roots, profile argv and overlay identity, exact model, planned prompts, owner clicks and account side effects. Send that plan to the owner and obtain an explicit reply for this run; the build reply is not enough. Use the SHA-256 of the approved plan's exact UTF-8 bytes as the approval reference. Recheck the gaming guard, approved bytes, actual executable and configuration identities, targets, effective model and prompt list. Create a new exclusive spent marker for that digest in the scratch attempt before the first OMP start. If the marker exists or the evidence already contains the digest, do not launch. A changed input, scenario or extra prompt needs fresh approval. A failed start does not make the approval reusable.

## Walk the release desktop

Use at most eight submitted root prompts and one short child assignment. The owner needs to watch the app and operate the permission, Stop, close, quit and Continue controls as agreed in the plan. Tool calls can cause additional provider requests. Do not add prompts or retry a missed transition. Wait for actual app events; use a generous time limit only to stop a hung walk.

For process evidence, identify the desktop's descendants by parent-PID chain while they are live. Compare creation times to identify the same parent and child processes and open each required handle immediately. Associate each runtime tree with A or B before close. Retain exit codes from the owned handles, not process-name matches or model output. An exit handle proves process settlement, not native history durability.

| Step | Action and pass evidence |
|---|---|
| 1 | Open A and start OMP. `launch` passes when the pane is Idle before a prompt and displays `omp-rpc` with the exact approved version. Send a short tool-free numbered reply request. `prompt` passes when the user event appears once and the turn ends. `streaming` passes when visible text grows before Idle and the final text does not repeat the deltas. |
| 2 | Ask for one harmless operation on a named scratch fixture. Choose **Deny** only after checking the native tool, input and intended target. `denial` passes when the intended operation does not happen and the actual outcome is visible. If using a write, check the scratch file stayed absent or unchanged. Do not accept a model report as proof. |
| 3 | Change the workspace selection to B and return to A's original chat. Ask it for one approved synthetic operation and one `kumiko_session_info` call. Approve only the exact reviewed operation, once, after inspecting the complete card. `one-shot approval` passes when only the one-shot and denial choices are offered and the authorized action takes effect. `tool activity` passes when a native card reflects the actual execution and terminal result. `kumiko tool call` passes when the real tool result agrees with host facts and the UI reports connected after its first use. `immutable target` passes when the returned target is A and the underlying session is unchanged. An assistant claiming it called the tool is not proof. |
| 4 | Ask A for longer but bounded tool-free text. Press **Stop** while the reply is growing. `Stop` passes only if the pane reports **Stopped**, the same process remains live, and it accepts the next approved prompt. Record **Finished before Stop** or **Stop not confirmed** as seen; neither is confirmed interruption. Do not kill OMP as a substitute. |
| 5 | Use the next A prompt for the one approved child assignment. Open the child row and inspect its attributed content, independent of the parent's transcript. The parent's task card or result summary is allowed. `read-only child pane` passes only with the expected child model and content, and no Send, approval, Stop, steering or Continue controls. Leave the pane open for the reopen check. Record child history availability and delegated Stop separately if observed. Missing child model proof is unverified; a different observed model fails the row. |
| 6 | Start B and request a harmless operation. While its permission is pending, try to close the pane and cancel. Then confirm close while the work is still affected. `close` passes when the first choice preserves the work, the confirmed close removes the pane, its owned handles signal, and A remains available. Do not approve the held operation to make close proceed. |
| 7 | Leave another approved-plan permission request pending in A. Try to quit, observe the affected-work warning, cancel, then confirm **Stop processes and close**. Wait for all owned handles and reopen with the same scratch profile. `ordinary quit` passes when the runtime exits 0, the desktop and host settle, the prior root journal is intact, and reopen shows the same parent as **Saved, not running** and an inert child pane. An unconfirmed-save or cleanup warning prevents this pass. Record it separately and do not claim a save because processes exited. |
| 8 | Press **Continue** explicitly. Compare the bounded scratch journal header and record identity with the original target and session. `exact Continue` passes only for the original session and target, without a replacement journal or new prompt or tool record. `history restore` passes if the supported messages and tool history shown in the parent match the expected chronological history before any live output. A truthful history-unavailable notice is not a history-restore pass. Only send a final `kumiko_session_info` prompt if it was in the approved plan. Check that the callback still reports the same Kumiko id and target. |

Close the owned session and desktop, then wait for the handles. If settlement cannot be confirmed, keep the scratch data that may be in use and report the unresolved cleanup. Do not kill processes by name or delete an open workspace. Preserve the spent marker until the attempt record is saved. Delete the throwaway workspaces, profile, native journals, overlay and notes after the owned processes have settled and the sanitized record is written.

## Record the result

The record is a JSON array. Each attempt has `id` and `approval.approvedAt` as UTC ISO 8601 timestamps, `approval.sha256` as the lowercase approval digest, `version` as the exact version without `omp/`, `os` as `windows`, `revision` as the full Kumiko commit, `model` as the approved `provider/model`, and `items`. Each required item in the table appears once as `{ "item": "...", "result": "pass|fail|unverified", "notes": "..." }`. Use the case-sensitive item names in the table, one single-line note of up to 512 UTF-8 bytes per row, and a fresh digest for any new attempt. The audit prints FAIL if any required row failed, INCOMPLETE if any remained unverified and none failed, or PASS if they all passed in the same attempt. A valid negative record does not fail the offline audit. A malformed or missing file does. The audit checks the receipt format, not the authenticity of the approval or the facts in the notes.

Use `fail` for a contradicted expectation and `unverified` for a missing event or missing proof. Name what happened without including raw prompts, transcripts, diagnostics, screenshots, paths, process and conversation ids, tool payloads or credentials. No fixture run, source review or account sign-in check fills a real row. Keep prior attempts and do not merge their rows. Report a runtime bug to the owner rather than publishing on the upstream repository.

## Differences from the shared contracts

These differences describe Kumiko's implementation. They are separate from what an installed OMP version does in a particular walk.

| Shared contract | OMP behavior or limit |
|---|---|
| Host owns native execution and exposes normalized session events | Private stdio v1 NDJSON, not ACP or JSON-RPC. Peers need `agent` and `omp` for a root. Exact Windows qualification is separate from the contained minimum-version probe and readiness gate. Kumiko does not negotiate OMP v2. |
| Prompt and Stop report actual outcomes | Native prompt admission and its result are distinct. A root result can arrive while children or native work remain active. Root abort or known child cancel acknowledgements do not prove interruption. Unknown or unconfirmed work stays visible. Close is the separate containment action. |
| The user answers interactive requests | OMP's native policy can run tools without asking. Kumiko only offers the recognized one-shot value and Deny on an admitted root turn. Remembered choices, general extension dialogs, generic questions, URL opens and steering are unavailable in the integration. Withdrawal retires the choice without replying. This policy is not a sandbox. |
| Tool activity and application tool access are separate | Root cards use bounded native execution frames and show omissions. Child events cannot alter root cards. An unread OMP callback can wait behind that run's output if the event queue fills. Kumiko tool delivery uses private, root-only `set_host_tools` callbacks under the shared host authorization, not MCP injection, an MCP listener or a transferable grant. Registration is not a successful call. |
| Provider setup is native | OMP uses native credentials and configuration. This walk selects its model in a scratch argv profile, not via provider sign-in management or an in-session model picker in Kumiko. |
| Explicit Continue restores the same conversation, when supported | `omp-history` gates the desktop's Continue and child views. OMP Continue uses the original host-owned locator and checked identity. Kumiko verifies one bounded v1 root snapshot; it tells the user when earlier messages cannot be shown rather than giving a partial replay or substituting a new chat. There is no inferred locator for legacy records. |
| Child work remains owned by the parent | The child pane reuses the live root connection and scopes history to the selected child and run. Missing attribution is withheld. History and live content remain separate. Only the parent can act or Continue. Restored child panes are inert. A read-only child view is not enforcement of a read-only coding role. |
| Close and quit preserve an honest recovery state | Ordinary close and quit give OMP native cancel and EOF grace. Evidence that work stopped, evidence that owned processes exited, and proof that the same session can resume are separate. Forced cleanup, runtime loss and unconfirmed native persistence do not become saves. |

Owner desktop observations and exact-version limits belong below as they occur. The right-side Sessions browser, other operating systems, runtime sign-in failure experiments, structured extension questions and enforcement of the personal read-only coding role are not part of this walk.

## Windows observations

### Attempt 1, OMP 19.2.1

The owner approved `openai-codex/gpt-5.5`. Kumiko showed a readiness-stage
failure: OMP exited 1 and reported that it could not find the selected model.
The attempt stopped with zero submitted prompts. The scratch profile held no
saved agent session and the native journal directory held no files. The
desktop and host exited normally during cleanup. This is startup failure and
cleanup evidence, not a pass for close, ordinary quit or recovery.

Before launch, the folder list held the scratch parent rather than A. The
owner corrected the selection and the scratch runtime was started only in A.
We did not establish why the first folder differed.

The [attempt record](omp-rpc-windows.json) reports **FAIL** for this run.
The owner said the selected model was retired and named `openai-codex/gpt-6.2-sol`
for a future approved attempt. The first failure does not establish a defect
in OMP's RPC behavior and is not replaced by a later result.

### Attempt 2, OMP 19.2.1

The owner approved a fresh attempt on `openai-codex/gpt-6.2-sol`, with new scratch
workspaces and the same packaged release. OMP started in both workspaces.
Prompt completion, reply streaming, Stop, one-shot approval and Deny, native
tool cards, the Kumiko callback, and target retention all passed. The view
scrolled to the end of the first reply; the beginning remained accessible.
The child had the approved model and its own read-only pane with earlier
history. Delegated Stop was not exercised. Cancel preserved B's pending
approval; Confirm closed B without granting it and left A running.

With a permission pending in A, invoking Windows title-bar Close through
computer use exited the app before an affected-work warning or a Cancel
decision could be observed. The desktop and host exited 0, A's OMP process
exited 1, and the host ledger did not mark the exit as a coordinated quit.
The held write did not happen. A's original session record and native journal
header remained, which does not establish a normal save or successful replay.
The run stopped after seven root prompts and one child assignment. There was
no reopen, eighth prompt, Continue, or root history restore.

A later no-model regression reproduced the same exit with a scripted agent
awaiting permission. The native folder picker left an unowned `WorkerW`
window, which made Flutter treat the main window as non-final and skip Dart's
quit handler. The Windows runner now routes main-window Close directly to the
existing coordinator, independent of auxiliary windows.

The [attempt record](omp-rpc-windows.json) reports **FAIL** for this run.
These passes do not qualify the version as a whole. The pane's general
**Load** and **Resume** indicators showed unavailable; that is separate from
the OMP-specific **Continue** flow, which this attempt did not reach.
