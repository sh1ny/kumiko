# Claude agent ACP qualification

This document contains real per-version observations and a fenced format template.
Windows qualification of `@agentclientprotocol/claude-agent-acp` 0.99.1 was run
through `tool/qualify_claude_acp.dart` and personally confirmed by the user.
Linux and macOS user observations remain `unproven`; they are not passing results.
Do not copy the fenced template into an evidence section before making those
observations. Capability claims must match the recorded results below.

## Running qualification

Run from the repository root with the pinned toolchains and `FLUTTER_ROOT` set
to the mise-managed Flutter installation. The driver builds the complete test-host
bundle; it never uses the release host.

Windows PowerShell, with the pinned Dart already on `PATH`:

```powershell
$env:FLUTTER_ROOT = (mise where flutter).Trim()
dart tool/qualify_claude_acp.dart --dry-run
dart tool/qualify_claude_acp.dart --workspace "<absolute disposable checkout>"
```

If the shell does not forward `mise exec --` arguments correctly, invoke Dart
directly as above, or pass the complete command to `mise exec -c`.

Git Bash, Linux or macOS:

```sh
export FLUTTER_ROOT="$(mise where flutter)"
mise exec -- dart tool/qualify_claude_acp.dart --dry-run
mise exec -- dart tool/qualify_claude_acp.dart --workspace "<absolute disposable checkout>"
```

`--dry-run` uses only owned temporary files and the contained scripted fixture.
It exercises streaming, tools, an explicit fixture permission choice, Stop,
confirmed close, preferred load, resume-only continuation and refusal without
the candidate override. Its output is not real-adapter evidence and it never
writes version observations here.

Real qualification requires an interactive terminal, Node 22 or newer, the
user's installed adapter and native Claude Code setup. Claude Code alone does
not install the ACP adapter. Install the planned candidate separately:

```sh
npm install --global @agentclientprotocol/claude-agent-acp@0.99.1
```

Restart the qualification driver after installing; it detects runtime profiles
when the test host starts. At the runtime profile prompt, a blank answer uses
the detected default.

Use a disposable checkout:
approved provider requests may spend tokens and change workspace files.
`--profile-dir "<existing Kumiko profile>"` reuses existing runtime profiles;
`--profile "<runtime profile id>"` selects one explicitly. An unavailable chosen
profile or default is reported rather than silently replaced. Without
`--profile-dir`, the Kumiko profile is disposable.

Separate explicit approvals gate provider execution, prompts, the offered
permission choice, Stop, close, authentication isolation and the final evidence
write. There is no `--yes` or noninteractive real mode. Authentication isolation
uses a fresh temporary `CLAUDE_CONFIG_DIR` and per-session credential environment
overrides; it never signs the user out, copies login files or changes global
credentials. An isolated session that starts successfully has not yet proved
model authentication. The driver then offers a separately approved minimal
model request through the ordinary prompt path. Review the exact prompt before
approving; no tool permission is answered automatically. Native authentication
errors may come from session creation or the prompt's actual turn result.
Successful model execution is reported as success, not authentication-failure
evidence. Declining the request, an unrelated failure, or missing/truncated native
diagnostics leaves authentication unrecorded. Recording an error still requires
your confirmation that its exact code and message mean authentication is required.
Without that observation, Windows evidence remains unwritten.

For the isolated clone, present `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`
and `CLAUDE_CODE_OAUTH_TOKEN` values are blanked. Matching is case-insensitive
on Windows (including profile-only overrides) and case-sensitive on POSIX.
`ANTHROPIC_BASE_URL` and unrelated overrides are preserved; the source profile
is never changed.

The candidate identity comes from the actual initialized adapter. Qualification
uses that exact candidate only in the test host: both extras exercise preferred
load; a second run with resume alone exercises the resume path. Neither grants
production capabilities. The final write preserves other OS observations and
requires confirmed Windows results plus the exact, nontruncated native
authentication error. Unrun Linux/macOS observations remain `unproven`.

## Status legend

- `pass`: the item was observed working. Notes describe the run and what was
  confirmed; authentication also records the actual error code and message.
- `fail`: the item was tried and did not meet the bar. Notes describe the failure.
- `unproven`: a Linux or macOS **user-verified** item has not been verified.
  Notes explain what remains unverified. This never means pass and is not allowed
  for a checked Windows item or an agent-scripted item.

`Kind` is `user` for a real-adapter observation verified by the user (including
observations produced by the qualification tool and confirmed by the user), or
`agent` for an agent-scripted observation. Fake-agent automated tests are not
real-adapter qualification evidence. This template uses user verification.

## Recording and checker contract

A real version section is exactly `## adapter <adapterName> <exactVersion>` with
one `### windows`, `### linux` and `### macos` table. Adapter names and versions
are the exact non-whitespace values from ACP `initialize`, not version ranges.
Each item appears once per OS; Finder/Dock appears only on macOS. The six table
columns, in order, are `Item`, `Kind`, `Result`, `Notes`, `Auth code`, `Auth message`.
Use a single line per row, without literal pipes inside cells. Do not record
credentials, prompts, replies or other private conversation content in notes.
For `auth-required observed`, a `pass` needs both the actual code and message in
their own cells. Record the environment, run date and user confirmation in notes.

The checker ignores fenced code blocks, including the entire template below.
Only unfenced real-run sections count as evidence. Blank results, unknown
items/OSes and duplicate sections/rows fail with adapter/version, OS and item
(or the `section` diagnostic item). For a listed pair it checks launch, streaming,
tool activity, permission request, Stop, close with confirmation, authentication,
and macOS Finder/Dock. It checks load/resume only if that pair claims them;
unclaimed load/resume may fail or remain unproven without blocking other claims.
Fill every result when recording a run; an empty template cell is not a status.

The source grammar is intentionally literal, so later claim logic can consume the
same typed data without evaluating Dart source:

```dart
const qualifiedAdapters = <(String, String, List<String>)>[
  ('<adapterName>', '<exactVersion>', <String>['load', 'resume']),
];
```

Each tuple is `(adapterName, exactVersion, qualifiedExtraCapabilities)`. An empty
capability list claims only the baseline qualification, not load or resume.
Only `load` and `resume` are allowed, at most once each. Source comments and
whitespace are allowed; computed expressions, aliases and other declarations are
not. Entries and identities must be unique. The production list currently names
`@agentclientprotocol/claude-agent-acp` 0.99.1 for `load` and `resume`, backed by
the confirmed Windows results below. Linux/macOS remain explicitly unproven.

Run `dart run tool/check_qualification.dart [resultsPath [sourcePath]]` from the
repository root. Defaults are this file and
`packages/host/lib/src/agent/qualified_adapters.dart`. The pure API is
`checkQualification(String markdown, String? qualifiedSource)` returning
`QualificationReport` with `failures`, `unproven`, `verdict` and `exitCode`.
A null source represents a missing source file. Diagnostics and unproven entries
use `<adapterName> <exactVersion>: <os>: <item>: <detail>` (unproven entries omit
`: <detail>`). Document/source errors use `results:` / `source:`.

- Exit 1: `FAILED: <diagnostic>` for each failure; no success verdict.
- Exit 0 with an empty list: `NO CLAIMS (no adapter qualified)`, never ACCEPTED or
  QUALIFIED. The document must still be nonblank and structurally valid.
- Exit 0 with nonempty claims and allowed unproven observations:
  `unproven: <adapterName> <exactVersion>: <os>: <item>` for each, then `ACCEPTED`.
- Exit 0 with nonempty claims and every checked item passing: `QUALIFIED`.

M1 close requires QUALIFIED. ACCEPTED leaves every unproven item visible.
Missing or unparseable source/results files fail; there are no provider calls.

## Version-section template (not evidence)

Replace the placeholders and blank cells only with real-run observations. This
fenced block must remain a template, not an observed adapter version section.

```markdown
## adapter <adapterName> <exactVersion>

### windows

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | | | | |
| streaming | user | | | | |
| tool activity | user | | | | |
| permission request | user | | | | |
| Stop | user | | | | |
| close with confirmation | user | | | | |
| load | user | | | | |
| resume | user | | | | |
| auth-required observed | user | | | | |

### linux

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | | | | |
| streaming | user | | | | |
| tool activity | user | | | | |
| permission request | user | | | | |
| Stop | user | | | | |
| close with confirmation | user | | | | |
| load | user | | | | |
| resume | user | | | | |
| auth-required observed | user | | | | |

### macos

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | | | | |
| streaming | user | | | | |
| tool activity | user | | | | |
| permission request | user | | | | |
| Stop | user | | | | |
| close with confirmation | user | | | | |
| load | user | | | | |
| resume | user | | | | |
| auth-required observed | user | | | | |
| launch from Finder or the Dock | user | | | | |
```

## adapter @agentclientprotocol/claude-agent-acp 0.99.1

### windows

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| streaming | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| tool activity | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| permission request | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| Stop | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| close with confirmation | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| load | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| resume | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; user confirmed pass. |  |  |
| auth-required observed | user | pass | Real local adapter through test host; OS=windows; 2026-10-31; isolated session/new succeeded, then session/prompt returned this exact error; user confirmed authentication semantics and pass. | -32000 | Authentication required |

### linux

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | unproven | Not verified by a user on this OS. |  |  |
| streaming | user | unproven | Not verified by a user on this OS. |  |  |
| tool activity | user | unproven | Not verified by a user on this OS. |  |  |
| permission request | user | unproven | Not verified by a user on this OS. |  |  |
| Stop | user | unproven | Not verified by a user on this OS. |  |  |
| close with confirmation | user | unproven | Not verified by a user on this OS. |  |  |
| load | user | unproven | Not verified by a user on this OS. |  |  |
| resume | user | unproven | Not verified by a user on this OS. |  |  |
| auth-required observed | user | unproven | Not verified by a user on this OS. |  |  |

### macos

| Item | Kind | Result | Notes | Auth code | Auth message |
|---|---|---|---|---|---|
| launch | user | unproven | Not verified by a user on this OS. |  |  |
| streaming | user | unproven | Not verified by a user on this OS. |  |  |
| tool activity | user | unproven | Not verified by a user on this OS. |  |  |
| permission request | user | unproven | Not verified by a user on this OS. |  |  |
| Stop | user | unproven | Not verified by a user on this OS. |  |  |
| close with confirmation | user | unproven | Not verified by a user on this OS. |  |  |
| load | user | unproven | Not verified by a user on this OS. |  |  |
| resume | user | unproven | Not verified by a user on this OS. |  |  |
| auth-required observed | user | unproven | Not verified by a user on this OS. |  |  |
| launch from Finder or the Dock | user | unproven | Not verified by a user on this OS. |  |  |

