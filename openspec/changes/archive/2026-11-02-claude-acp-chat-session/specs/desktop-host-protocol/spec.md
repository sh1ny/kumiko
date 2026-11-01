# Spec Delta

## ADDED Requirements

### Requirement: Each agent session has one host-to-desktop event channel
Starting or continuing an agent session SHALL give it one host-to-desktop data channel carrying its transcript events in order, under the existing per-channel credit. The host SHALL allocate the channel id and return it in the result. The host SHALL send no frame on it until the desktop has attached the session.

#### Scenario: Start a session
- **WHEN** the desktop starts an agent session and the adapter creates it
- **THEN** the result names a Kumiko session id and an event channel id distinct from every other open channel

#### Scenario: Channel limit reached
- **WHEN** a start or continue would exceed the connection's channel limit
- **THEN** it is refused with a channel-limit error, no adapter is started, and existing channels are unaffected

#### Scenario: Desktop never attaches
- **WHEN** the desktop receives a start result and sends no attach for that session within the attach timeout
- **THEN** the host terminates the session's process tree, frees the channel, and keeps the saved record

### Requirement: Agent state, requests and results travel as control messages
Turn state changes, permission requests, Stop results and session exit SHALL be control messages naming the Kumiko session id, never data on the event channel. Prompt, Stop, permission reply and close for an unknown or closed session SHALL fail with an unknown-session error and change nothing.

#### Scenario: Permission request while the event channel is stalled
- **WHEN** a session's event channel has no credit, the host's event queue for it is below its bound, and the adapter raises a permission request
- **THEN** the desktop receives the request as a control notification, and its reply reaches the adapter

#### Scenario: Event queue full when a permission request is raised
- **WHEN** a session's event channel has no credit, its host event queue has reached its bound so the host has stopped reading the adapter's output, and the adapter writes a permission request
- **THEN** the request is not shown until the desktop consumes events again and then appears as a control notification; Stop sent meanwhile reports *Stop not confirmed* after the stop deadline unless consumption resumes first, and close is acknowledged within the control-latency bound and ends the session

#### Scenario: Reply to an answered request
- **WHEN** the desktop replies to a permission request that was already answered or cancelled
- **THEN** the reply fails with an unknown-request error and the adapter receives nothing

#### Scenario: Stop an unknown session
- **WHEN** the desktop sends Stop for a session id that was closed
- **THEN** the request fails with unknown-session, and no other session is affected

### Requirement: Agent methods are capability-gated
Runtime profile and agent session methods SHALL be available only when both peers advertise the `agent` capability in `hello`. Without it they SHALL fail with `method-not-available`, and the rest of the session SHALL keep working.

#### Scenario: Both peers support agents
- **WHEN** desktop and host both advertise the `agent` capability
- **THEN** runtime profile and agent methods succeed

#### Scenario: Host without the capability
- **WHEN** a desktop that advertises `agent` connects to a host that does not
- **THEN** agent methods fail with `method-not-available`, the **Claude Code** launcher entry is disabled with that reason, and terminal and workbench methods keep working

### Requirement: Agent control stays responsive under saturated output
With one terminal saturating its output channel and another channel's consumer stalled, Stop, permission replies and close for an agent session SHALL be acknowledged within the control-latency bound, and other channels SHALL keep flowing.

#### Scenario: Stop under saturation
- **WHEN** terminal A streams output continuously, session B's event channel has no credit, and the user presses Stop in session C
- **THEN** the Stop request is acknowledged within the control-latency bound, and C's event channel keeps flowing

#### Scenario: Permission reply under saturation
- **WHEN** terminal A streams output continuously and the user answers a permission request in session C
- **THEN** the reply is acknowledged within the control-latency bound and reaches C's adapter
