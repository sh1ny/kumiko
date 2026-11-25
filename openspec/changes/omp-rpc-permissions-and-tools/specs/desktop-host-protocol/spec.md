# Spec Delta

## MODIFIED Requirements

### Requirement: Tool traffic never uses the desktop connection
Kumiko tool requests and results SHALL remain between the runtime and the host. Claude and Codex use the bridge and tool endpoint. OMP uses its private runtime stdio. Stalled desktop channels SHALL NOT delay another run's calls, and tool calls SHALL NOT delay desktop control. OMP frames behind a full event queue in their own session wait for normal event backpressure. Source: ADR 0002, ADR 0005 and ADR 0016.

#### Scenario: Tool call under saturated output
- **WHEN** a terminal saturates its output channel, another session's event channel has no credit, and session C calls `kumiko_session_info`
- **THEN** C's call is answered within the control-latency bound

#### Scenario: Busy tool clients do not delay Stop
- **WHEN** a client holds the per-connection maximum of in-flight tool calls and the user presses Stop in another session
- **THEN** Stop is acknowledged within the control-latency bound

#### Scenario: OMP tool request on a backpressured runtime pipe
- **WHEN** OMP sends a host tool request while the event queue of that same run is full
- **THEN** another session's Stop can be acknowledged while that queue is full. When credit resumes, OMP receives its tool result over private stdio without the tool request or result going through the desktop as tool traffic.
