# Review

## Metadata

- **Round:** 1 re-check
- **Prior round:** Round 1 gave APPROVE_WITH_CHANGES with nine Required Changes (M1-M9: POSIX exec-status pipe, Windows executable resolution and `npx`, macOS GUI PATH, event size bounds, host memory worst case, stalled-channel permission scenario, Stop error and late results, Continue availability rule, qualification results path), CHANGES_APPLIED: no.
- **Reviewer:** fresh-context subagent (Claude Code, specwright-reviewer); project skill loaded: flutter-test-architecture
- **Reviewed:** openspec/changes/claude-acp-chat-session/{proposal.md, design.md, review.md (round 1 findings and Rebuttals), specs/agent-sessions/spec.md, specs/agent-runtimes/spec.md, specs/desktop-host-protocol/spec.md, specs/workbench-layout/spec.md}; source: packages/process_containment/lib/src/unit_exec.dart, packages/host/lib/src/profiles/shell_detector.dart (wellKnownShellDirs, search order), .github/workflows/ci.yml (OS matrix, "Audit dependencies" step)

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

This re-check covers only the nine Required Changes from round 1, plus any contradiction the fixes added.

- **M1:** applied. D2 no longer uses the shim status pipe for `pipes` units, and says why: fd 1 carries ACP (`unit_exec.dart:43-51`). The executable is now resolved and checked before `launch`: `X_OK` on POSIX, a regular `.exe` on Windows. Exit 126 or 127 before `initialize` maps to `not-executable` or `executable-not-found`, which matches the shim's real codes (`unit_exec.dart:60, 95`). The Failure & Visibility row and the Mechanism Ledger row were updated to match.
- **M2:** applied. D11 "Executable resolution" searches PATH and then PATHEXT. The first match must be an `.exe`, a `.cmd` or `.bat` match is refused, and the search does not continue past it. This works with `lpApplicationName`, because the host passes the absolute `.exe` it resolved. D7 step 2, Risks and the proposal's runtime-profile bullet now give the Windows `node.exe ... npx-cli.js` form. agent-runtimes adds "Bare name on Windows" and "Bare name resolving to a batch file on Windows", and the `npx` scenario now says it applies to Linux.
- **M3:** applied. D11 adds well-known directories that follow the `shell_detector.dart` pattern. The built-in profile is now the absolute `node` path plus the absolute script path, with `node`'s directory first on `PATH`, so it does not depend on `#!/usr/bin/env node` or on the desktop's PATH. D13 adds a Finder/Dock step, and Risks has a new row. agent-runtimes adds "Adapter on PATH on macOS" and "Desktop started from the Dock".
- **M4:** applied. The "Normalized event size" row in Resource Bounds sets one limit: 256 KiB encoded, escaping counted, enforced before enqueueing. Text chunks are capped at 1 MiB and split into events of at most 64 KiB encoded, on code point boundaries. Tool items are added while the event total still fits, and the rest are marked with `truncated` and `omittedItems`. An event still too large becomes a `notice`, and a session is never failed for event size. These limits are consistent with the desktop reassembly bound.
- **M5:** applied. Resource Bounds keeps the 16 MiB line bound and adds a host-wide permit for large lines. The queue overshoot is bounded at 1 MiB, by the 1 MiB text cap and the 256 KiB event cap. The design states the worst case: about 4.4 MiB per session, about 280 MiB at 64 sessions, plus about 64 MiB for one large line, about 350 MiB in total. The arithmetic holds, and the Mechanism Ledger has a row for the permit.
- **M6:** applied. In desktop-host-protocol, "Permission request while the event channel is stalled" now applies only when the queue is below its bound. The new scenario "Event queue full when a permission request is raised" says the request is shown after consumption resumes, Stop reports *Stop not confirmed* after the deadline, and close is still acknowledged and ends the session. This matches the design's Flow & State Gaps entry.
- **M7:** applied. D8 adds `stopResult{endedWithError, message}`. It also defines one late result after `notConfirmed`, carrying `late: true`, followed by `agent/turnEnded` and `agent/state idle`, and shown as "(after the deadline)". agent-sessions updates the requirement text and adds "Turn errors after Stop" and "Turn ends after the stop deadline".
- **M8:** applied. D9 "One rule for availability" decides availability from the Continue run alone. agent-runtimes ("Qualified version", "Unqualified version", "Unqualified version in a new session", "Advertised feature missing") and agent-sessions ("Adapter exits during a turn", "Continue through load", "Continue through resume") now check the reason after Continue, not on the record. The Failure & Visibility row and the proposal's *resume unavailable* list match this rule.
- **M9:** applied. D10, D13, D15 and the proposal now put the results in `docs/qualification/claude-agent-acp.md`, a path that does not move on archive. The check runs in CI's audit step, and `ci.yml` has an "Audit dependencies" step inside the windows/ubuntu/macos matrix. QUALIFIED is printed only when every OS passes, which M1 close requires.

### Critical (blocking)

None.

### Moderate

None introduced by the fixes.

### Suggestions

**S1. The 126/127 mapping can mislabel a failure that happens after `execve`.** `env` exits 127 when its interpreter is missing, for example a user profile pointing at the npm bin link `claude-agent-acp` (`#!/usr/bin/env node`) on a GUI PATH with no `node`. An adapter can also exit 126 or 127 itself before `initialize`. Both are then shown as *executable not found* naming a path that exists. The shim always writes `unit-exec: ...` to stderr before exiting (`unit_exec.dart:116-118`). Map to `executable-not-found` or `not-executable` only when the stderr tail starts with that prefix. Otherwise show the generic *adapter failed to start* with the exit status and the tail.

**S2. Release of the large-line permit is not specified.** The permit is released "once the line is parsed and normalized". Say that it is also released when the holding session fails, closes or reaches EOF partway through a line. Otherwise, a holder whose adapter dies or hangs in the middle of a line could block other sessions' large lines with no visible reason.

**S3. The proposal and the state diagram lag D8.** The proposal's Stop list does not include *Turn ended with an error after Stop* or the late result. It still says "the turn stays shown as running" (round 1 S2), while the spec and D8 say the status stays *Stopping*. The diagram's `stopping --> idle` label lists only `stopped / finishedFirst`. Update both, so nobody implements from the shorter list.

**S4. Detection scenarios still say "on PATH".** In agent-runtimes, "Adapter not installed" and "Default profile removed from PATH" are written in terms of PATH alone. Detection now also searches the well-known directories. Say "on PATH or in the well-known directories", so a test does not assert that no profile is found while the adapter sits in `/opt/homebrew/bin`.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **design.md D2 and Mechanism Ledger:** replace the POSIX exec-status pipe for `pipes` units with pre-launch resolution and checks plus 126/127 mapping (M1). *Applied.*
2. **design.md D7 and D11, proposal, Risks, specs/agent-runtimes:** specify Windows executable resolution, give the `npx` example in a POSIX form and a Windows form, and add Windows bare-name scenarios (M2). *Applied.*
3. **design.md D11 and D13:** handle the GUI-launch PATH on macOS and Linux, and add the case to the qualification walk (M3). *Applied.*
4. **design.md Resource Bounds:** make the 256 KiB encoded event bound consistent with the content limits, split text by encoded size, and enforce the bound before enqueueing (M4). *Applied.*
5. **design.md Resource Bounds:** state the true worst-case host memory, including one line's normalized overshoot (M5). *Applied.*
6. **specs/desktop-host-protocol:** limit the stalled-channel permission scenario to a queue below its bound, and add the full-queue scenario (M6). *Applied.*
7. **design.md D8 and specs/agent-sessions:** add the result for a turn that ends in an error after Stop, define the late result after `notConfirmed`, and add both scenarios (M7). *Applied.*
8. **design.md D9 and D10, specs/agent-runtimes, specs/agent-sessions:** use one rule for Continue availability, decided by the Continue run, and rewrite the THENs to match (M8). *Applied.*
9. **design.md D10 and D15:** move the qualification results to a stable repository path and say that CI runs the check (M9). *Applied.*

CHANGES_APPLIED: yes

## Rebuttals

- **M1-M9:** fixed by the author as listed in round 1's Rebuttals, and confirmed by this re-check (see Findings).

- **M1 (POSIX exec-status pipe):** fixed. design.md D2 replaces it with pre-launch resolution and checks plus 126/127 mapping; Failure & Visibility row and Mechanism Ledger row updated.
- **M2 (Windows launch):** fixed. design.md D11 "Executable resolution" (PATH + PATHEXT, first match must be `.exe`, `.cmd`/`.bat` refused) and "`npx` profiles" (Windows `node.exe ... npx-cli.js` form); D7 step 2; Risks; proposal runtime-profile bullet; specs/agent-runtimes scenarios "Bare name on Windows" and "Bare name resolving to a batch file on Windows", and the npx scenario's Windows note.
- **M3 (macOS GUI PATH):** fixed. design.md D11 well-known directories and built-in profile as absolute `node` + script with `node`'s directory on `PATH`; D13 Finder/Dock step; Risks row; specs/agent-runtimes detection requirement text and scenarios "Adapter on PATH on macOS" and "Desktop started from the Dock".
- **M4 (event size bounds):** fixed. design.md Resource Bounds "Normalized event size": 256 KiB encoded total enforced before enqueue, text split by encoded size on code points, tool items added while the total fits with `truncated`/`omittedItems`, oversize fallback to a notice, never failing the session.
- **M5 (host memory):** fixed. design.md Resource Bounds: 16 MiB line bound kept, new host-wide large-line permit row, queue overshoot bounded at 1 MiB (1 MiB text-chunk cap), and a stated worst case (≈ 350 MiB at 64 sessions); Mechanism Ledger row for the permit.
- **M6 (stalled-channel permission scenario):** fixed. specs/desktop-host-protocol: condition limited to a queue below its bound; new scenario "Event queue full when a permission request is raised".
- **M7 (Stop outcomes):** fixed. design.md D8 adds `endedWithError` and the late result after `notConfirmed`; specs/agent-sessions requirement text and scenarios "Turn errors after Stop" and "Turn ends after the stop deadline".
- **M8 (Continue availability):** fixed. design.md D9 "One rule for availability" (decided by the Continue run); Failure & Visibility row; specs/agent-runtimes "Qualified version", "Unqualified version", "Unqualified version in a new session", "Advertised feature missing"; specs/agent-sessions "Adapter exits during a turn", "Continue through load", "Continue through resume".
- **M9 (qualification results path):** fixed. design.md D10 (`docs/qualification/claude-agent-acp.md`, check in CI's audit step on every OS), D13, D15; proposal Qualification and planning-files bullets.
