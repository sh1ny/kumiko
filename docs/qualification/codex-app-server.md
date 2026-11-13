# Codex App Server contract research

## Offline checker and bounded Windows walk procedure

Historical note, superseded by
[Final status for this change](#final-status-for-this-change-task-84-2026-11-13):
when this procedure was first written, two approved real-runtime attempts had
failed before prompts, the second identifying the helper's unsupported
approval-policy override, and no provider-backed capability had been observed.
Later attempts are recorded below; Windows 0.166.0 now passes. The authored checker, auth
projection and test-host audit controls below are regression evidence only.
They do not establish a safe native persistence path, successful provider
authentication, Linux/macOS behavior, main-branch three-OS CI, or owner daily use.
The original terminal aggregate failure and skipped isolated rerun remain in
[Windows terminal measurement](windows-terminal-input-measurement.md).

Run `mise.exe run audit` from the repository root. The existing two-positional
`check_qualification.dart [Claude-results [qualified-source]]` CLI remains
compatible. Its default audit also reads this document and the separate literal
`packages/host/lib/src/agent/codex/codex_auth_signatures.dart`. An absent default
native document makes no observation claim; a present malformed/blank document,
explicitly missing input, unsupported literal, or registry without matching
recorded evidence fails. Pure checker callers can supply `codexMarkdown` and
`codexAuthSource` without changing the original two arguments.

For each actual protocol/name/exact-version/OS observation, use the following
format. This fenced template is deliberately not recorded evidence:

```markdown
## native codex-app-server codex <exact native version>
### windows
| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | unverified | no approved observation | | |
| streaming | user | unverified | no approved observation | | |
| tool activity | user | unverified | no approved observation | | |
| command approval | user | unverified | no approved observation | | |
| Stop | user | unverified | no approved observation | | |
| close/descendant containment | user | unverified | no approved observation | | |
| kumiko tool call | user | unverified | no approved observation | | |
| auth-required | user | unverified | isolated authentication experiment unrun | | |
```

`Kind` is `user` or `agent`. Every recorded row needs notes and exactly six
cells. Results are `pass`, `fail`, or `unverified`. Optional `recovery`,
`steering`, `structured question`, and `child attribution` rows each need their
own result when claimed. Required unverified rows produce
`CODEX OBSERVATIONS: <version> <OS>: INCOMPLETE`; all required passes produce
`PASS`; any failed required/claimed optional item or malformed section produces
`FAIL`. Optional unverified rows do not prevent a required-only PASS. These are
observation statuses, never a native ACCEPTED/QUALIFIED admission claim.
An unrecorded compatible Codex version remains admissible. Windows evidence
never manufactures Linux/macOS evidence. Missing/duplicate rows or sections,
unknown results/items/OS names, and unsigned auth passes are rejected.

Native Markdown cells support literal Unicode and the escapes `\|`, `\\`,
`\n`, `\r`, `\t`, and `\uXXXX` (four hexadecimal digits, including boundary
spaces/control characters). Split encoded cells first, trim Markdown padding, then
decode; escaped control characters remain exact. Unknown/dangling escapes fail.
Codex sign-in is classified by two closed, structured signals (design D7,
structured authentication signals), never by a native code/message pair:
`account-unauthenticated` (a Start-only preflight) and `turn-http-401` (a failed
turn whose structured error is an HTTP 401). An auth pass lists the observed
signal names in its Auth code cell, comma-separated in that fixed order, and
leaves the Auth message cell empty. Registry tuples are
`(observedVersion, observedOs, signal)`; every tuple needs a matching recorded
pass naming its signal, and every signal a pass names needs valid registry
provenance. Later observed versions can reuse a confirmed signal: the
production classifier projects only the signal names, so provenance never
gates later admitted versions. A successful authenticated turn cannot
substitute for observing an auth-required error.

Native `toolDeliveryFailures` messages use a
restricted single-quoted Dart literal: literal Unicode, `\'`, `\\`, `\$`,
`\n`, `\r`, `\t`, and exactly four hexadecimal digits after `\u`. There is
no interpolation, multiline/raw string, or expression evaluation. A failed
native tool-call Notes cell is exactly `observed: <JSON string>` before Markdown
cell escaping, preserving embedded quotes and control characters. Decode both
layers before comparing exact text. Do not truncate, fold case, or compare the
rendered/encoded text. The legacy Claude string/table grammar is unchanged.
Native failures use `('codex-app-server', exactVersion, exactObservedText)` in
the existing shared `toolDeliveryFailures`; only actually recorded native OS
sections are checked, without imposing Claude's three-OS requirement. A matched
native failure remains a FAIL observation. The existing Claude “Recorded
failure matches evidence” row keeps its established QUALIFIED behavior.

The offline helper is `tool/qualify_codex_app_server.dart`. Run through mise:

```text
mise.exe exec -- dart tool/qualify_codex_app_server.dart --dry-run
mise.exe exec -- dart tool/qualify_codex_app_server.dart --prepare --workspace <owned-empty-workspace> --native <absolute-native-exe> --manifest <new-manifest.json>
```

Preparation builds the existing test host and runs only its opt-in
`test/codex.probe`, which uses the ordinary UnitManager-contained, 4 KiB,
five-second identity probe. It does not start App Server, read native-home
files, submit provider turns or isolate authentication. It creates a disposable
Kumiko profile and writes a concrete manifest with selected native version,
workspace, complete native startup argv, exact three prompts/commands,
native-home scan scope and SHA-256. Schema 2 retains the native configured
approval policy without a qualification override. Startup uses the manifest's
exact argv; old schema-1 or missing-argv manifests are rejected before a new
attempt claim or host startup. A walk is also refused before the claim unless
the manifest's workspace is still an existing, empty, ordinary directory, so a
workspace removed after preparation (attempt 11) cannot spend an approval;
prepare a fresh manifest instead.
The native home path is recorded without accessing it. `--native-home` can
state the intended normal native auth home; credentials are never copied and
the owner's settings/login are not changed.

The coordinator must present that exact manifest for explicit owner approval
before invoking `--walk --manifest <file> --approved-sha256 <approved-hash>`.
The hash binds the approved bytes. No approval has been given or implied by a
dry run, successful native help/schema generation, or a prepared manifest.
An exclusive, flushed `attempt.jsonl` claim consumes that approved manifest
before host startup. Bounded completion/failure state is appended separately
from observation/cleanup success; a startup/scan/close failure does not restore
permission to replay the same approval. Fresh preparation and approval are
required for another attempt.
Observation persistence runs independently in `finally` even if cleanup or
the audit fails. Such a failure keeps the audit explicitly incomplete and
cannot leave the tool call marked pass; an existing privacy failure is retained.
The planned cap is three root prompts/native turns with 75-second observation
deadlines and no retries. Tool loops can cause additional billable provider
requests. Provider/model billing is inherited from normal user settings;
there is no enforceable dollar cap. Unexpected delegated-work state or child
events abort the walk and close the run. Stop/close and host settlement follow an
unapproved permission or deadline. Isolated authentication is a separate
helper mode with its own manifest and exact approval (`--prepare-auth`, then
`--walk-auth --manifest <file> --approved-sha256 <hash>`); never sign out, copy
credentials or invent a signal instead.

The walk uses the ordinary HostLauncher/public protocol, AgentService,
AgentSession and containment path. Its explicit native profile adds one
nonsecret independent test MCP probe through native `-c key=value` overrides;
native `app-server --help` confirms dotted TOML override syntax. Only the private
Kumiko MCP entry receives the grant over stdin. The probe reports booleans and
PID/start time into a bounded owned-workspace file after an actual
`env_presence` call; it never reports environment values. The unrelated command
also prints only presence booleans. Only an exact planned command/cwd and native
`accept` one-shot choice may be approved. File/session-wide/arbitrary permissions
are refused and stop the walk. No native config-write API is used.

Native home auditing is opt-in only in the test entrypoint, fixed before runs,
and matched to the native initialize response's home for the retained closed
session/run grant. Before launch it captures bounded metadata in that one home.
It scans new/changed session files, mutable log/state subtrees and root
SQLite/WAL/SHM, JSONL, and state-JSON artifacts; known mutable state/DB/log
artifacts are scanned even if metadata is unchanged. Unchanged historical
session contents are not read.
Unchanged unrelated files remain metadata-only, and credential/config contents
are never read. Missing baseline entries, new/changed unknown artifacts or
directories, links, unreadable/unstable bytes and exceeded bounds make the scan
incomplete. Traversal counts files/directories/links against 4096 entries and
does not follow links. The retained-grant scanner keeps four roots maximum,
16 MiB per file and 32 MiB total, including Kumiko profile and immutable target.
It returns counts/completeness/errors only, never the secret or matched content.
A canary match is a tool-delivery failure: refuse that unsafe configuration
path and stop further secret injection. A status-only failure entry is not
permission to repeat a proven unsafe path. An incomplete scan cannot pass by
excluding unreadable or unknown bytes. Release hosts reject these diagnostics
and the independent MCP fixture mode.

After approval, review the helper's bounded `observations.json` together with
actual native events, identity, permission decisions, Stop outcome, process
settlement, MCP facts and canary counts. Record only observations actually made.
Streaming requires multiple nonempty observations within one root turn before
its terminal control. The helper conservatively observes the first turn only,
so delayed data/control ordering may leave it unverified. A containment pass
requires the same known MCP descendant PID/start-time alive before close and
dead afterward; an already-exited helper cannot prove close killed it.
Retain absent/failed/optional results separately. A fixture dry run or synthetic
checker PASS is never a replacement. The full child browser/tree, targeted
child controls and independent child authority remain separately reviewed future
scope; this change preserves native identities and root delegated summaries.

Research date: 2026-11-10. Platform: Windows x64.

This records schema inspection, not a provider observation, authentication test,
runtime qualification or a claim that Kumiko's Codex path is implemented. Every
real-runtime observation remains **unverified**. No provider turn, approval,
tool call or auth experiment was made during this research.

## Candidate and reproduction

The installed native executable is
`F:\scoop\apps\codex\current\bin\codex.exe`, resolved from the Scoop shim's
metadata rather than treating the shim or package version as native identity.
Its `--version` output was `codex-cli 0.166.0`. The installed package manifest
also reports version 0.166.0 and target `x86_64-pc-windows-msvc`.
The SHA-256 observed for provenance was
`9D563EE4E0441FF9D59D612013E0460DDF8E5709735C2D9F6B98B7EF8CA4EB42`;
this is research provenance, never an admission allowlist/hash requirement.

Using that exact executable, the following local commands completed successfully:

```text
--version
app-server generate-json-schema --help
app-server generate-json-schema --out <task-temp>/stable
app-server generate-json-schema --experimental --out <task-temp>/experimental
```

These commands generated protocol data without starting an App Server or model
turn. The restricted environment printed failures to clean/create Codex's arg0
alias directories; generation and version retrieval nevertheless exited zero.
No generated source or schema was adopted into Kumiko; task output was temporary
and removed after inspection. Future runtime version checks must use the reviewed
contained UnitManager probe, not these standalone research commands.

## Core schema findings

Both stable and experimental bundles contain the essential methods below.
Schema field presence proves a wire shape, not successful runtime execution.

| Surface | Required request/response facts |
|---|---|
| `initialize` / `initialized` | Initialize request requires `clientInfo`; optional capabilities. The v1 response requires `userAgent`, `platformFamily`, `platformOs`, `codexHome`; there is no standalone required version field. Parse reported version only when actually present and compare to the probe. Send initialized notification before thread operations. |
| `thread/start` | Optional cwd/config/approval/model settings; response requires thread, model/provider, cwd, approval policy/reviewer and sandbox. Persist validated `thread.id` before exposing usable session. |
| `thread/resume` | Requires threadId; response includes thread and the same execution settings. Do not supply caller-created history/path overrides: their precedence can replace disk identity. A running thread can be rejoined by the runtime, so Kumiko must separately refuse adoption of unknown active work. |
| `turn/start` | Requires threadId and input; response requires turn. Completion is a separate native event. |
| `turn/interrupt` | Requires threadId and turnId; empty response is an acknowledgement, not interrupted terminal evidence. |
| Streaming | `turn/started`, `turn/completed`, `item/started`, `item/completed`, `item/agentMessage/delta`, command output and file-change notifications exist. Fence correlation by native identities and tolerate events before request response. |
| Command approval | `item/commandExecution/requestApproval` requires threadId, turnId, itemId, startedAtMs. Optional kind defaults to command when absent; null is not that default. Optional networkApprovalContext, additionalPermissions and availableDecisions determine the ordinary-command/list handling reviewed in D4. Response requires decision; explicit lists retain their native values. |
| File approval | `item/fileChange/requestApproval` requires threadId, turnId, itemId, startedAtMs and carries no offered-decision list. Its response-side native FileChangeApprovalDecision contract defines choices, including same-files session approval. The command-only fallback does not modify this contract; do not invent permission choices. |
| Permission approval | `item/permissions/requestApproval` is present; authored mapping must preserve its declared grant scope and native response shape. |
| Resolution | `serverRequest/resolved` exists; retire matching run-scoped interactions, including native cancellation/completion races. |

Approval provenance: the versioned [native request/response contract](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server-protocol/src/protocol/v2/item.rs)
defines `kind` and the file-change response semantics. That version's
[file-change UI](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/bottom_pane/approval_overlay.rs#L981)
also exposes same-files session approval. These are contract research facts,
not observed provider behavior or new real-runtime qualification.

JSON-RPC here uses native App Server envelopes; no synthetic ACP methods or ACP
capability advertisements are implied. Unknown additive events/fields are
tolerated. Malformed required core fields fail the run. Unknown server requests
are refused, never implicitly approved. Transport framing, request registration,
write failure and timeout behavior require the authored fixture tests.

## Optional contracts and history

| Feature | Candidate schema evidence and implementation limit |
|---|---|
| Explicit steering | `turn/steer` requires threadId, expectedTurnId and input; response requires turnId. Missing/malformed support disables steering only, with no fallback to a new turn. |
| Questions | `item/tool/requestUserInput` requires threadId, turnId, itemId, questions and isBlocking. Preserve question/options and native answer shape; never answer a newer turn. |
| MCP elicitation | `mcpServer/elicitation/request` requires serverName and threadId, with optional turnId; supported discriminated form/URL data must be validated. Unsupported forms receive an explicit native unavailable/cancel result. |
| Paged history | `thread/turns/list` and `thread/items/list` are present in the stable bundle. Each requires threadId, accepts cursor/limit/direction, and returns required data with optional next/backwards cursors. Item pages may select turnId. Limit requests to <=50 items and enforce shared encoded line/relay budgets. |
| Resume omission | `thread/resume.excludeTurns` avoids populating thread.turns. Optional initialTurnsPage can supply a bounded initial page; response may include initialTurnsPage and turn/item backwards cursors. `thread/read.includeTurns` controls history loading. Omitted/unloaded history must not be interpreted as a genuinely empty conversation. |
| History detail | Turn page itemsView distinguishes notLoaded, summary and full. Default summary is not a complete transcript. Ask for supported full detail and bounded item pages; do not invent missing items. Snapshot/live boundaries still require fixture checks and later real observation. |
| Child metadata | Experimental bundle retains collaboration/relationship fields in thread and item definitions. Only validated native identities may establish parentage; missing/changed metadata disables that view and marks unknown/incomplete instead of failing ordinary chat or flattening content. |

No essential core method was absent in this candidate. Optional schema presence
is not evidence that upstream will emit the feature in a particular turn; newer
versions may change optional shapes and must receive feature-local refusal.

## MCP configuration safety

The native thread/start and thread/resume config fields accept arbitrary objects
over stdin, but their JSON schema alone does **not** prove entry-env isolation
or non-persistence. `config/read` supports cwd and includeLayers, returning config,
origins and optional layers. The known Config properties do not explicitly
describe `mcp_servers`: absence from the typed projection cannot prove that a
user/workspace has no conflicting `kumiko` server. The later implementation must
prove effective-config absence and environment semantics before granting tools.

`config/value/write` and `config/batchWrite` are unsuitable fallback paths:
batchWrite explicitly targets a file (default user config.toml), and its optional
reload setting applies **after writing**. A private request transport does not
make a persistent write safe. No secrets were sent in this research. Until the
per-run path and absence proof are validated, report tools unavailable and revoke
the unused grant while keeping chat available. Do not switch to parent env, argv
or temporary/persistent secret files.

Fixture work must prove bridge-only entry environment, unrelated command and MCP
entry isolation, root-thread binding/revocation, conflicting config refusal and
the existing four-client cap. Scan all runtime-written session/log/state files
and Kumiko profile files for a per-run canary without printing matches. A fixture
only proves Kumiko behavior; a separately approved real run is needed to prove
Codex persistence behavior. No safe native tools claim is made here.

## Group 6: owned idle restoration and private tool configuration

Restoration reads native metadata before resume, validates the original thread
ID and inactive status, and requires `idle` after resume and history delivery.
Host prompt admission stays closed until replay ends. Duplicate Continue is
refused. Missing, empty, omitted, summary-only, active, changed-identity and
oversized history retain the saved record and report resume unavailable; no
prompt or replacement thread is submitted.

Positional cursors are not frozen snapshots. The basis for safe idle paging is
[native writer ownership](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/rollout/src/writer_lock.rs):
an exclusive OS lock refuses an existing active writer.
[The local store](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/thread-store/src/local/mod.rs)
retains the guard in its live recorder. This is primary-source contract
research, not a real-runtime lock observation. Actual work or unmatched live
items during restoration invalidates the boundary and fails replay.

Paginated threads use `excludeTurns: true` and `thread/items/list`, requesting
at most 50 full items per page. Cursors stay opaque and must make progress.
Legacy threads reject item paging; the supported full `thread/resume` reply is
their bounded fallback. Summary/unloaded history is never treated as full.
Frames retain the shared 16 MiB cap; normalized history is capped at 256 KiB
per page/full fallback. Encoded pages reserve existing relay bytes before
leaving native response decoding and release them only when relay ownership
transfers or the run closes. The 4096-key deduplication window evicts oldest
identities with a visible loss marker; it does not cap total paged history.
Snapshot/live races reserve existing relay credit
(64 messages / 256 KiB). Completed native item IDs deduplicate replay. Pages
flow through the ordinary event channel between replay markers, with one read
in flight and one 60-second active history deadline excluding awaited display
backpressure. No all-history collection survives outside a bounded native frame.

Private tools first call `config/read` with root cwd and `includeLayers: true`.
The effective MCP map and complete raw layers are checked; any `kumiko` entry
is refused without overwrite. Missing/malformed layers cannot prove absence.
Typed Config omission alone is insufficient. The primary
[configuration reader](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server/src/config_manager_service.rs)
loads cwd-effective configuration and raw layers. Per-thread stdin overrides
use [the in-memory builder](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server/src/config_manager.rs);
the override contains only `mcp_servers.kumiko`, with endpoint/secret/unit in
that entry's env. [MCP launch](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/rmcp-client/src/stdio_server_launcher.rs)
applies entry env to its child command. No parent env, argv, config-write API
or secret file delivers it. Unsupported absence verification revokes the unused
grant and keeps chat available with its precise tools-unavailable reason.
The minimum [named profile contract](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/config/src/profile_toml.rs)
does not support MCP server overlays. Raw `profiles` tables containing MCP
definitions fail closed as unsupported rather than bypassing absence checks
under unknown/newer profile semantics.

Source review found enumerated rollout metadata rather than arbitrary config
persistence and ordinary request tracing records method/IDs rather than bodies.
MCP child stderr is a potential native log sink: the bundled bridge must never
echo its secret. This supports the chosen contract path, not a real canary pass.

Authored fixtures launch the actual bundled bridge, exercise pending binding
and root authorization, inspect separate command/MCP environments, and scan
runtime session/log/state, work/report and profile files without printing the
secret or matching contents. Incomplete/unreadable scans fail verification.
An intentionally persisted canary is a negative detector control, never a
skipped pass. These are modeled native writes. Task 8.3 must separately approve
and record the real native tool call and post-run home/log/state/profile scan.
Every real-runtime observation remains unverified until that walk.

After fixture root close and before release, the existing test-only
`test/agent.stats` diagnostic accepts `secretScanSessionId` and
`secretScanRoots`. It uses only that retained run's grant and returns counts,
completeness and errors, never secrets or matching contents. At most four roots
are allowed within the host profile or immutable target, with limits of 4096
regular files, 16 MiB per file and 32 MiB total. Nonempty unreadable, changing or
oversized files make the scan incomplete. Two stable metadata observations can
account an empty regular file as zero bytes scanned without opening it. This
handles the observed Windows `kumiko.lock` error 33, length zero, without a path
exemption. An intentionally leaked fixture file proves detection; an exclusively
locked nonempty fixture file proves unreadable bytes cannot pass as clean.
These diagnostics are unavailable in release hosts and establish no real Codex
persistence observation.

### Opt-in audit budget (reviewed and offline verified, 2026-11-11)

The owner approved preparing, reviewing and then implementing a larger audit
preset. Round 5's focused recheck confirmed all six required corrections applied;
the implementation is independently verified offline. Default remains
16 MiB/file and 32 MiB total. The only larger preset,
`large-native-home`, allows 256 MiB/file and 512 MiB total, retaining 4096 files,
four confined roots and the existing native-home metadata traversal bound.

The prepare-only `--audit-profile` option explicitly selects the larger
preset; omission records `default`. Validate it before creating workspace/profile
artifacts. The manifest stores `scan.auditProfile`, exact `scan.maxFiles`,
`scan.maxFileBytes`, `scan.maxTotalBytes` and `scan.roots`. Top-level `profile`
continues to mean the Kumiko profile directory. Print all effective limits beside
the SHA256. Legacy schema-2 without `scan.auditProfile` accepts default numbers
only. Before claim or host/provider startup, reject unknown names, inconsistent
numbers or roots differing from the declared workspace/profile/native home.
Use the validated `scan.roots` list itself. `--walk` accepts no budget option.

`test/codex.audit.prepare` binds `auditProfile` once before any agent run or
scan, rejecting unknown, repeated or late bindings. Legacy unprepared fixture
scans keep the immutable default. Preparation echoes effective `auditProfile`,
`maxFiles`, `maxFileBytes` and `maxTotalBytes`; the helper rejects missing/mismatched
echoes before agent startup or content reads. Every scan result repeats those
fields. A scan echo mismatch keeps the result incomplete and the tool call
unverified, preserving any match failure. `test/agent.stats` rejects preset,
numeric-limit and budget overrides. Release hosts expose no audit/budget RPC or
capability, including under test environment inputs and budget-bearing requests.

The scanner uses at most 1 MiB chunks plus canary-length-minus-one carry, with no
whole-file allocation. Requests are bounded by the minimum chunk, remaining
file and remaining aggregate allowances. Stable `scannedBytes`, returned
`readBytes` and conservative `chargedBytes` satisfy
`scannedBytes <= readBytes <= chargedBytes <= maxTotalBytes`. Reserve before I/O;
unknown-count failures retain the charge. Unstable files' returned bytes still
count. EOF uses unchanged post-read metadata and a zero-byte read result only
when allowance remains; exact-boundary completion needs no out-of-budget probe.
Pre-read per-file oversize is unread/incomplete. Aggregate overflow reads only
the remaining allowance and is incomplete for outstanding bytes. After exhaustion,
bounded metadata enumeration still accounts stable empty files without reads;
nonempty or unknown-size candidates remain outstanding.

Matches count in `matchedFiles` even if that file later changes, fails or exhausts
allowance. Reset carry at each file; a prefix and suffix in different files do
not match. Match the ASCII canary's UTF-8 bytes; this does not detect UTF-16 or
other re-encodings. Directories are metadata traversal containers; links,
junctions and non-regular leaf entries in any root are errors and never followed.
Shared native-home concurrent writes may legitimately produce instability.
No credentials/config contents or scan exclusions are added. The byte budget
applies per scan call, with exactly one actual scan and no retry in a walk; the
existing request API has no scan deadline. A deterministic internal stat/open/read
seam is reachable only by offline tests, never RPC.

All implementation checks use owned synthetic files. This planning approval
authorizes no native-file content read, provider walk or authentication experiment.
A later exact-manifest approval must state the larger limits and that native
history/state contents up to those limits are read in chunks, never printed.
Original manifests and incomplete results remain intact; tasks 8.3/8.4 stay open.

For identity-only preparation of that preset, append
`--audit-profile large-native-home` to the existing `--prepare` command above.
It still starts no App Server/provider turn and performs no native-home content
scan. The larger scan remains gated by approval of the resulting exact manifest.

The scanner also caps metadata-candidate admission at 4096, counting duplicates
and directories, independently of the file ceiling and native-home metadata
bound. Directory-heavy trees can therefore be incomplete before reaching 4096
files. Iterative traversal bounds pending/seen state and cancels further upstream
enumeration at saturation; admitted candidates still settle. Code review exposed
this missing bound despite the earlier passing suites. Four deterministic
directory/duplicate/sibling regressions failed before correction. A further
regression reproduced a prior privacy failure being overwritten by later
incomplete metadata; that explicit failure now remains sticky.

Earlier behavioral RED also covered whole-file reads, lost matches after file
instability, failed-read accounting, non-regular leaves, missing host-limit echoes
and a malformed manifest claimed too early. Later matrix cases were added as
coverage, without a separate RED receipt for every case. Final independent
verification passed 54 affected host tests (one existing POSIX-only skip), all
183 retained tool tests, `mise.exe run check` (412 desktop tests), and all 883 host
tests with 13 platform skips. Audit and strict validation passed while retaining
native Windows **INCOMPLETE**. All 46 matching privacy/budget/manifest map cases
passed without skips across the four named files; the privacy row is green and
the real-Windows evidence row remains red. Synthetic Windows junction creation
was verified explicitly: non-following metadata returned link, no target bytes
were read, and the audit stayed incomplete. No additional real native-file scan,
provider walk or unrun OS observation is claimed.

## Initialize user-agent identity research (group 4)

Exact-tag primary references studied for behavior only:
[initialize response](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server/src/request_processors/initialize_processor.rs)
and [user-agent construction](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/login/src/auth/default_client.rs).
The response uses a user-agent whose first product token carries the native
build version. Its later platform and client-information suffixes carry other
versions and must not be interpreted as native identity. Compare only a
recognized leading product token with the contained probe. A future valid
string with unrecognized grammar leaves the probe authoritative; an unknown
additive `version` property has no established identity semantics and is ignored.
No App Server was started and no source was copied for this research.

## Version parsing and native launch environment

The observed identity line is exactly `codex-cli 0.166.0`; one observed line does
not establish every future upstream grammar. Kumiko must parse one bounded native
version token, rejecting missing/malformed/ambiguous identities and wrapper-version
substitution. Use numeric major/minor/patch comparison and semantic prerelease
ordering: 0.166.0 prereleases precede the stable minimum and are below it; a valid
newer numeric version is admitted without an allowlist. Build metadata does not
alter ordering. Do not compare lexicographically or silently strip a prerelease
suffix into a stable version. Verify these cases in group 3 fixtures, along with
probe/initialize mismatches. Record the exact native identity for evidence.

The candidate is a native Scoop package, not an npm launch. Its installed
codex-package.json names the native entrypoint, exec server, resources and path
directory. Direct launch must preserve package resources and resolution needs;
no npm process or JavaScript shim is necessary for this candidate.

For npm installs, official release-tagged launcher behavior was inspected as
reference only at
[Codex 0.166.0 launcher](https://github.com/openai/codex/blob/rust-v0.166.0/codex-cli/bin/codex.js).
It resolves the matching platform optional package's native binary and supplies
package-management provenance through the environment: the canonical package
root (`CODEX_MANAGED_PACKAGE_ROOT`) and exactly one package-manager marker
(`CODEX_MANAGED_BY_NPM`, or the detected Bun/pnpm/Vite Plus alternative), clearing
other manager markers. A native resolver must retain validated package provenance
without inheriting another installation's stale markers. This is behavior
research, not copied launcher code, constants or a port of its resolver.
Use installed package metadata and authored resolution tests; do not assume the
Scoop layout describes npm. Upstream main documentation obtained through Context7
also describes package resources/path directories; it is explanatory and is not
proof of the installed npm package's exact layout or runtime behavior.

## Observation status

This paragraph describes the state before the approved Windows attempts; the
recorded section at the end of this document is current. Before them there was
no recorded provider observation section. Launch/streaming, tool
activity, command approval, Stop, close/descendants, Kumiko tool call and
auth-required are all unverified, as are optional recovery, steering, questions
and child attribution. No PASS, ACCEPTED or QUALIFIED label follows from schema
generation. The later real Windows walk must name workspace, executable/version,
operations and possible provider cost, obtain explicit approval, then record the
actual results and canary scan. Linux/macOS remain unverified. Missing evidence
does not block compatible Codex versions; M2 close still needs real Windows
evidence for its then-installed version.


## Native host integration and profile guidance

Use an installed native Codex 0.166.0 or newer. Kumiko does not install Codex,
run npm during discovery, execute Windows batch shims, or scan another app's
private packages. Discovery checks native PATH files and matching installed npm
platform-package metadata. Other installations use an explicit profile: kind
`codex`, an absolute native executable, and argv `app-server` (plus user settings
as individual argv entries). Native provider sign-in stays user-owned.
An existing global default is preserved; launch intent and saved records filter
profiles by runtime kind. Removing a profile does not change a live run or its
saved immutable target.

AgentService owns containment, records, channels and failed-start cleanup.
AgentSession owns root state, drafts, pending interactions and Stop outcomes.
The operation driver maps native requests/events and bounded correlation only.
A separate ledgered probe uses the host's owner-only profile directory, selected
executable plus `--version`, resolution-essential environment, 4 KiB combined
output and a five-second limit; it settles before the root App Server starts.
The root uses the selected workspace and profile argv unchanged.

Core initialize/thread/turn/message/command/file/approval shapes are validated.
Unknown additive fields/events remain compatible. Optional questions, steering,
elicitation and child metadata have visible feature-local refusal. Unknown-child
content is withheld immediately with a bounded notice until the later child
registry is implemented. Early events reserve bytes from the same relay budget;
response-side delivery awaits bounded enqueue outside the large-line permit.
Steering reserves canonical-event capacity before draft removal or native writes.
Control acknowledgement remains separate from native completion; Stop timeout
leaves Stopping and a late terminal event reports its actual outcome.

The desktop offers Codex in the New tab launcher and a native runtime-kind
selector in Runtime profiles. Launcher and fresh-session recovery keep the
requested runtime kind; a different-kind global default requires a compatible
profile choice. Continue first retains the saved profile or compatible global default;
when neither can continue, the user can explicitly choose a compatible replacement
without changing the default. This profile routing does not establish native
history restoration. Root approvals show their supplied native choices and bounded
request preview. Structured answers are ephemeral, with secret inputs obscured;
Send remains idle-only and Steer explicitly addresses the active native turn.
Command approvals include the supplied command, working directory and reason;
file approvals include the grant root and reason. Additional-permission approvals
include the requested scope and working directory. Requests whose complete
details or choice labels exceed the existing 16 KiB preview, 256-byte choice label
or 64 KiB notification bounds are refused with a visible capacity reason.

Native history and root-scoped MCP now use the group 6 contract path above.
Unsupported history retains the saved identity; unsupported or conflicting MCP
configuration keeps chat available with tools unavailable and no usable grant.
Delegated activity uses a per-root registry of at most 64 native child identities.
Validated thread parent/source metadata and collaboration spawn records retain
immediate parents, including nested/restored relationships. Native thread/item
keys use unambiguous length prefixes; identical item IDs in different children
remain separate. Attributed content stays in the bounded live event model; the
root view shows task/status summaries and attributed interactions, with no child
browser or transcript persistence.

Sequenced agent state carries active-child count, waiting child requests and an
incomplete flag. Stop availability and close/quit warnings use this state even
when transcript credit is stalled and the root turn is Idle. Unknown attribution
shares relay reservations (32 messages/256 KiB and one five-second deadline);
capacity/deadline loss stays visibly incomplete. Native loss marks active children
disconnected rather than completed. Pending unknown relationships may resolve;
observed loss remains conservative until the root contained unit is settled.

Root Stop admits all addressed interrupts and cancellation replies atomically
within the existing 32 pending native requests and 1 MiB input budget. Saturation
refuses busy before writes or Stopping. Native outcomes, rather than interrupt
acknowledgements, settle the aggregate: unknown remains not confirmed, then error,
interrupted, or finished first. Unsupported child interruption keeps Stopping and
Close available. Explicit root close retains contained-tree cleanup and unresolved
cleanup gates. Draft and terminal exit rules are unchanged.

The full delegated-work browser remains later work. No real
runtime, persistence or authentication observation is established by authored
fixtures, source research or candidate-only signatures.


The published 0.166.0 npm metadata uses platform dependency aliases:
[main package metadata](https://registry.npmjs.org/@openai/codex/0.166.0)
and [Windows x64 alias target](https://registry.npmjs.org/@openai/codex/0.166.0-win32-x64).
The installed dependency directory has the platform alias name, but its own
metadata retains the declared underlying `@openai/codex` name and platform
package version. Discovery validates that declared alias identity, OS and CPU;
it never treats the packaging suffix as native semver. The contained native
probe remains authoritative. Native npm launch retains its validated package
root, one npm manager marker and existing bundled resource PATH directory;
stale other-manager markers are removed without modifying the host environment.
Probe stdout supplies identity; stderr remains diagnostic and counts toward the
same four-KiB combined output limit.

## Local Windows regression checks (2026-11-11)

The coordinator independently ran all 33 retained/affected suites and the
checker CLI. Direct results were host 426 pass / 3 platform skips, desktop 228,
Windows reopen integration 2, protocol 18, containment 11 and domain 5. After
the final checker correction, all three qualification tool suites passed 124
tests. The added newer-version child-metadata regression passed independently;
it was added green coverage, not an invented red-first result.

At the pre-walk checkpoint, `mise.exe run check` passed (412 desktop tests), then
`mise.exe run test:host` passed 820 tests with 13 platform skips. Audit, strict
OpenSpec validation (15 items) and `git diff --check` passed. No timing failure
occurred in these final runs. Earlier reproduced failures remain recorded; a
later green run does not erase them.

The scenario map contains 131 scenarios and 131 unique rows. Its references
identify actual file-bound regression checks; historical POSIX-only coverage
skipped on Windows remains a skip. These local checks establish no new
Linux/macOS result. The real-Windows observation row remains pending, and no
native observation section or confirmed authentication signature was added.

A separate contained identity-only probe prepared a disposable walk manifest
for installed Codex 0.166.0. That preparation made no App Server/provider calls
and read no native-home contents. The subsequently approved attempt is recorded
below. Authentication isolation remains unapproved; another walk needs a fresh
manifest and approval.

## Approved Windows attempt (2026-11-11)

The owner approved manifest SHA256
`d54897088e3bee53d56f17844bad6abdb6fcea358a05a897e5b2b4e331c46f28`.
The manifest and native executable hashes were verified before its single
attempt, claimed at 07:42:29.900867 UTC and failed at 07:42:30.377362 UTC.
No root prompt was submitted. The returned reason was `adapter-protocol`;
the original helper lost the message and stage, so the native cause is unknown.
The original attempt marker and observations are retained unchanged in the
owned qualification scratch directory. No automatic retry occurred.
A portable [failed-attempt receipt](codex-app-server-windows-attempt-2026-11-11.json)
retains the observed timestamps, identity hashes, cleanup and missing audit.

Host metadata records both version-probe units and the native unit cleaned,
then host exit 0. This is startup cleanup evidence, not a pass for interactive
close/descendant containment. The failed start returned no session identity,
and the helper did not perform its canary scan. The original lost stage cannot
prove that a private entry was never injected: the audit is **incomplete**,
with no claim of zero matches or a safe persistence path.

At this checkpoint the failed observation made the native checker report FAIL.
Regression tests and the earlier green offline audit did not override it.
The production authentication registry stays empty; no tool-delivery failure
entry or authentication signature is invented from this startup failure.

An offline follow-up reproduced the lost diagnostics with fixtures. Native
protocol startup failures now retain bounded redacted stderr, stage and known
exit status. The helper retains those diagnostics privately and records launch
FAIL with an incomplete, unscanned audit for any failure before a session id,
including non-RPC and host-open failures. Non-RPC error strings are not dumped.
At that checkpoint these changes fixed reporting; the original attempt's
startup cause remained unknown.

The coordinator's follow-up verification passed 145 qualification/dependency
fixture tests, eight selected native privacy/auth/startup regressions, the full
pre-commit check and 821 host tests with 13 platform skips. Strict OpenSpec
validation and whitespace checks passed. The explicit qualification audit
exited 1 with `CODEX OBSERVATIONS: 0.166.0 windows: FAIL`, solely for the real
recorded launch failure. No gate or evidence was weakened. A fresh unused
manifest was prepared with an identity-only probe; a further real attempt still
requires approval.

## Second approved Windows attempt (2026-11-11)

The owner approved fresh manifest SHA256
`4d9e8468fa12016f1d496698f0cbc7b9ad54236bd04baee76c199e007f09cd99`.
This separate single-use attempt was claimed at 08:36:19.232667 UTC and failed
at 08:36:19.607065 UTC, again before any root prompt. Its [durable receipt](codex-app-server-windows-attempt-2-2026-11-11.json)
preserves the captured diagnostic and cleanup. Both original attempt artifacts
remain unchanged; neither was retried automatically.

The corrected diagnostics identify stage `initialize` and native stderr:
`Error: approval_policy = "untrusted" is no longer supported; remove this setting`.
The helper supplied that rejected override. This establishes a qualification
helper startup defect, rather than an observed failure of root prompts, tools,
approvals or Stop. The native exit status was not captured and is not invented.
All three launched units were cleaned and the host exited 0.

Initialization failed before the host's private per-run MCP configuration step.
The filesystem canary scan nevertheless did not run and remains incomplete;
no zero-match or persistence-safety result is claimed. The helper now retains
normal account/configuration by removing its unsupported policy override; command
approval remains unverified unless a real native request is actually observed.
Any further real attempt requires a new exact manifest and approval.

The schema-2 policy/argv correction and cleanup-persistence regressions were
verified offline: the complete helper suite passed 22 tests, the coordinator's
qualification/dependency suites passed 156 tests, and `mise.exe run check`
passed. Host source/tests are unchanged since the independently passing
821-test host gate. These fixture results do not replace a new real observation;
the recorded Windows launch result remained FAIL until the third attempt below.

## Third approved Windows attempt (2026-11-11)

The owner approved schema-2 manifest SHA256
`ed9761314fe3a9b3ad049525a240571822d728d3909025f9051f6df7b6c91f78`,
declaring the complete startup argv without a qualification approval-policy
override. The exact manifest, executable and source hashes were verified before
its single attempt. It was claimed at 09:49:18.870740 UTC and failed at
09:51:27.063721 UTC with `TimeoutException`. All three root prompts were
submitted. No retry occurred, and this approval is consumed. A portable
[third-attempt receipt](codex-app-server-windows-attempt-3-2026-11-11.json)
preserves the partial observations and their limits.

Launch succeeded. The host recorded 92 text events, including 62 incremental
events during the first turn, and two tool-activity events. These establish
streaming and tool activity. The original helper left those rows unverified
because it assigned their positive results only after the entire operation loop;
the later timeout bypassed that assignment. Original observations are retained
unchanged, with this reconciliation separate. Bounded metadata from this exact
new native session also confirms an actual private SessionInfo result. It records
one completed task and two aborted turns, using normal `on-request` policy.
No transcript text, native command contents or matching file contents were printed.

Command approval and Stop were not observed. All three launched units were
cleaned and the host exited 0, but the unrelated MCP probe report was absent;
there is no active-descendant proof or verified unrelated-command/MCP environment
isolation. The canary audit scanned 29 files and 18,938,452 bytes, found zero
matches in that subset, and reported 11 errors. It is **incomplete**, not clean.
Additional bounded current-run metadata reads do not repair that audit. Overall
MCP delivery remains unverified despite the observed SessionInfo response.
No authentication experiment ran and the production signature registry is empty.

The latest section is therefore INCOMPLETE. The earlier two startup failures
remain recorded above and in their receipts. This is no claim of Windows
qualification, M2 close, approval/Stop success or unrun OS results. Task 8.3
remains unfinished while the control checks and persistence audit are unresolved.

### Offline corrections after the third attempt

The private configuration previously addressed the whole `mcp_servers` table.
Native thread overrides are applied after CLI overrides, so that replacement
discarded the unrelated qualification probe. The driver now addresses only
`mcp_servers.kumiko`, preserving the existing conflict checks. Independently
authored fixture regressions reproduced the missing entry on start and resume
before the fix, then verified that unrelated configuration survives without the
Kumiko grant environment. This establishes the configuration defect; it does
not prove the full cause of the real walk's later timeout. Reference:
[native override assembly](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/app-server/src/config_manager.rs#L673).

The helper now retains observed streaming and tool counters in a finalizer even
when a later operation times out. Its regression preserves explicit failures
and incomplete private-tool/audit results. Original real-attempt artifacts were
not rewritten.

The coordinator's first direct aggregate then exposed a separate startup EOF
race: 147 tests passed and one failed because the exit status was still unknown.
The isolated test passed. Containment cleanup and Dart exit-code publication
are independent, so stderr EOF alone did not ensure an observed status. A
deterministic reproduction failed before correction. Diagnostic draining now
joins stderr and exit-code observation within the existing one-second
post-exit read budget, preserving unknown status on timeout and preserving the
primary error. The strict EOF integration assertion was retained.

Final independent verification passed 154 directly affected native tests,
107 qualification/auth/audit-helper tests, `mise.exe run check` (including 412
desktop tests), and 829 host tests with 13 platform skips. `mise.exe run audit`
passed while explicitly reporting native Windows observations **INCOMPLETE**.
The 131-scenario map has 131 unique rows, no missing/extra/duplicate rows,
130 green rows and the real-Windows observation row still red. No new real
attempt or unrun OS result is claimed. At this checkpoint, command approvals
with an omitted native decision list remained unavailable pending the separate
design decision. The subsequent reviewed correction is recorded separately.

## Reviewed command-approval correction (2026-11-11)

The owner-approved D4 clarification passed independent design review with all
required items resolved. Ordinary command requests with absent/null decision
lists now expose only native one-shot accept/cancel, while explicit lists keep
their values and order. Invalid lists and missing lists on non-ordinary command
requests receive one native decline and a bounded notice; the run continues.
File-change behavior is outside this correction and was not changed.

The worker observed nine genuine failures before the implementation (five
ordinary-default cases and four invalid-entry cases), alongside 16 retained
passes. All 25 cases then passed. They cover explicit answers, opaque tokens,
duplicate/retired-answer refusal, known-child attribution, policy proposals,
explicit unknown values and a successful later root prompt.

The coordinator's first aggregate recorded 178 passes and one failure in the
existing pending-binding failure test: an authenticated transport slot was still
reserved while physical closure completed. The exact isolated case passed.
Grant revocation and pending-call removal are synchronous; the transport slot
intentionally remains counted until close completes. The test now waits for that
existing close condition while retaining immediate pending-binding, no-record
and single-start assertions. A controlled held-close unit test additionally
proves immediate revocation and rejection of the old secret, with capacity held
until physical close. No runtime counter, capacity limit or timeout was changed.
The original failed aggregate remains in the owned verification receipts.

Final independent verification passed 214 directly affected tests, 158 retained
tool tests, `mise.exe run check` (including 412 desktop tests), and 855 host tests
with 13 platform skips. Audit passed while reporting the existing native Windows
section **INCOMPLETE**. The expanded approval map row is now green from its full
executed checks; the real-Windows observation row remains red. These fixture
results do not establish new provider, privacy, OS or real-runtime observations.

Before preparing another walk, the helper gained bounded refusal diagnostics:
fixed stage/reason strings, operation number and four booleans. It retains the
same refusal and records no command, preview, identifiers, option values or
native messages. Three diagnostic regressions failed before the metadata was
added and then passed. All 161 retained tool tests passed independently. Approval
matching, grants, prompts, budgets and scan bounds were unchanged. Every host
source file still matched the source snapshot of the 855-test host gate.

## Fourth approved Windows attempt (2026-11-11)

The owner approved exactly one fresh attempt with manifest SHA256
`3b990826ebbe1699ea44585be1ad81ce5a58d279558a85f28acd11f70d739815`.
The preflight checked the native/test-host binaries and all 279 Dart sources.
Codex 0.166.0 used the current native account and normal `on-request` policy;
no approval-policy override, isolated authentication experiment or retry ran.
The [durable receipt](codex-app-server-windows-attempt-4-2026-11-11.json)
records the attempt from 16:50:26.384708 to 16:51:44.444781 UTC.

All three approved root prompts were submitted. The helper completed with exit
0 and observed 74 text events, 46 incremental first-turn events and four tool
events. Bounded current-session metadata recorded one completed turn and two
aborted turns. It confirms a SessionInfo response and aborted outputs for both
command attempts; it does not establish why those attempts were aborted.
No native command-approval answer, running marker or Stop result was recorded.
The unrelated MCP probe report was absent. Three walk-owned contained units
were cleaned and host disposal completed, but an active probe descendant was
not established, so that containment observation remains unverified.

The canary scan read 20,170,523 bytes across 29 files, found zero matches in
that subset and reported 11 errors. It is **incomplete**, not clean. Three bounded
reads of the exact current session added 866,694 bytes of metadata diagnosis,
for 21,037,217 bytes including the canary scan, within the approved 32 MiB
aggregate bound. No transcript text or secrets were printed. Those reads do
not repair the persistence audit or prove isolation of unrelated tools.

The latest observation section remains **INCOMPLETE**. Exit 0 only means the
helper completed; it is not a qualification pass. Tasks 8.3 and 8.4 stay open,
and the real-Windows map row stays red. Earlier failed attempts remain intact.
The single-use approval is consumed; no further real attempt is authorized.

A subsequent metadata-only inspection visited 440 native-home entries without
reading their contents. Two mutable root state/history artifacts were
69,947,392 and 136,392,704 bytes. Both exceed the existing 16 MiB per-file
scan bound, and together exceed its 32 MiB aggregate bound. This establishes a
current audit-budget obstacle, not a reconstruction of all 11 historical
errors. Repeating a walk under the same bounds cannot establish a complete
current-home scan while those artifacts remain in scope. No files were deleted,
no audit limit was raised and no exclusion was used to turn the result green.

Offline source tracing also found that the walk counted `agent/turnEnded`
notifications but discarded their structured error fields, and did not retain
notice classifications. The helper now stores at most three safe turn-end
summaries, an overflow flag and a finite set of notice flags. Fixed known
phrases are recorded only as category names; they are evidence of a phrase,
not proof of a cause. No raw message, native message, session identity or
command is stored in these diagnostics. Combined worst-case output is below
4 KiB. Three missing-diagnostic regressions failed before implementation; the
full 31-test helper suite then passed, including a fourth worst-case bound test.
Operational flow, native arguments, approval matching, grants and audit bounds
are unchanged. This improves future evidence; it does not reconstruct the
fourth attempt's missing host diagnostics or establish its abort cause.

Independent verification after this reporting correction passed all 165 retained
tool tests, `mise.exe run check` (including 412 desktop tests), audit and strict
OpenSpec validation. Audit still reports native Windows **INCOMPLETE**. Host
sources were unchanged from the independently passed 855-test host snapshot.

## Fifth approved Windows attempt (2026-11-11)

The owner approved one fresh attempt with exact manifest SHA256
`7e84ad19f2cc31f7e65c92b91c209a45f3913b56b4c6b37223ca991ea0b24953`,
including the large-native-home preset (256 MiB/file, 512 MiB total, 4096 files).
The [durable receipt](codex-app-server-windows-attempt-5-2026-11-11.json)
records the attempt from 19:04:46.400245 to 19:06:18.191128 UTC. Native 0.166.0
used the current account and normal approval configuration; no override,
automatic retry or isolated authentication experiment ran. Preflight verified
the exact manifest, executables, script and all 281 Dart source hashes.

All three approved root prompts were submitted. The helper completed with exit
0 and observed 75 text events, 43 incremental first-turn events and four tool
events. Retained control diagnostics show one normal end_turn and two cancelled
turns with no reported error fields. A native approval display-fidelity refusal
notice was observed before the request could be offered to the harness. This
localizes a blocker to the display guard; the exact lost field (title, preview,
choice name or encoded envelope) was not retained and is not proven. Model tool
arguments were small, but they are not the native approval payload. No native
approval answer, running marker or Stop result was recorded. The unrelated MCP
probe report was absent. All three walk-owned units were cleaned and host
disposal completed; active-descendant containment and unrelated environment
isolation remain unverified.

The audit echoed the approved large profile and limits. It scanned 32 files,
returning and charging 275,005,267 bytes, found zero matches in that subset and
reported two errors. It is **incomplete**, not clean. The smaller remaining error
count is not a pass and does not identify their historical categories. Bounded
post-run current-session/log/WAL shape inspection recovered no native approval
payload. Including conservatively charged owned-profile diagnostic reads, the
recorded upper bound is 355,075,420 bytes, below the approved 536,870,912 bytes.
No transcript text, secret or matching content was printed. This diagnosis
does not repair the incomplete audit or prove the cause of display loss.

The latest Windows section remains **INCOMPLETE**. All earlier failed/incomplete
attempts remain intact, tasks 8.3/8.4 stay open and the real-Windows map row stays
red. Exit 0 only means the helper completed. The fifth approval is consumed;
no further real attempt is authorized.

The offline follow-up preserves the refusal condition, cancellation response,
display caps and native choices. A refusal now adds only a static approval
category, child flag, redacted byte sizes and fidelity-loss flags. The helper
validates a closed field set, retains at most three snapshots within its 4 KiB
diagnostic bound, and stops issuing further prompts after a confirmed refusal;
the existing cleanup and single bounded audit still run. Test-only audit results
now separate fixed scanner/root/native-baseline/native-diff error categories,
OS-error buckets and known-literal artifact classes. No raw names, paths,
messages or file contents are emitted, and selection, reads, matching, scalar
error counts and qualification outcomes remain unchanged. These additions do
not reconstruct attempt 5's lost field or two historical error causes.

Coordinator reverification passed the affected host/tool suites, mise run check
(including 412 desktop tests), mise run test:host (899 passed, 13 platform
skips), audit, strict OpenSpec validation and whitespace checks. All 46 cases
matched by the audit-budget map prefixes passed without skips. The audit command
still reports native Windows INCOMPLETE; its overall ACCEPTED label concerns
the repository audit and is not a native qualification pass.

## Sixth approved Windows diagnostic attempt (2026-11-11)

The owner approved exact manifest SHA256
`561db06b745cf3d512dab90c80e4cfc09109b0031febbd9463510d4af75e35ed`.
The [durable receipt](codex-app-server-windows-attempt-6-2026-11-11.json)
records one attempt from 20:19:30.624733 to 20:20:55.399710 UTC, using native
0.166.0, the current account, normal approval settings and the large-native-home
limits. No retries or isolated authentication experiment ran. The helper exited
1 after its intentional display-refusal abort; it retained progress and ran the
existing cleanup, single audit and disposal path. No further real attempt is
authorized by this consumed approval.

The first root turn ended normally. The second produced a root command approval
with three options. Its largest redacted option name was 406 UTF-8 bytes,
exceeding the shared 256-byte name cap; namesLoss was true. Title (16 bytes),
preview (580 bytes), option count and encoded-envelope flags reported no loss.
The helper stopped further prompts. Source inspection confirms JSON native
decision objects are serialized into option labels, the DTO clamps those
labels, and the unchanged fidelity guard cancels the request. The actual raw
decision payload was not retained; the diagnostics prove the lost field, not
its specific native policy value. A retained synthetic policy-amendment case
already verifies this conservative cancellation. No approval response or Stop
result was recorded. There were 45 text events, 34 incremental first-turn events
and two tool events; unrelated MCP/command environment isolation and active
descendant containment remain unverified.

The audit scanned 32 files, returning and charging 281,381,306 bytes, with zero
subset matches and two errors. Both errors came from native metadata diffing:
one changed model-cache file and one changed other directory outside the
selected content scope. Scanner/root/baseline/I/O error counts were zero. The
model-cache classification is literal-name metadata only; the other directory
is unidentified. Their bytes were not cleared by a content scan. Neither error
may be ignored or reclassified as clean under the existing policy. No additional
native content inspection ran after this attempt. Windows remains INCOMPLETE,
tasks 8.3/8.4 stay open, and the real-Windows map row stays red.

## Planned follow-up after attempt 6 (not implemented or qualified)

The owner approved planning and external review of two changes. D4 places the
complete ordered object-valued native decision details in the existing redacted
preview with bounded indexed object labels and conservative object kind.
Permission display uses literal selectable text without fence interpretation;
exact native responses, field caps,
explicit answers and the final fidelity guard remain. The canary helper still
selects only the unique literal one-shot accept for its exact declared command
and cwd, never a policy/session object or an arbitrary allow_once option.

D5 adds prepare-only --native-selection and manifest scan.nativeSelection.
Omission/legacy keeps the old selection. Explicit changed-artifacts-v1 uses
bounded no-follow before/after native-home metadata inventories and scans
new/changed regular files, including caches and unclassified-directory children,
plus the existing always-scan artifacts. The 4096-entry metadata ceiling and
all byte/file limits remain. An incomplete baseline stops before provider work
but consumes the durable claim and records INCOMPLETE counters with no provider
or content scan; another attempt needs fresh approval. This wider scope may not
fit a shared home and promises no pass. SQLite/WAL/SHM filename families always
scan at every depth; other metadata-equal ordinary files remain a disclosed
detector limit. auth.json and config.toml leaves, plus other known credential
and configuration names established before implementation, remain metadata-only
at every depth, and changed protected,
removed, unstable or unaccounted entries remain incomplete. Other changed
contents may be private, including other credential-bearing stores. Preparation
must print the canonical wider-read disclosure and effective protected set
beside the hash; its manifest scope is checked before claim. A later
exact-manifest approval must disclose that wider scope. No real native-home
metadata/content inspection, implementation,
walk or tracker action is authorized by this planning/review step. All consumed
attempts and the INCOMPLETE result below remain intact.

## Credential and configuration filename research (0.166.0, 2026-11-11)

This is the research gate the D5 amendment requires before implementation. It
used only installed material for the minimum version: the same
`F:\scoop\apps\codex\current\bin\codex.exe` (`codex-cli 0.166.0`, SHA-256
`9D563EE4E0441FF9D59D612013E0460DDF8E5709735C2D9F6B98B7EF8CA4EB42`), the
stable and experimental schemas it generated into a task-temporary folder, and
a byte search of that executable's embedded strings. No native home, user
profile, credential store or provider was read or contacted; the temporary
schemas were deleted afterwards. No code or schema was adopted.

| Basename | Kind | Exact-version evidence |
|---|---|---|
| `auth.json` | credential | Executable: file-backend auth path and `auth storage mode` diagnostics; schema `CliAuthCredentialsStoreMode` = `file`/`keyring`/`auto` |
| `config.toml` | configuration | Schema: `CODEX_HOME/config.toml` user layer and config write targets |
| `.credentials.json` | credential | Executable: MCP OAuth file store next to `MCP_OAUTH`, `issuer`, `client_id`, `token_response`, `expires_at` and "credentials file path has no parent directory" |
| `managed_config.toml` | configuration | Schema: "Managed config layer from a file (usually `managed_config.toml`)"; executable config-layer labels |
| `requirements.toml` | configuration | Schema: requirements read response ("no requirements.toml/MDM entries"); executable `<environment:..>/requirements.toml` layer label |
| `environments.toml` | configuration | Executable: environment-registry file name next to environment-id validation messages |
| `.env` | credential (conservative) | Executable links `dotenvy` 0.15.7 from the `arg0` startup crate; `.env` is that loader's file name. The exact load directory is not provable from installed material, so the name is protected conservatively |

The effective changed-artifacts-v1 protected set is these seven basenames,
compared case-insensitively on Windows and exactly elsewhere, at every depth.
Protection only removes reads: a new, changed or removed protected entry keeps
the audit incomplete. Credentials named by environment variables at arbitrary
paths (for example `OPENAI_IDENTITY_TOKEN_FILE`) and stores outside the native
home (OS keyring, AWS SDK files) have no fixed native-home basename. They are
covered only by the wider-read disclosure, which warns that other
credential-bearing stores may be read. No unresolved known name remains for
0.166.0. A later minimum version needs this research repeated before its names
are trusted.

## Seventh approved Windows attempt (2026-11-11)

The owner approved exact manifest SHA256
`8e12e7743fe8b272d217f56ff4e05d28974b35071e607d067de9df53e2f3f54c` after
the decision display and changed-artifact amendment was implemented and
verified offline. The approval stated the changed-artifacts-v1 wider-read
disclosure, the seven-name protected set and the large-native-home limits. The
[durable receipt](codex-app-server-windows-attempt-7-2026-11-11.json) records one
claim at 21:53:42.331443 UTC and failure at 21:53:43.801657 UTC with native
0.166.0, the current account and normal approval settings.

The baseline preflight ran after the claim and before App Server startup. The
native-home inventory reported baselineComplete false with 8 errors, so the
helper aborted as designed. No App Server, prompt, provider work, content scan
or authentication experiment ran, and no attempt-owned process remained. The
claim is consumed.

The preparation echo carried only the error count, not its content-free
category breakdown, so the cause is unknown. It could be the admission bound,
links or nonregular entries, instability, or I/O. No further native-home
metadata was read to find out. The raw helper also set launch to fail through
its missing-session path, although launch was never attempted. Neither
helper defect changes the result: the attempt is INCOMPLETE and the
observation table below still holds attempt 6's actual observations.

Offline corrections after this attempt, verified test-first:
- The host's preparation echo now includes the fixed baseline error and I/O
  category counters.
- The helper copies only known category keys with non-negative integer counts
  into the receipt.
- A baseline-preflight abort leaves launch unverified.

If a home exceeds the unchanged 4096-entry inventory bound, changed-artifacts-v1
cannot complete for it. The bound is not raised. Another attempt needs a fresh
exact-manifest approval.

## Eighth approved Windows attempt (2026-11-11)

The owner approved exact manifest SHA256
`fb2c0359586bfeaea449faa5fe543879e3737c310e29d066bc3f2404346b2392`, with the
same settings and disclosure as attempt 7, after attempt 7's offline
corrections. The [durable receipt](codex-app-server-windows-attempt-8-2026-11-11.json)
records the claim at 22:03:00.775309 UTC and failure at 22:03:02.088218 UTC.
The baseline preflight again aborted before App Server startup. No prompt,
provider work, content scan or authentication experiment ran, launch stayed
unverified, and no attempt-owned process remained. The claim is consumed.

This time the content-free categories explain all 8 errors:
- 1 `metadataLimit`: the native home holds more entries than the unchanged
  4096-entry admission bound.
- 7 `nonRegular`: links, junctions or other non-regular entries, which are
  never followed.

There were no I/O, instability, removed or protected-entry errors. Under the
reviewed bounds, changed-artifacts-v1 cannot complete for this native home.
Further progress needs one of two things: a different native home that is
within the bounds and has no links (for example a dedicated Codex home signed
in separately), or a reviewed design change. Either also needs fresh
exact-manifest approval. The observation table below still holds attempt 6's
actual observations.

## Ninth approved Windows attempt (2026-11-12)

The owner kept the normal native home. The reviewed changed-artifacts-v2
amendment was implemented and verified offline. The owner then approved exact
manifest SHA256
`56dac86c6e2c063bdcdae73c571b58141fa0fcc3965ff17968e119e8e28ac81b` and paused
other Codex sessions. The approval stated the v2 disclosure and the
large-native-home limits. The
[durable receipt](codex-app-server-windows-attempt-9-2026-11-12.json) records
the claim at 23:04:22.125786 UTC and failure at 23:04:26.469971 UTC (on
2026-11-11).

The baseline preflight aborted before App Server startup with 2 errors, both
`nonRegular`. The entry bound and the string budget held. No link observation
failed, so the 7 links were not among the errors. No prompt, provider work,
content scan or authentication experiment ran, launch stayed unverified, and
no attempt-owned process remained. The claim is consumed.

In v2, `nonRegular` means the no-follow type check returned neither file,
directory nor link. On Windows that is a Unix-domain socket, a pipe, or an
entry that vanished between directory listing and type check. These results
cannot tell which. Windows remains INCOMPLETE.

An owner-approved metadata-only diagnostic followed. It printed only counts per
no-follow type, and for odd entries only their extension and folder depth. It
found 9,158 files, 3,956 directories, 5 links and 2 Unix-domain sockets (`.sock`,
one folder below the native-home root). Nothing had vanished. The reviewed
socket amendment adds changed-artifacts-v3, which records Windows AF_UNIX
sockets from their own find-data without opening them. v2 keeps its meaning
for this consumed manifest.

## Tenth approved Windows attempt (2026-11-12)

The reviewed changed-artifacts-v3 amendment was implemented and verified
offline. The owner approved exact manifest SHA256
`9aa62426f2a3ceca304b89df2db2d01b63af4769aeadf4ba64f2297c632c0d9c`, stating
the v3 disclosure and large-native-home limits. As instructed, Orca was checked
for Codex sessions first: two idle Codex chats were listed, and no Codex
process ran on the machine, so none was killed. The
[durable receipt](codex-app-server-windows-attempt-10-2026-11-12.json) records
the claim at 00:04:28.070420 UTC and failure at 00:05:37.960698 UTC.

The v3 baseline was complete. Launch, streaming (47 first-turn incremental
events) and tool activity passed. On the second operation, the native command
approval for the canary command had the expected title and a one-shot accept
option, but did not match the approved request. The helper refused it and
stopped (`outside-approved-request`). Its content-free diagnostic does not say
which check failed: command text, working directory, preview layout or the
native decision list. Command approval, Stop, containment and the kumiko tool
call stay unverified.

The audit scanned 98 files (321,423,458 bytes) with 0 canary matches. It
accounted for 2 sockets and 5 links, and kept 2 protected entries
metadata-only. 5 `removedEntry` errors (baseline entries gone after the run)
keep it incomplete; every other category is zero. No attempt-owned process
remained. The claim is consumed. Windows remains INCOMPLETE.

## Eleventh approved Windows attempt (2026-11-12)

The reviewed changed-artifacts-v4 amendment and the per-check approval
diagnostic were implemented and verified offline. The owner approved exact
manifest SHA256
`f890541458489176d44c878714de591c2da3fc39320f4218d4b8adf7d8de108c`, stating
the v4 disclosure and large-native-home limits. A Codex review process started
by another Claude session was running at approval time; it was left to finish,
and the walk started only once no Codex process remained. The
[durable receipt](codex-app-server-windows-attempt-11-2026-11-12.json) records
the claim at 01:31:34.462857 UTC and failure at 01:31:37.928047 UTC.

Session start was refused with `target-unavailable` (`CreateFileW error 0`).
The owned workspace folder had been created empty at preparation (00:39 UTC),
but no longer existed when the walk started; the profile folder from
preparation was intact. What removed the empty folder is not known. Error 0
means the Win32 last-error value was not preserved. No prompt, provider work or
content scan ran, and no attempt-owned process remained. The helper's
`launch: fail` reflects this environment failure, not Codex launch, which
attempt 10 passed; the table below is unchanged. The claim is consumed.
Windows remains INCOMPLETE.

## Twelfth approved Windows attempt (2026-11-12)

The owner approved a freshly prepared changed-artifacts-v4 manifest, SHA256
`c7fc01bbe7244063258efd4ac522668759141138387d81f8b68aca2821d3c033`, with the
same disclosure and large-native-home limits. A Codex review process started
by another Claude session began after approval; it was left to finish, and the
walk started once no Codex process remained and the prepared workspace was
confirmed empty. The
[durable receipt](codex-app-server-windows-attempt-12-2026-11-12.json) records
the claim at 09:33:55.840331 UTC and failure at 09:35:29.364531 UTC.

The audit was complete for the first time: 0 errors in every category, 101
files scanned (322,415,678 bytes), 0 canary matches. It accounted for 2 sockets
and 5 links, counted 5 removed entries and kept 2 protected entries
metadata-only. Launch, streaming (47 first-turn incremental events) and tool
activity passed. On the canary operation, the per-check approval diagnostic
shows every check passing (title, one-shot accept, preview layout, working
directory, reason line, native decision list) except `commandMatches`. The
first preview line neither contains nor starts with the approved command, so
Codex presents the command in a different form than the prompt gave it; the
content-free diagnostic does not record which form. The helper refused the
approval (`outside-approved-request`). Command approval, Stop, containment and
the kumiko tool call stay unverified, and no attempt-owned process remained.
The claim is consumed. Windows remains INCOMPLETE.

## Thirteenth approved Windows attempt (2026-11-12)

The native command wrapper amendment (Rounds 10 and 11 REVISE, an owner
decision on administrator trust, Round 12 APPROVE_WITH_CHANGES) was implemented
and verified offline. The owner approved exact manifest SHA256
`a2ef2382a841cb1480474d2c7abb053b72b08d4f506f0990edcc9b0ff4fb3337`, with the
same v4 disclosure and limits. The walk waited for a Codex review started by
another Claude session to finish. A second such review started during the walk
(10:54:42 UTC) and was left alone; it is a possible concurrent native-home
writer, which the disclosure covers. The
[durable receipt](codex-app-server-windows-attempt-13-2026-11-12.json) records
the claim at 10:53:57.538610 UTC and completion at 10:55:45.522763 UTC.

All three prompts ran. Launch, streaming (42 first-turn incremental events),
tool activity (16 events) and command approval passed: each native command
approval was answered once under the wrapper rule, and the canary command
reported both injected secrets absent. The audit was complete: 0 errors, 106
files scanned (325,104,462 bytes), 0 canary matches, 2 sockets and 5 links
accounted for, 5 removed entries counted, 2 protected entries metadata-only.

Three required rows stay unverified. Stop: the helper looks for the running
marker only in tool events tagged as command executions, but the host forwards
streamed command output deltas as untagged tool updates, so the marker was not
seen while the 60-second command ran and the turn ended normally. Close and
descendant containment, and the kumiko tool call: the qualification MCP
environment probe wrote no report, so MCP environment isolation and the
active-descendant proof are missing; why it did not report is not recorded. No
attempt-owned process remained. The claim is consumed. Windows remains
INCOMPLETE.

## Fourteenth approved Windows attempt (2026-11-12)

Two offline corrections were verified first. The walk now reads command markers
through a per-id tracker that joins untagged streamed output deltas with their
command item. The MCP probe rewrites its report at each stage (started,
initialized, listed, called) with boolean flags and its own identity only. The
owner approved exact manifest SHA256
`a4cc1d2d96b7d5fb0edc11c33f0b68ddf4ba10c873c69af789f3399b4f8471bb`, with the
same v4 disclosure and limits. No Codex process was running; the one idle Orca
Codex chat was left alone. The
[durable receipt](codex-app-server-windows-attempt-14-2026-11-12.json) records
the claim at 11:19:21.958479 UTC and completion at 11:20:57.401150 UTC.

All three prompts ran. Launch, streaming (45 first-turn incremental events),
tool activity (9 events), command approval, Stop and close/descendant
containment passed. Stop was sent when the running marker arrived in the third
command's streamed output, and that turn ended cancelled. The probe's started
record gave its process identity; it was alive before close and settled after.
The audit was complete: 0 errors, 59 files scanned (324,820,631 bytes), 0
canary matches, 2 sockets and 5 links accounted for, 5 removed entries counted,
2 protected entries metadata-only.

The kumiko tool call stays unverified. The probe started, was initialized and
listed its tool, but `env_presence` was never called. The tool declared no
annotations, and Codex's default (`auto`) MCP approval mode asks for approval of
such a tool; the host cancels MCP elicitations as unsupported. That is the
likely cause, but this walk did not flag the cancellation notice. Since then the
probe declares its tool read-only, as Kumiko's own read-only tools do, and the
walk flags a cancelled MCP elicitation. No attempt-owned process remained. The
claim is consumed. Windows remains INCOMPLETE.

## Fifteenth approved Windows attempt (2026-11-12)

The probe now declares `env_presence` read-only, and the walk flags a cancelled
MCP elicitation; both were verified offline. The owner approved exact manifest
SHA256 `1e7c42ac40bf240cc665f0ab8d592dfdec89b4ad5a5ef3ede79a823a912c9bcc`, with
the same v4 disclosure and limits. No Codex process was running; the one idle
Orca Codex chat was left alone. The
[durable receipt](codex-app-server-windows-attempt-15-2026-11-12.json) records
the claim at 11:31:46.215328 UTC and completion at 11:33:38.078368 UTC.

All three prompts ran, and every required row the walk exercises passed: launch,
streaming (28 first-turn incremental events), tool activity (9 events), command
approval, Stop, close/descendant containment and the kumiko tool call. Codex
called the probe without an approval request; the probe reported both the tool
secret and the tool endpoint absent, and the canary command reported both
secrets absent. The audit was complete: 0 errors, 59 files scanned (326,946,613
bytes), 0 canary matches, 2 sockets and 5 links accounted for, 5 removed entries
counted, 2 protected entries metadata-only. No attempt-owned process remained.
The claim is consumed.

At this point Windows remained INCOMPLETE only on `auth-required`, which
needed the separate isolated authentication experiment (recorded below).

## Isolated authentication observation (2026-11-12)

The owner approved the isolated authentication experiment. Before building it,
a minimal direct observation ran outside Kumiko to see how signed-out Codex
reports authentication. It used Codex 0.166.0 (`F:\scoop\apps\codex\current\bin\codex.exe`)
with an empty, owned `CODEX_HOME` in `%TEMP%`, `-c
cli_auth_credentials_store="ephemeral"` (no keyring read, no credential write)
and no environment variable whose name contains `OPENAI`, `CODEX` or `AZURE`.
The owner's native home was not used: `initialize` reported the isolated home
as `codexHome`. Nothing was billed: every provider request was answered HTTP
401. The folder was deleted afterwards, and no Codex process remained.

Observed: `initialize`, `thread/start` and `turn/start` all succeed;
`account/read` with `refreshToken: false` returns `account: null` and
`requiresOpenaiAuth: true`. The turn emits `error` notifications with
`willRetry: true` and `codexErrorInfo`
`{"responseStreamDisconnected": {"httpStatusCode": 401}}` (five WebSocket and
five HTTPS attempts). It then ends with `turn/completed` status `failed` and
`codexErrorInfo` `{"httpConnectionFailed": {"httpStatusCode": 401}}`. The
message text carries per-request identifiers, and no JSON-RPC error code is
involved. This observation is research input for the structured-signal design
amendment, not a recorded auth-required pass: it did not run through Kumiko.

## Approved isolated authentication experiment (2026-11-12)

After the structured-signal amendment was implemented, the owner approved the
experiment manifest with SHA-256
`d06cce698e5cf6e3e9a41ab52973239d844d948038bdc18f00e3885ce4f19b6f`. It used
Codex 0.166.0 (`F:\scoop\apps\codex\current\bin\codex.exe`, SHA-256
`9d563ee4e0441ff9d59d612013e0460ddf8e5709735c2d9f6b98b7ef8ca4eb42`) through the
test host with SHA-256
`07b9e36375d0096d1202c4df3325d8c44991262a53b072b8385ded18f5ac48c1`. Each
operation ran on a fresh host with its own empty, owned `CODEX_HOME` inside the
run's profile folder, native arguments
`app-server -c cli_auth_credentials_store="ephemeral"`, and a host environment
with no variable whose name contains `OPENAI` or `CODEX`. The owner's native
home was neither read nor scanned. The content-free receipt is
[`codex-app-server-windows-auth-experiment-2026-11-12.json`](codex-app-server-windows-auth-experiment-2026-11-12.json).

- Operation A (candidates `account-unauthenticated`): Start succeeded. The
  preflight did not hold, so it failed open as designed and the session was
  closed. The receipt is content-free, so why it did not hold is not recorded;
  `account-unauthenticated` remains unobserved and unregistered.
- Operation B (candidates `turn-http-401`): Start succeeded; the one prompt,
  sent signed out, ended auth-required through Kumiko without a native error
  code. The session closed cleanly.
- The canary scan of the workspace and profile (both homes included) was
  complete: 2,598 files, 31,256,624 bytes, 0 errors, 0 matches. Both homes were
  deleted, the claim is consumed, and no Codex process remained.

The registry now holds `('0.166.0', 'windows', 'turn-http-401')`.

## native codex-app-server codex 0.166.0
### windows
| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | agent | pass | fifteenth approved attempt established a root session and ran three turns | | |
| streaming | agent | pass | fifteenth attempt: 28 incremental first-turn text events | | |
| tool activity | agent | pass | fifteenth attempt: 9 host tool-activity events | | |
| command approval | agent | pass | fifteenth attempt: native command approvals answered once each under the reviewed wrapper rule; canary reported both secrets absent | | |
| Stop | agent | pass | fifteenth attempt: running marker read from streamed output deltas; Stop sent and the turn ended cancelled | | |
| close/descendant containment | agent | pass | fifteenth attempt: close completed; the MCP probe was alive before close and settled after | | |
| kumiko tool call | agent | pass | fifteenth attempt: tools connected; MCP probe called and reported secret and endpoint absent; complete audit 59 files 326946613 bytes 0 matches | | |
| auth-required | agent | pass | approved isolated authentication experiment: signed-out prompt turn ended auth-required through Kumiko from its structured HTTP 401; the account preflight failed open, so account-unauthenticated was not observed | turn-http-401 | |
| recovery | agent | unverified | optional observation unrun | | |
| steering | agent | unverified | optional observation unrun | | |
| structured question | agent | unverified | optional observation unrun | | |
| child attribution | agent | unverified | optional observation unrun | | |

## Final status for this change (task 8.4, 2026-11-13)

This summary reconciles the record above; it adds no observation.

- **Windows, Codex 0.166.0:** every required row passed (the fifteenth approved
  attempt and the approved isolated authentication experiment), and the audit
  prints `CODEX OBSERVATIONS: 0.166.0 windows: PASS`. That is a qualification
  of this version on Windows, not an allowlist: later compatible versions are
  admitted without new evidence.
- **Failed and incomplete attempts stay recorded.** Attempts one to fourteen,
  with their receipts, failed or ended INCOMPLETE for the reasons given in
  their sections. The final pass does not clear or relabel them.
- **Not observed:** the optional recovery, steering, structured-question and
  child-attribution observations were not run and stay unverified; fixture
  and regression results do not stand in for them. The Start-time sign-in
  signal `account-unauthenticated` was not observed (its preflight failed open
  in operation A), so it is not registered and the release host does not use
  it.
- **Linux and macOS:** no real Codex observation ran on either. Only the
  regression suites cover them, and no support is claimed.
- **Not claimed by this change:** main three-OS CI and the owner's daily use
  on Windows are M2 milestone-close evidence. An informal manual run of a
  local release build by the owner (2026-11-12) is not recorded evidence
  either.
- **Future scope:** the full child browser or tree, targeted child controls
  and independent child authority need a separately reviewed change. This
  change keeps native child identities and the root delegated-activity
  summary for it.
