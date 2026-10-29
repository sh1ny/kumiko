# Spec Delta

## Purpose

Carry structured control and high-volume byte streams between the desktop and its host over one pipe pair, versioned and capability-negotiated, so control actions keep working while any data channel is saturated or stalled (ADR 0002, D6, D26).

## ADDED Requirements

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
