# Spec Delta

## MODIFIED Requirements

### Requirement: A runtime profile is an argv launch description for an ACP adapter

A runtime profile SHALL hold a name, a runtime kind (`claude-code`, `codex` or `omp`), an executable, an argument list and environment overrides. The host SHALL start the adapter from that executable and list without assembling or parsing a command string, and SHALL apply the overrides only to sessions that use the profile. The runtime kind SHALL select Claude ACP, native Codex App Server or native OMP RPC explicitly; existing profiles SHALL retain their meaning. Source: D6 amended by owner decision 2026-11-10, D20; ADR 0004 for OMP.

#### Scenario: Launch from an npx profile

- **WHEN** a profile has executable `npx`, arguments `-y`, `@agentclientprotocol/claude-agent-acp@0.99.1`, and the user starts a session with it on Linux (on Windows the same profile uses `node.exe` with npm's `npx-cli.js`, since `npx` is a batch file there)

- **THEN** the adapter process receives exactly those two arguments, in order, unchanged

#### Scenario: Argument with spaces and quotes

- **WHEN** a profile argument is `--setting="a b"`

- **THEN** the adapter receives that one argument byte for byte, not split or unquoted

#### Scenario: Override does not leak

- **WHEN** profile P sets `ANTHROPIC_LOG=debug` and a terminal and a session with profile Q are started

- **THEN** neither the terminal nor the Q session's adapter sees `ANTHROPIC_LOG=debug`

#### Scenario: Codex argv profile

- **WHEN** a Codex profile specifies an absolute executable and App Server arguments

- **THEN** it launches profile arguments unchanged and in order, with only non-secret per-run configuration arguments appended, over private stdio without an ACP wrapper

#### Scenario: Unsupported runtime kind

- **WHEN** a profile names an unsupported runtime kind

- **THEN** start is refused with that kind named, without launching it as Claude

#### Scenario: OMP argv profile

- **WHEN** an OMP profile specifies an absolute executable and the arguments `--mode rpc`

- **THEN** OMP receives exactly those arguments, unchanged and in order, over private stdio without an ACP wrapper, and Kumiko appends no argument

### Requirement: One runtime profile is the default

Exactly one runtime profile SHALL be the default when any exists. When no default is stored, Claude SHALL be preferred if detected, otherwise Codex, otherwise OMP. Existing defaults SHALL not change when another runtime is detected. Launch, fresh recovery and Continue SHALL select only a compatible runtime kind. A default that names a missing profile SHALL be reported unavailable, and no other profile SHALL be substituted silently.

#### Scenario: First start with the adapter installed

- **WHEN** the host starts with no stored default and a built-in Claude Code profile is detected

- **THEN** that profile is the default

#### Scenario: Default profile removed from PATH

- **WHEN** the stored default is the built-in profile and `claude-agent-acp` is absent from both PATH and the well-known install directories stated in the design at host start

- **THEN** the default is reported unavailable with the reason, and starting a Claude Code session asks the user to choose or add a profile

#### Scenario: Codex added beside existing Claude default

- **WHEN** Codex is detected and Claude is already the stored default

- **THEN** Claude remains the global default and Codex launch requires a compatible profile or explicit selection

#### Scenario: Fresh Claude recovery with Codex default

- **WHEN** a Claude saved pane requests New session and the global default is Codex

- **THEN** it asks for a compatible Claude profile and starts no Codex process

#### Scenario: Codex launcher with incompatible default

- **WHEN** the Codex launcher has only an incompatible global default

- **THEN** it asks for a compatible Codex profile and starts nothing until one is explicitly selected

#### Scenario: OMP is the only detected runtime

- **WHEN** the host starts with no stored default and only a built-in OMP profile is detected

- **THEN** the OMP profile becomes the default, and a later detected Claude or Codex does not replace it

### Requirement: Runtime capabilities are claimed only from evidence

For each Claude ACP session the host SHALL record the adapter name and version reported in ACP `initialize`. It SHALL claim a capability only when the adapter advertised it and that adapter version is on the qualified-versions list for it. Unqualified versions SHALL get only the safe baseline: prompt, streamed messages, tool activity, permission requests and cancel. Every other capability SHALL be shown unavailable with the reason. Source: ADR 0004 decision 2.

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

#### Scenario: Codex follows minimum-version compatibility

- **WHEN** Codex 0.166.0 or newer starts without an exact-version evidence row

- **THEN** native features use their supported contract and observed responses, not Claude's ACP advertisement or exact-version gate

#### Scenario: OMP follows minimum-version compatibility

- **WHEN** OMP at or above the minimum version starts without an exact-version evidence row

- **THEN** the run claims prompt, streamed replies and Stop from the native contract, and reports Continue, steering, permissions and Kumiko tools unavailable with the reason that this Kumiko version does not support them for OMP

## ADDED Requirements

### Requirement: Native OMP detection never borrows another application's private installation

The host SHALL offer an installed native OMP executable found on PATH or in the official installer's directory as a read-only built-in profile with the arguments `--mode rpc`. It SHALL NOT execute Windows batch or PowerShell shims to find it. Another application's private package directory SHALL NOT be an automatic discovery root. Explicit custom profiles SHALL remain supported. Source: D20, ADR 0004.

#### Scenario: OMP installed by its installer

- **WHEN** `omp.exe` exists in the official installer's directory on Windows and no other OMP is on PATH

- **THEN** the launcher offers an OMP built-in profile using that absolute executable and the arguments `--mode rpc`

#### Scenario: Only a shim exists

- **WHEN** discovery finds only `omp.cmd` or `omp.ps1` and no native executable

- **THEN** OMP is shown unavailable with explicit profile guidance, and no shell or script is run

#### Scenario: Only a private copy exists

- **WHEN** OMP exists only in another application's private package directory that is not on PATH

- **THEN** Kumiko does not offer it as a built-in profile, but accepts an explicit argv profile that names it
