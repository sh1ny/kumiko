# Spec Delta

## ADDED Requirements

### Requirement: Agent control carries the Kumiko tools status
The host SHALL include each live session's Kumiko tools status, and its reason when *unavailable*, in the start and Continue results and in the session's sequenced state messages. A status change SHALL take the next number in the session's state sequence. A desktop that does not know the field SHALL keep working.

#### Scenario: Status change reaches the desktop
- **WHEN** a session's first successful tool call happens
- **THEN** the desktop receives a state message for that session with the next sequence number and tools status `connected`

#### Scenario: Stale status message
- **WHEN** the desktop receives a state message whose sequence is lower than one it has already applied for that session
- **THEN** it ignores the message, including its tools status

#### Scenario: Older desktop
- **WHEN** a desktop that predates the field receives a state message carrying a tools status
- **THEN** it applies the turn state and ignores the extra field without error

### Requirement: Tool traffic never uses the desktop connection
Tool calls SHALL travel only between bridge and host over the tool endpoint. Saturated or stalled desktop channels SHALL NOT delay tool calls, and tool calls SHALL NOT delay desktop control. Source: ADR 0002, ADR 0005.

#### Scenario: Tool call under saturated output
- **WHEN** a terminal saturates its output channel, another session's event channel has no credit, and session C calls `kumiko_session_info`
- **THEN** C's call is answered within the control-latency bound

#### Scenario: Busy tool clients do not delay Stop
- **WHEN** a client holds the per-connection maximum of in-flight tool calls and the user presses Stop in another session
- **THEN** Stop is acknowledged within the control-latency bound
