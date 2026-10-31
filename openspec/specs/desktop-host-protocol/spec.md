# desktop-host-protocol Specification

## Purpose

Carry structured control and high-volume byte streams between the desktop and its host over one pipe pair, versioned and capability-negotiated, so control actions keep working while any data channel is saturated or stalled (ADR 0002, D6, D26).

## Requirements

### Requirement: Sessions start with a versioned hello
The first exchange SHALL be `hello`, carrying each side's protocol version range and capability set. The session SHALL use the highest common version and only capabilities both sides advertise. With no common version, the desktop SHALL show an incompatibility error naming both ranges.

#### Scenario: Compatible versions
- **WHEN** the desktop and the host advertise overlapping version ranges
- **THEN** the session uses the highest version in the overlap and the intersection of both capability sets

#### Scenario: No common version
- **WHEN** the version ranges do not overlap
- **THEN** the desktop shows an incompatibility error naming both ranges, and no other request is sent

#### Scenario: Request before hello
- **WHEN** a peer sends any request before `hello` has completed
- **THEN** the receiver answers with a protocol error and processes nothing else from that request

### Requirement: Capabilities gate methods
A peer SHALL reject a request whose method belongs to a capability that was not negotiated, with a method-not-available error. Release builds of the host SHALL not advertise test capabilities.

#### Scenario: Release host and a test method
- **WHEN** a release build of the host receives a test-unit or test-channel request
- **THEN** it answers method-not-available and starts nothing

#### Scenario: Test host advertises test capabilities
- **WHEN** a test build of the host completes `hello` with a desktop that requests test capabilities
- **THEN** the negotiated set includes them and their methods are served

### Requirement: Frames are bounded and channel-tagged
Every frame SHALL carry a length, a channel id and a kind, with a payload no larger than the maximum frame payload. Larger data SHALL be split across frames. A frame over the limit, or with an unknown kind, SHALL be a protocol violation that closes the connection with a visible error.

#### Scenario: Large output is split
- **WHEN** a sender has more data for a channel than the maximum frame payload
- **THEN** the data arrives as several frames each within the limit, and the receiver reassembles the exact bytes in order

#### Scenario: Oversized frame received
- **WHEN** a receiver reads a frame whose declared length exceeds the limit
- **THEN** it closes the connection, and the desktop shows *host lost* with a protocol-violation reason

### Requirement: Control frames are never queued behind bulk data
Each sender SHALL send a pending control frame before its next data frame, and SHALL take turns between data channels with data pending. A control message SHALL be delayed by at most one data frame per sender.

#### Scenario: Control round-trip under a saturating channel
- **WHEN** one test channel streams at full rate from the host and the desktop sends a control request
- **THEN** the response arrives within the control latency bound measured in the qualification test

#### Scenario: Control enqueued while bulk output is being written
- **WHEN** a control message is enqueued while a data frame is being written and more data frames are pending
- **THEN** at most one data frame of that sender precedes the control message's first frame on the wire

#### Scenario: Two busy data channels
- **WHEN** two test channels both have data pending
- **THEN** both receive frames, and neither waits for the other to drain

### Requirement: Data channels use per-channel credit
A sender SHALL send on a data channel no more bytes than the receiver has granted. A receiver SHALL keep reading the pipe into bounded per-channel queues. A consumer that stops reading SHALL stall only its own channel. Exceeding the granted credit SHALL be a protocol violation.

#### Scenario: One consumer stalls
- **WHEN** the desktop stops consuming one test channel while another test channel and control traffic continue
- **THEN** the stalled channel stops at its granted credit, the other channel keeps flowing, and control requests complete

#### Scenario: Stalled consumer resumes
- **WHEN** the stalled consumer starts reading again
- **THEN** the channel resumes and every byte arrives exactly once and in order

#### Scenario: Sender exceeds credit
- **WHEN** a peer sends more bytes on a channel than were granted
- **THEN** the receiver closes the connection with a protocol-violation reason

### Requirement: The host bounds memory for a slow desktop
The host SHALL cap open data channels and buffer at most the configured bound per channel and for pending control. An open beyond the cap SHALL be refused. On a data channel without credit, it SHALL stop reading its source. Pending control past its bound SHALL count as desktop lost.

#### Scenario: Desktop stops reading a channel
- **WHEN** a test channel's source produces data continuously and the desktop grants no credit
- **THEN** the host's buffered bytes for that channel stay within the per-channel bound

#### Scenario: Repeated channel opens
- **WHEN** the desktop keeps opening test channels without closing them
- **THEN** opens beyond the channel cap are refused with the reason `channel-cap`, and the host's total channel buffering stays within the cap times the per-channel bound

#### Scenario: Desktop stops reading the pipe entirely
- **WHEN** the desktop stops reading the pipe and the host's pending control exceeds its bound
- **THEN** the host terminates its units and exits, as for a lost connection

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
