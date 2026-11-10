## MODIFIED Requirements



### Requirement: Each live session run receives a Kumiko MCP entry

When the host creates or continues a session while its tool endpoint is available, it SHALL pass exactly one stdio MCP server entry named `kumiko` through the runtime-specific session configuration: ACP session requests or native Codex per-run App Server configuration. The entry's command SHALL be the bundled host executable in `mcp-bridge` mode. Kumiko SHALL NOT write or change any repository file or runtime configuration to deliver it. Source: ADR 0005 decisions 2 and 6; D14, D15.



#### Scenario: New session gets the entry

- **WHEN** the user starts a Claude Code session in a workspace

- **THEN** `session/new` carries one `mcpServers` entry named `kumiko` whose command is the host executable with the bridge argument, and no file in the workspace is created or changed



#### Scenario: Continue gets a new entry

- **WHEN** the user continues a saved session through load or resume

- **THEN** that request carries a `kumiko` entry whose secret differs from every earlier run of that session



#### Scenario: Endpoint unavailable

- **WHEN** the host's tool endpoint could not be created and the user starts a session

- **THEN** `session/new` carries an empty `mcpServers` list, and the session shows Kumiko tools *unavailable* with the endpoint's reason



#### Scenario: Adapter rejects session creation

- **WHEN** the adapter answers `session/new` with an error

- **THEN** the start fails with the adapter's error as it does today, no session record is stored, the secret minted for that start is revoked, and no second `session/new` is sent





#### Scenario: Codex receives its bridge configuration

- **WHEN** a Codex run starts or continues with the endpoint available

- **THEN** its App Server receives exactly one kumiko MCP entry with the current run secret before the native thread is usable, without changing user or repository configuration files



#### Scenario: Codex configuration cannot be applied

- **WHEN** native per-run MCP configuration is unsupported or invalid

- **THEN** the run reports tools unavailable with the reason, never connected, and any unused grant is revoked



#### Scenario: Child uses inherited Kumiko tools

- **WHEN** a Codex child invokes the inherited kumiko bridge

- **THEN** authorization uses its root Kumiko run's role and immutable target and does not claim a separate child authority



#### Scenario: Unrelated commands cannot read bridge secret

- **WHEN** a fixture model command and an unrelated MCP server inspect their environments

- **THEN** neither sees the root bridge secret while the kumiko bridge receives it through its entry-only environment, and the secret appears in no file the runtime wrote during the run



#### Scenario: User already defines kumiko MCP

- **WHEN** effective user or workspace configuration defines an MCP server named kumiko, or its absence cannot be verified

- **THEN** tool delivery is unavailable with a conflict reason, no user entry is overwritten and the unused grant is revoked


#### Scenario: Child bridge connection cap
- **WHEN** more child bridges than the per-grant bound authenticate
- **THEN** extra connections are refused busy, the root shows child tools unavailable and no other session's tools change
