# Codex App Server contract research

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
| Command approval | `item/commandExecution/requestApproval` requires threadId, turnId, itemId, startedAtMs; optional availableDecisions. Response requires decision. Preserve actual offered decision values. |
| File approval | `item/fileChange/requestApproval` requires threadId, turnId, itemId, startedAtMs. Do not invent permission choices. |
| Permission approval | `item/permissions/requestApproval` is present; authored mapping must preserve its declared grant scope and native response shape. |
| Resolution | `serverRequest/resolved` exists; retire matching run-scoped interactions, including native cancellation/completion races. |

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

There is no recorded provider observation section yet. Launch/streaming, tool
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

This host integration does not yet expose the desktop launcher, restore native
history, or deliver a Kumiko MCP entry. Until safe entry-only delivery is proven,
Codex starts without a usable ToolGrant and reports the Codex safe-delivery
limitation even when the tool endpoint exists. No real runtime or authentication
observation is established by the authored fixtures or candidate-only signatures.


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
