# Spec Delta

## Purpose

Gives agent sessions that Kumiko launches authenticated, per-call authorized access to Kumiko operations through one host-owned MCP tool service, and reports honestly whether that access works in each session.

## ADDED Requirements

### Requirement: The host serves Kumiko tools on a per-user local endpoint
The host SHALL run one Kumiko tool service for its lifetime. Its only listening surface SHALL be a per-user local endpoint: a named pipe on Windows that only the current OS user can open and that rejects remote clients, and a Unix domain socket in the owner-only profile directory on Linux and macOS. The endpoint SHALL be removed when the host exits. Source: ADR 0005 decision 2 and consequences.

#### Scenario: Endpoint exists while the host runs
- **WHEN** the host has started with a usable profile
- **THEN** the endpoint accepts a connection from a process of the same OS user, and no TCP or UDP port is opened by the host

#### Scenario: Endpoint access is limited to the current user
- **WHEN** the host has created its endpoint
- **THEN** on Windows the pipe's access list read back from the OS grants access only to the current user's SID and the local system account, and the pipe rejects remote clients; on Linux and macOS the socket's directory is accessible only to its owner and the socket's mode is `0600`

#### Scenario: Endpoint cannot be created
- **WHEN** the endpoint cannot be created at host start (for example a socket path longer than the platform limit)
- **THEN** the host still starts, the failure and its reason are written to the host log, and every session shows Kumiko tools *unavailable* with that reason

#### Scenario: Endpoint is removed on exit
- **WHEN** the host exits after the desktop goes away
- **THEN** the socket file no longer exists (Linux and macOS) and the pipe name no longer accepts connections (Windows)

#### Scenario: Stale socket from a killed host
- **WHEN** a host starts and its profile holds a socket file left by a host that was killed
- **THEN** the new host replaces it and accepts connections on it

### Requirement: Each live session run receives a Kumiko MCP entry
When the host creates or continues a session while its tool endpoint is available, it SHALL pass exactly one stdio MCP server entry named `kumiko` in `session/new`, `session/load` or `session/resume`. The entry's command SHALL be the bundled host executable in `mcp-bridge` mode. Kumiko SHALL NOT write or change any repository file or runtime configuration to deliver it. Source: ADR 0005 decisions 2 and 6; D14, D15.

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

### Requirement: Tool connections are authenticated by a per-run session secret
Each live session run SHALL get a fresh random secret of at least 256 bits. It SHALL be passed only through the MCP entry's environment, never stored, logged, sent to the desktop or written to a repository file. The secret SHALL map to exactly one live session run, and SHALL be revoked when that run's adapter exits, the session is closed, or the host exits. A connection SHALL present its secret before any MCP message is processed. Source: ADR 0005 decision 3.

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
- **WHEN** a session is started and then listed through the session records method and observed in its control messages
- **THEN** neither the stored record nor any message to the desktop contains the secret

### Requirement: Every tool call is authorized against its session
The host SHALL check every tool call, at the time of the call, against the calling session's role, owner and target. A tool the role does not permit SHALL be absent from that session's tool list and SHALL be rejected if called. Identifiers in tool arguments SHALL NOT grant access. Source: ADR 0005 decision 4; backlog `agent-tool-access` *Kumiko tool authority is authenticated and scoped* and *Tool operations respect the session role*.

#### Scenario: Permitted tool for the coding role
- **WHEN** an authenticated `coding` session lists its tools and calls `kumiko_session_info`
- **THEN** the list contains `kumiko_session_info` and the call succeeds

#### Scenario: Tool not permitted for the role
- **WHEN** an authenticated session calls a tool name its role does not permit, or that does not exist
- **THEN** the call returns an MCP error naming the tool as unavailable, and nothing is changed

#### Scenario: Session closed while connected
- **WHEN** a bridge authenticated for a session, the user closes that session, and a further call arrives on that connection
- **THEN** the call is rejected and the connection is closed

#### Scenario: Arguments name another session
- **WHEN** a session calls `kumiko_session_info` with arguments that name another session's id or workspace
- **THEN** the result describes only the calling session, or the call is rejected for invalid arguments; it never returns another session's data

### Requirement: A read-only session information tool is available
The tool service SHALL offer `kumiko_session_info` to `coding` sessions. It SHALL take no arguments, be marked read-only, change no state, and return the calling session's Kumiko session id, role, runtime kind, adapter name and version, and target workspace path.

#### Scenario: Call returns the calling session
- **WHEN** a session whose target is workspace W calls `kumiko_session_info`
- **THEN** the result contains that session's id, role `coding`, runtime kind `claude-code`, its adapter name and version, and W's absolute path

#### Scenario: Call during session creation
- **WHEN** the adapter starts the bridge and calls the tool before `session/new` has returned its native session id
- **THEN** the call answers once the session record exists, with that record's session id; if the start fails instead, the call fails with *session unavailable*; it never returns a different or empty session id

#### Scenario: Target kept after focus moves
- **WHEN** the user focuses another workspace and the session then calls `kumiko_session_info`
- **THEN** the result still names the session's original target workspace

### Requirement: The Kumiko tools status reports only what was observed
Each live session SHALL have one Kumiko tools status shown in its chat pane: *not yet used*, *connected*, *not started by the adapter*, or *unavailable* with a reason. *connected* SHALL be shown only after an authenticated tool call succeeded in that session run. Source: ADR 0005 decision 5.

#### Scenario: Successful call connects
- **WHEN** a session starts, and later its bridge authenticates and a `kumiko_session_info` call succeeds
- **THEN** the pane shows *not yet used* until the call succeeds, and *Kumiko tools: connected* afterwards

#### Scenario: Bridge listed tools but never called one
- **WHEN** a bridge authenticated and served a tool list, but no tool call has succeeded
- **THEN** the pane does not show *connected*

#### Scenario: Adapter never starts the bridge
- **WHEN** a session's first turn ends and no bridge has authenticated for that session run
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

### Requirement: The bridge ends with its session or its host
The `mcp-bridge` process SHALL run as a descendant of its session's adapter inside that session's contained unit. It SHALL exit when its standard input closes or its endpoint connection ends, and SHALL never itself open a listening surface. Source: ADR 0001, ADR 0005 decision 2, ADR 0012 decision 1.

#### Scenario: Session closed
- **WHEN** the user closes a session whose bridge is connected
- **THEN** the bridge process has exited when the close settles, with the rest of the session's unit

#### Scenario: Host killed
- **WHEN** the host is killed while a bridge is connected
- **THEN** the bridge exits once its endpoint connection ends, and the next host reconciliation leaves no bridge process running

#### Scenario: Bridge started without a host
- **WHEN** the bridge is started with an endpoint that does not exist or a missing endpoint variable
- **THEN** it writes one diagnostic line to standard error and exits with a non-zero status without reading standard input
