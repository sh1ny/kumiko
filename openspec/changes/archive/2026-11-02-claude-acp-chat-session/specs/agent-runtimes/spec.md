# Spec Delta

## Purpose

Describes how Kumiko launches a user's installed coding-agent runtime adapter from an argv runtime profile, and how it decides which runtime capabilities it may claim from the adapter's advertised features and a qualified-versions list.

## ADDED Requirements

### Requirement: A runtime profile is an argv launch description for an ACP adapter
A runtime profile SHALL hold a name, a runtime kind (`claude-code` in this change), an executable, an argument list and environment overrides. The host SHALL start the adapter from that executable and list without assembling or parsing a command string, and SHALL apply the overrides only to sessions that use the profile. Source: D6, D20; user decision 2026-10-31.

#### Scenario: Launch from an npx profile
- **WHEN** a profile has executable `npx`, arguments `-y`, `@agentclientprotocol/claude-agent-acp@0.99.1`, and the user starts a session with it on Linux (on Windows the same profile uses `node.exe` with npm's `npx-cli.js`, since `npx` is a batch file there)
- **THEN** the adapter process receives exactly those two arguments, in order, unchanged

#### Scenario: Argument with spaces and quotes
- **WHEN** a profile argument is `--setting="a b"`
- **THEN** the adapter receives that one argument byte for byte, not split or unquoted

#### Scenario: Override does not leak
- **WHEN** profile P sets `ANTHROPIC_LOG=debug` and a terminal and a session with profile Q are started
- **THEN** neither the terminal nor the Q session's adapter sees `ANTHROPIC_LOG=debug`

### Requirement: An installed adapter is detected as a built-in profile
At start the host SHALL look for `claude-agent-acp` on the user's PATH and the well-known install directories stated in the design, and when found offer it as a built-in runtime profile. That profile SHALL run the absolute `node` executable with the adapter package's script path, so it works without the desktop's PATH. Built-in profiles SHALL be read-only.

#### Scenario: Adapter installed with npm on Windows
- **WHEN** `npm install -g @agentclientprotocol/claude-agent-acp` has put `claude-agent-acp.cmd` on PATH and `node.exe` is on PATH
- **THEN** the built-in profile's executable is that `node.exe` and its first argument is the absolute path of the package's `dist/index.js`

#### Scenario: Adapter on PATH on macOS
- **WHEN** `claude-agent-acp` resolves on PATH to the npm bin link of the package
- **THEN** a built-in profile named Claude Code is listed whose executable is the absolute `node` path and whose only argument is the package's absolute `dist/index.js` path

#### Scenario: Desktop started from the Dock
- **WHEN** Kumiko is started from the macOS Dock with a PATH that lacks `/opt/homebrew/bin`, and Node and the adapter are installed there by Homebrew
- **THEN** the built-in profile is still detected, and a session started with it reaches *Idle*

#### Scenario: Adapter not installed
- **WHEN** `claude-agent-acp` is absent from both PATH and the well-known install directories stated in the design
- **THEN** no built-in runtime profile is listed, and the Claude Code launcher entry offers to add a profile, naming the npm package and Node ≥ 22

#### Scenario: Built-in profile cannot be edited
- **WHEN** the desktop asks the host to change or remove a built-in runtime profile
- **THEN** the request is refused with a reason and the profile is unchanged; the user can copy it into an editable profile instead

### Requirement: The user can define, edit and remove runtime profiles
The user SHALL be able to add, edit and remove their own runtime profiles. The host SHALL validate a profile before saving and keep it in the local store across restarts. Removing a profile SHALL NOT end or change any running session or saved session record.

#### Scenario: Add a profile
- **WHEN** the user saves a profile with executable `node`, arguments `/opt/acp/dist/index.js` and no overrides
- **THEN** it is listed after a host restart with the same executable, arguments and overrides

#### Scenario: Invalid profile refused
- **WHEN** the user saves a profile with an empty executable, or an environment name containing `=`
- **THEN** the save is refused with the reason, and the stored profiles are unchanged

#### Scenario: Remove a profile in use
- **WHEN** the user removes the profile a running session was started with
- **THEN** the session keeps running, its saved record keeps its runtime kind and adapter version, and a later Continue of it uses the default profile

### Requirement: One runtime profile is the default
Exactly one runtime profile SHALL be the default when any exists. The first detected built-in profile SHALL become the default when no default is stored. A default that names a missing profile SHALL be reported unavailable, and no other profile SHALL be substituted silently.

#### Scenario: First start with the adapter installed
- **WHEN** the host starts with no stored default and a built-in Claude Code profile is detected
- **THEN** that profile is the default

#### Scenario: Default profile removed from PATH
- **WHEN** the stored default is the built-in profile and `claude-agent-acp` is absent from both PATH and the well-known install directories stated in the design at host start
- **THEN** the default is reported unavailable with the reason, and starting a Claude Code session asks the user to choose or add a profile

### Requirement: An unusable adapter executable is reported, never substituted
Starting a session whose profile executable is missing, not executable, or a Windows batch file (`.cmd`, `.bat`) SHALL fail with a reason naming the executable, and SHALL NOT start another adapter. An adapter that exits before answering `initialize` SHALL fail the start with its exit status and the last lines of its error output.

#### Scenario: Missing executable
- **WHEN** a profile's executable `/usr/local/bin/claude-agent-acp` does not exist and the user starts a session
- **THEN** the start fails with *executable not found* naming that path, no process is left running, and no session record is created

#### Scenario: Batch file refused
- **WHEN** a profile's executable on Windows is `C:\Users\u\AppData\Roaming\npm\claude-agent-acp.cmd`
- **THEN** the profile is refused with a reason that batch files cannot be launched directly and that the `node.exe` form is needed

#### Scenario: Bare name on Windows
- **WHEN** a profile's executable on Windows is `node` and `C:\Program Files\nodejs\node.exe` is on PATH
- **THEN** the session starts `C:\Program Files\nodejs\node.exe`

#### Scenario: Bare name resolving to a batch file on Windows
- **WHEN** a profile's executable on Windows is `npx` and the first match on PATH is `npx.cmd`
- **THEN** the start is refused with the batch-file reason, naming `npx.cmd` and the `node.exe ... npx-cli.js` form, and no process is started

#### Scenario: Node too old
- **WHEN** the adapter process exits with status 1 before answering `initialize`, writing an engine-version error to its error output
- **THEN** the start fails showing the exit status and the last lines of that output, and no session record is created

### Requirement: Runtime capabilities are claimed only from evidence
For each session the host SHALL record the adapter name and version reported in ACP `initialize`. It SHALL claim a capability only when the adapter advertised it and that adapter version is on the qualified-versions list for it. Unqualified versions SHALL get only the safe baseline: prompt, streamed messages, tool activity, permission requests and cancel. Every other capability SHALL be shown unavailable with the reason. Source: ADR 0004 decision 2.

#### Scenario: Qualified version
- **WHEN** the user chooses Continue on a saved session, and the adapter started for it reports a name and version on the qualified list for `load` and advertises `loadSession`
- **THEN** that run claims `load`, and the earlier conversation is loaded

#### Scenario: Unqualified version
- **WHEN** the user chooses Continue on a saved session, and the adapter started for it reports a version that is not on the qualified list while advertising `loadSession` and `resume`
- **THEN** the pane shows *resume unavailable: adapter version not qualified* with that version, the adapter is terminated, and the saved record is unchanged

#### Scenario: Unqualified version in a new session
- **WHEN** the user starts a new session and the adapter reports a version that is not on the qualified list
- **THEN** the session runs with the baseline only, and its capabilities show load and resume as unavailable with the version named

#### Scenario: Advertised feature missing
- **WHEN** the user chooses Continue, and the adapter started for it is a qualified version but advertises neither `loadSession` nor `sessionCapabilities.resume` in that run
- **THEN** the pane shows *resume unavailable: not advertised by the adapter*, and the adapter is terminated

#### Scenario: Adapter speaks another protocol version
- **WHEN** an adapter answers `initialize` with a protocol version other than 1
- **THEN** the start fails with *unsupported ACP protocol version* naming the version, and the adapter's process tree is terminated
