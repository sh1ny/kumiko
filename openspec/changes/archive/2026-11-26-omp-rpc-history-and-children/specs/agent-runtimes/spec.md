# Spec Delta

## MODIFIED Requirements

### Requirement: Runtime capabilities are claimed only from evidence

For each Claude ACP session the host SHALL record the adapter name and version reported in ACP `initialize`. It SHALL claim a capability only when the adapter advertised it and that adapter version is on the qualified-versions list for it. Unqualified versions SHALL get only the safe baseline: prompt, streamed messages, tool activity, permission requests and cancel. Every other capability SHALL be shown unavailable with the reason. Source: ADR 0004 decision 2.

#### Scenario: Qualified version

- **WHEN** the user chooses Continue on a saved session, and the adapter started for it reports a name and version on the qualified list for `load` and advertises `loadSession`
- **THEN** that run claims `load`, and the earlier conversation is loaded

#### Scenario: Unqualified version

- **WHEN** the user chooses Continue, and the adapter started for it reports a version that is not on the qualified list while advertising `loadSession` and `resume`
- **THEN** the pane shows *resume unavailable: adapter version not qualified* with that version, the adapter is terminated, and the saved record is unchanged

#### Scenario: Unqualified version in a new session

- **WHEN** the user starts a new session and the adapter reports a version that is not on the qualified list
- **THEN** the session runs with the baseline only, and its capabilities show load and resume as unavailable with the version named

#### Scenario: Advertised feature missing

- **WHEN** the user chooses Continue, and the adapter started for it is a qualified version but advertises neither `loadSession` nor `sessionCapabilities.resume` in that run
- **THEN** the pane shows *resume unavailable: not advertised by the adapter*, and the adapter is terminated

#### Scenario: Adapter speaks another protocol version

- **WHEN** the adapter answers `initialize` with a protocol version other than 1
- **THEN** the start fails with *unsupported ACP protocol version* naming the version, and the adapter's process tree is terminated

#### Scenario: Codex follows minimum-version compatibility

- **WHEN** Codex 0.166.0 or newer starts without an exact-version evidence row
- **THEN** native features use their supported contract and observed responses, not Claude's ACP advertisement or exact-version gate

#### Scenario: OMP follows minimum-version compatibility

- **WHEN** OMP at or above the minimum version starts without an exact-version evidence row
- **THEN** the session accepts and streams a prompt, can Stop it, and shows a supported approval and root tool card when OMP emits them. A successful registration or call updates Kumiko tools status without any exact-version evidence row. Native Continue, history and child activity depend on the record and observed OMP responses; steering remains unavailable.
