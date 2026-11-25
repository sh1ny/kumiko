# Spec Delta

## MODIFIED Requirements

### Requirement: The host serves Kumiko tools on a per-user local endpoint
The host SHALL run one Kumiko tool service for its lifetime. Its only listening surface SHALL be a per-user local MCP endpoint: a named pipe on Windows that only the current OS user can open and that rejects remote clients, and a Unix domain socket in the owner-only profile directory on Linux and macOS. The endpoint SHALL be removed when the host exits. OMP SHALL use only its private runtime connection for Kumiko tools. Source: ADR 0005 decision 2 and consequences; owner decision S2.

#### Scenario: Endpoint exists while the host runs
- **WHEN** the host has started with a usable profile
- **THEN** the endpoint accepts a connection from a process of the same OS user, and no TCP or UDP port is opened by the host

#### Scenario: Endpoint access is limited to the current user
- **WHEN** the host has created its endpoint
- **THEN** on Windows the pipe's access list read back from the OS grants access only to the current user's SID and the local system account, and the pipe rejects remote clients; on Linux and macOS the socket's directory is accessible only to its owner and the socket's mode is `0600`

#### Scenario: Endpoint cannot be created
- **WHEN** the host cannot create the MCP endpoint
- **THEN** the host still starts, logs the reason and reports tools unavailable for sessions that use MCP. OMP still registers and serves its authorized tools over private RPC.

#### Scenario: Endpoint is removed on exit
- **WHEN** the host exits after the desktop goes away
- **THEN** the socket file no longer exists (Linux and macOS) and the pipe name no longer accepts connections (Windows)

#### Scenario: Stale socket from a killed host
- **WHEN** a host starts and its profile holds a socket file left by a host that was killed
- **THEN** the new host replaces it and accepts connections on it

### Requirement: Each live session run receives a Kumiko MCP entry

When the host creates or continues a Claude or Codex session while its tool endpoint is available, it SHALL pass exactly one stdio MCP server entry named `kumiko` through the runtime-specific session configuration: ACP session requests or native Codex per-run App Server configuration. The entry's command SHALL be the bundled host executable in `mcp-bridge` mode. OMP SHALL get no MCP entry or MCP grant. Kumiko SHALL NOT write or change any repository file or runtime configuration to deliver its tools. Source: ADR 0005 decisions 2 and 6; D14, D15.

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

#### Scenario: OMP run without tool delivery

- **WHEN** the user starts an OMP session
- **THEN** the run gets no `kumiko` MCP entry, bridge secret or bridge process, and no workspace or OMP configuration file is created or changed to register Kumiko tools

### Requirement: Tool connections are authenticated by a per-run session secret
Each live session run using MCP SHALL get a fresh random secret of at least 256 bits. It SHALL be passed only through the MCP entry's environment, never stored, logged, sent to the desktop or written to a repository file. The secret SHALL map to exactly one live session run, and SHALL be revoked when that run's adapter exits, the session is closed, or the host exits. A connection SHALL present its secret before any MCP message is processed. For OMP the host SHALL use the identity of the private connection it opened for the run, never a transferable credential or a caller-supplied session identifier. Source: ADR 0005 decision 3; owner decision S2.

#### Scenario: Correct secret
- **WHEN** a bridge connects with the secret of a live session run
- **THEN** the connection is accepted and its MCP requests are served for that session only

#### Scenario: Wrong secret
- **WHEN** a client connects with a secret that matches no live session run
- **THEN** the host answers with an authentication refusal, closes the connection, processes no MCP message from it, and no session's status changes

#### Scenario: Missing secret
- **WHEN** a client connects and sends an MCP request without first presenting a secret, or sends nothing within the authentication deadline
- **THEN** the host closes the connection without processing any MCP message

#### Scenario: Secret of a closed session
- **WHEN** a client presents the secret of a session run that has been closed or whose adapter has exited
- **THEN** the connection is refused as for a wrong secret

#### Scenario: Secret stays out of the record and the desktop
- **WHEN** a session using MCP is started and then listed through the session records method and observed in its control messages
- **THEN** neither the stored record nor any message to the desktop contains the secret

#### Scenario: Two OMP runs use the same native call id
- **WHEN** two OMP connections carry a call with the same native id, or one call supplies another run's identity as an argument
- **THEN** a valid call returns only its connection's own run information. A call with the extra identity argument is refused and returns no other run's data.

### Requirement: The Kumiko tools status reports only what was observed
Each live session SHALL show one Kumiko tools status. MCP runs use *not yet used*, *connected*, *not started by the adapter*, or *unavailable* with a reason. A registered OMP run stays *not yet used* until a call succeeds and never reports a bridge startup state. *Connected* SHALL require a successful authorized tool call in that run. Source: ADR 0005 decision 5.

#### Scenario: Successful call connects
- **WHEN** a session starts, and later its bridge authenticates and a `kumiko_session_info` call succeeds
- **THEN** the pane shows *not yet used* until the call succeeds, and *Kumiko tools: connected* afterwards

#### Scenario: Bridge listed tools but never called one
- **WHEN** a bridge authenticated and served a tool list, but no tool call has succeeded
- **THEN** the pane does not show *connected*

#### Scenario: Adapter never starts the bridge
- **WHEN** an MCP session's first turn ends and no bridge has authenticated for that session run
- **THEN** the pane shows *Kumiko tools: not started by the adapter*; a later authentication changes it to *not yet used*, and a later successful call to *connected*

#### Scenario: Bridge authenticated during session creation
- **WHEN** the bridge authenticates before `session/new` returns, and the first turn ends without any tool call
- **THEN** the pane shows *not yet used*, never *not started by the adapter*

#### Scenario: Endpoint connection held open by a client
- **WHEN** a local client connects to the endpoint and then neither sends its secret nor closes
- **THEN** the host closes that connection within the authentication deadline on every OS, and the connection no longer counts against the endpoint's connection limit

#### Scenario: Known failure for the adapter version
- **WHEN** a session starts with an adapter name and version whose tool delivery is recorded as failed
- **THEN** the pane shows *Kumiko tools unavailable for <adapter> <version>: <recorded failure>*, and never *connected* unless a call actually succeeds

#### Scenario: Continue resets the status
- **WHEN** a session showing *connected* exits and the user continues it
- **THEN** the new run shows *not yet used* until a call succeeds in that run

#### Scenario: OMP registers but has not used a tool
- **WHEN** OMP confirms the catalog and ends a turn without a successful host call
- **THEN** the pane still shows *not yet used*. A later successful `kumiko_session_info` result changes it to *connected* in the same run.

## ADDED Requirements

### Requirement: OMP registers and invokes authorized Kumiko tools over private RPC
The host SHALL register its allowed catalog once per OMP run. A call SHALL require confirmed registration and a live, bound run. The host SHALL use the same role, owner, immutable target and argument checks as MCP. Failed registration SHALL leave tools unavailable without overwriting another tool or retrying registration. Source: direction D14 and D15; owner decision S2.

#### Scenario: OMP calls the registered tool
- **WHEN** an OMP run confirms registration and invokes `kumiko_session_info` with empty arguments after its session record exists
- **THEN** the result identifies the calling run's saved Kumiko session, coding role, adapter and version, and original target, even after the user switches workspaces

#### Scenario: Registration unavailable
- **WHEN** OMP rejects registration, reports a name collision, returns a mismatched acknowledgement or does not confirm before its deadline while the transport remains live
- **THEN** chat stays usable and tools report unavailable with a bounded reason. Further callbacks do not run tools. Kumiko sends no second registration and overwrites no existing definition.

#### Scenario: Host tool call refused
- **WHEN** a callback names an unknown tool or supplies invalid arguments, or arrives before the run is bound or after authority is withdrawn
- **THEN** no operation runs and the tools status cannot advance. If the connection is still usable and the request can be correlated, OMP receives an error for that id.

#### Scenario: Host tool callback is cancelled or transport is lost
- **WHEN** OMP withdraws a callback, or the private connection ends
- **THEN** withdrawal cannot trigger a second reply or a successful result for another callback. An ended connection loses all tool authority, and a late result cannot update another run's status.
