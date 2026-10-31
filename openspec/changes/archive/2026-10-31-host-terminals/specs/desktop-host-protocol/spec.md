# Spec Delta

## ADDED Requirements

### Requirement: Each terminal has one data channel per direction
Opening a terminal SHALL give it two data channels: host-to-desktop for output and desktop-to-host for input, each under the existing per-channel credit. Both channel ids SHALL be allocated by the host and returned in the open result, so the two peers never choose the same id.

#### Scenario: Open a terminal
- **WHEN** the desktop opens a terminal and the launch succeeds
- **THEN** the result names a terminal id, an output channel id and an input channel id, each distinct from every other open channel

#### Scenario: Open several terminals at once
- **WHEN** the desktop sends several terminal open requests concurrently
- **THEN** every returned channel id is unique across all open channels, and no frame is delivered to the wrong terminal

#### Scenario: Channel limit reached
- **WHEN** a terminal open would exceed the connection's channel limit, including when only one of its two channels would fit
- **THEN** the open is refused with a channel-limit error, no shell is started, and existing channels are unaffected

### Requirement: No terminal channel traffic precedes the desktop's attach
The host SHALL send no data and no credit on a terminal's channels until the desktop has registered both channel ids and sent attach for that terminal. A terminal not attached within the attach timeout stated in the design SHALL be closed by the host, with its processes terminated.

#### Scenario: Open result and first credit arrive together
- **WHEN** the open result and the frames that follow attach arrive at the desktop in one read
- **THEN** the desktop has registered both channels before any frame for them is processed, and the connection stays open

#### Scenario: Desktop never attaches
- **WHEN** the desktop receives an open result and then sends no attach for that terminal
- **THEN** after the attach timeout the host terminates the terminal's process tree and frees its channel slots, and no process from it remains

### Requirement: Terminal control messages name the terminal
Resize, close and shell exit SHALL be control messages that name the terminal id. Resize and close requests for a terminal id that is unknown or already closed SHALL fail with an unknown-terminal error and change nothing.

#### Scenario: Resize a terminal
- **WHEN** the desktop sends resize with a terminal id, 120 columns and 40 rows
- **THEN** the host applies that size to that terminal's pseudo-terminal only

#### Scenario: Shell exits
- **WHEN** a terminal's shell prints a final line and exits with status 3
- **THEN** the desktop receives every output byte, including the final line, before an exit notification naming the terminal and status 3 that reports the output as complete, and the channels stay open until the desktop releases the terminal

#### Scenario: Output cannot be read to the end
- **WHEN** a shell exits but its pseudo-terminal does not reach end-of-output within the design's active read deadline
- **THEN** every byte already read is delivered, and the exit notification follows them and reports the output as incomplete

#### Scenario: Shell exits while the desktop grants no credit
- **WHEN** a shell exits while its output channel has no credit and output is queued in the host
- **THEN** no output is dropped, including bytes still unread in the pseudo-terminal while the host waits for credit, and the exit notification follows the last byte once credit returns and reports the output as complete

#### Scenario: Close is acknowledged before termination completes
- **WHEN** the desktop sends close for a terminal whose program ignores SIGTERM
- **THEN** the close is acknowledged within the control-latency bound, and an exit notification with reason `closed` follows once the process tree is terminated and its cleanup is confirmed within the design's overall settlement deadline, or a close-failed notification follows if cleanup cannot be confirmed by then

#### Scenario: Close an already closed terminal
- **WHEN** the desktop sends close for a terminal id whose shell has already exited and been closed
- **THEN** the request fails with unknown-terminal, and no other terminal is affected

#### Scenario: Invalid size
- **WHEN** the desktop sends resize with 0 columns or more rows than the stated maximum
- **THEN** the request fails with an invalid-size error, and the pseudo-terminal keeps its previous size

### Requirement: Terminal methods are capability-gated
Shell profile and terminal methods SHALL be available only when both peers advertise the terminal capability in `hello`. Without it they SHALL fail with `method-not-available`, and the rest of the session SHALL keep working.

#### Scenario: Both peers support terminals
- **WHEN** desktop and host both advertise the terminal capability
- **THEN** profile and terminal methods succeed

#### Scenario: Host without the capability
- **WHEN** a desktop that advertises the terminal capability connects to a host that does not
- **THEN** terminal methods fail with `method-not-available`, the Terminal launcher entry is disabled with that reason, and workbench methods keep working

### Requirement: Terminal control stays responsive under saturated output
With one terminal saturating its output channel and another terminal's consumer stalled, resize and close requests for any terminal SHALL be acknowledged within the control-latency bound stated in the design, termination SHALL complete within the overall settlement deadline, and output on other terminals SHALL keep flowing.

#### Scenario: Saturating and stalled terminals
- **WHEN** terminal A streams output continuously and terminal B's desktop consumer has stopped granting credit
- **THEN** resize and close requests for terminal C are each acknowledged within the stated bound, and output on terminal C keeps flowing

#### Scenario: Close the stalled terminal
- **WHEN** the user closes terminal B while its output channel has no credit
- **THEN** the close is acknowledged within the stated bound, B's process tree is terminated within the overall settlement deadline without waiting for credit, and A keeps streaming
