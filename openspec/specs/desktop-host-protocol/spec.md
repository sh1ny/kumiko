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

### Requirement: Lifecycle, activity and draft methods are capability-gated
`app/quit` and `app/previousExit` SHALL need the `lifecycle` capability, `terminal/activity` the `terminal` capability, and `agent/draftSave`, `agent/draftLoad`, `agent/draftReset` and the `agent/draftStoreReady` notification the `agent` capability, each advertised by both peers in `hello`. Without it they SHALL fail with `method-not-available` and the rest of the session SHALL keep working. Source: ADR 0002.

#### Scenario: Both peers support lifecycle
- **WHEN** desktop and host both advertise `lifecycle`
- **THEN** `app/quit` and `app/previousExit` succeed

#### Scenario: Host without lifecycle
- **WHEN** a desktop that advertises `lifecycle` connects to a host that does not
- **THEN** `app/previousExit` fails with `method-not-available`, no previous-exit notice is shown, and quitting still closes the connection and ends every unit

### Requirement: Activity and draft requests are bounded
`terminal/activity` SHALL name at most 64 terminals and be answered within the activity deadline; ids past the bound SHALL be refused `invalid-params`. A draft's encoded JSON string contents, UTF-8 and escaping counted, SHALL be at most 256 KiB, so a draft always fits a control message; a larger `agent/draftSave` SHALL be refused `draft-too-large`, and one past the total draft bound `draft-cap`. Both SHALL stay answered within the control-latency bound under saturated output. Source: ADR 0002.

#### Scenario: Too many terminals
- **WHEN** the desktop sends `terminal/activity` naming 65 terminals
- **THEN** the host refuses it `invalid-params` and reads no process table

#### Scenario: Oversized draft
- **WHEN** the desktop sends `agent/draftSave` whose text encodes to one byte over 256 KiB of JSON string contents
- **THEN** the host refuses it `draft-too-large` and the stored draft is unchanged

#### Scenario: Unknown session
- **WHEN** the desktop sends `agent/draftSave` for a session id with no saved record
- **THEN** the host refuses it `unknown-session` and stores nothing

#### Scenario: Draft save under saturated output
- **WHEN** terminal A streams output continuously, session B's event channel has no credit, and the desktop saves session C's draft
- **THEN** the save is acknowledged within the control-latency bound

### Requirement: Draft storage never delays control or cleanup
A stalled or failed draft store SHALL NOT delay reconciliation, Stop, permission replies or desktop-loss cleanup. A draft operation past the draft deadline, or arriving while the store is not responding or full, SHALL fail `draft-unavailable`. A `stale-revision` refusal SHALL carry the stored revision. The host SHALL send `agent/draftStoreReady` whenever the store becomes available again. Source: ADR 0002, D7.

#### Scenario: Draft store stalls at start
- **WHEN** the previous host was killed with a unit still running and the next host's draft store is held inside its open
- **THEN** the next host reconciles that unit and accepts launches as usual, and draft requests fail `draft-unavailable` within the draft deadline

#### Scenario: Draft commit stalls
- **WHEN** a draft save is held inside its commit and the user presses Stop in session B and answers a permission request in session C
- **THEN** both are acknowledged within the control-latency bound, and the save fails `draft-unavailable` within the draft deadline

#### Scenario: Desktop lost while a draft commit stalls
- **WHEN** a draft save is held inside its commit and the desktop is killed
- **THEN** the host ends every unit and exits within the desktop-loss bound

#### Scenario: Stale save reports the stored revision
- **WHEN** the desktop saves a draft at revision 3 and the stored revision is 500
- **THEN** the host refuses it `stale-revision` with stored revision 500 and the stored draft is unchanged

#### Scenario: Store answers again
- **WHEN** the draft store was not responding and its stuck operation returns
- **THEN** the host sends `agent/draftStoreReady`, and the next draft save is accepted

#### Scenario: Reset refused while storage works
- **WHEN** the draft store is open and working and the desktop sends `agent/draftReset`
- **THEN** the host refuses it `draft-store-in-use` and every stored draft is unchanged

#### Scenario: Second reset during a reset
- **WHEN** drafts are disabled, a first `agent/draftReset` is held while the host replaces the draft worker, and a second `agent/draftReset` arrives
- **THEN** the second is refused `draft-store-in-use`, exactly one new draft worker serves draft requests, and a draft save acknowledged after `agent/draftStoreReady` is still stored after a host restart

### Requirement: Native Codex additions require a compatible peer

Codex start and Continue SHALL require `agent` and `codex` from both peers. Steering, structured questions and attributed child events SHALL additionally require `agent-extensions-v1` from both peers. Without it Codex start/Continue SHALL be refused before spawn, while Claude and terminals remain usable. Source: ADR 0002 additive capability rule.

#### Scenario: Compatible peers

- **WHEN** both peers advertise agent, codex and agent-extensions-v1

- **THEN** Codex methods and attributed events are available subject to runtime claims

#### Scenario: Older desktop

- **WHEN** a desktop lacks agent-extensions-v1

- **THEN** Codex is disabled with the missing capability named and no native requests are hidden or automatically answered

### Requirement: Extended control is sequenced and scoped to the native run

Steering and question answers SHALL identify the Kumiko run and originating native turn or request. Questions and resolutions SHALL travel on priority control, carrying the root and child identity where applicable. Late replies and stale runs SHALL be refused without native writes. Text and options SHALL obey encoded control bounds.

#### Scenario: Answer the current question

- **WHEN** the desktop answers a current question in run R and turn T

- **THEN** exactly its native request receives the answer and sequenced resolution retires its controls

#### Scenario: Prior run sends a late answer

- **WHEN** an answer arrives after Continue has created a replacement run

- **THEN** it is refused as stale and the replacement run receives nothing

### Requirement: Child events retain attribution under bounded delivery

The event channel SHALL support additive root/child/parent identities and child lifecycle events. Child tools SHALL be keyed by child and native item identity, with ordering preserved per native stream. A root summary SHALL remain visible; the full child viewer is deferred. Attribution overflow SHALL be reported as unavailable or incomplete, never silently reassigned.

#### Scenario: Two children use the same tool identifier

- **WHEN** children A and B both report native tool item X

- **THEN** their normalized identities remain distinct and each update changes only its own event

#### Scenario: Attribution capacity is exceeded

- **WHEN** more child identities arrive than the tracked-child bound

- **THEN** the root shows incomplete delegated activity, later control remains serviceable and no extra unbounded child map is retained

### Requirement: Codex control keeps the shared responsiveness contract

Stop, approval replies, question answers and close SHALL use priority control and stay within the existing control acknowledgement bound under saturated terminal output or a stalled transcript consumer. Native operation completion SHALL remain separately observable and SHALL NOT be equated with control acknowledgement.

#### Scenario: Stop while Codex output is stalled

- **WHEN** the Codex transcript consumer has no credit and the user presses Stop

- **THEN** the control acknowledgement arrives within the existing bound and native completion or timeout is reported separately

#### Scenario: Stalled native input

- **WHEN** Codex stdin cannot admit an answer or Stop sequence

- **THEN** control returns busy without reporting the native operation as performed

### Requirement: Active native turn identity reaches the desktop

The host SHALL include the current run and native turn identity in sequenced Codex Running state before offering Steer. Missing or stale identity SHALL disable steering; the desktop SHALL NOT infer it from transcript text.

#### Scenario: Running turn identity published

- **WHEN** a Codex turn is admitted and its identity is known

- **THEN** the sequenced state exposes that run and turn for explicit steering

#### Scenario: Delayed prior-turn state

- **WHEN** the desktop receives a stale Running state for an earlier turn

- **THEN** it ignores that state and cannot steer the completed turn

### Requirement: Delegated activity is reported in sequenced state
The host SHALL publish a bounded delegated-activity summary in sequenced agent state, including active child count, waiting child requests and an incomplete flag. Close, quit and Stop availability SHALL use that control state, independent of transcript credit. An incomplete registry SHALL NOT imply that no child work exists.

#### Scenario: Child starts
- **WHEN** a known child starts work
- **THEN** sequenced state reports active delegated work and the root's close and exit predicates include it

#### Scenario: Child starts with no transcript credit
- **WHEN** the event channel has no credit and a child of an Idle root starts
- **THEN** sequenced state reports active delegated work and closing the pane asks for confirmation
