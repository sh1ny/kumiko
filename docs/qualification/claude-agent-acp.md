# Claude agent ACP qualification

This is the format template, not an observation record. No adapter version has
been recorded here. `tool/qualify_claude_acp.dart` and the user will add version
sections from real runs in tasks 10.1 and 10.2 of `claude-acp-chat-session`.
Do not copy a template into an evidence section before making those observations.
The qualified list stays empty until task 10.3 selects claims from recorded runs.

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
not. Entries and identities must be unique. The production list is empty now.

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
