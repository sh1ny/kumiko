# ADR 0002: Versioned, capability-negotiated desktop-host protocol over the host's stdio

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D6, D9, D26; ADR 0001

## Context

The desktop and its child host (ADR 0001) exchange two kinds of traffic:
- structured control: commands, session events, questions/approvals, store queries;
- high-volume terminal byte streams.

D6 keeps terminal I/O separate from structured protocol frames. The desktop and its bundled host normally ship together, but D26's habit of negotiating rather than assuming versions also protects a future remote host. Local listening ports are a security surface that other local processes can reach.

## Decision

1. **Transport:** the host's stdin/stdout pipes, opened by the desktop at launch. The host opens no listening port or socket for this contract. stderr carries host diagnostics only (bounded, content-free per D46).
2. **Framing:** length-prefixed binary frames, each carrying a channel id and a kind. Channel 0 carries the control protocol. Each terminal gets its own channel carrying raw bytes in each direction. Resize and close are control messages that name the channel.
3. **Control protocol:** JSON-RPC 2.0 messages (requests, responses, notifications) on channel 0. Message types are defined once in the `host_protocol` package and used by both sides. Neither side hand-writes JSON for them.
4. **Handshake:** the first exchange is `hello`, carrying the protocol version range and capability set from each side. The session proceeds on the highest common version, and only mutually advertised capabilities are used. With no common version the desktop shows an incompatibility error. It never falls back to guessing.
5. **Flow control and progress:**
   - **Bounded frames.** Every frame has a maximum payload size, and large terminal output is split across frames, so no single frame occupies the pipe for long.
   - **Fair writer with reserved control progress.** Each side's writer sends a pending control frame before the next data frame. Between data channels it takes turns round-robin. Saturated terminal output therefore delays a control message by at most one data frame.
   - **Per-channel credit.** Data channels (terminals, session event streams) use credit-based flow control: a sender never sends more on a channel than the receiver has granted.
   - **Receivers never block on one channel.** A receiver always keeps draining the pipe into bounded per-channel queues. Senders respect credit, so the queues cannot overflow. A stalled consumer stops granting credit on its own channel only, and other channels and control keep moving.

   The host buffers within the bounds in the architecture's resource table and never grows unbounded memory for a slow or absent desktop. Numeric frame, credit and queue sizes are set by the change that introduces the transport.
6. **Evolution:** additive changes take a new capability flag. Breaking changes bump the protocol version. Unknown fields are preserved when relayed and ignored when not understood.

## Rejected alternatives

- **Localhost TCP/WebSocket.** Any local process can reach it, so it needs its own authentication. It also costs firewall prompts on Windows and gives a remote-host feel without remote-host security.
- **Terminal bytes base64-encoded inside JSON-RPC.** It inflates large-output traffic by a third and puts control messages behind bulk output on one logical stream.
- **Dart isolate ports / platform channels.** Only possible in-process, which ADR 0001 rejects.
- **gRPC/protobuf.** A heavier toolchain for one local peer pair. Revisit if a remote host makes a schema-first IDL worth it.

## Consequences

- A future remote host can reuse framing and the control protocol over an authenticated transport. Remote transport and its authentication are a separate decision.
- The protocol needs a test harness that runs the real host executable from Dart tests, so contract tests do not depend on Flutter.
- Throughput and latency are measured in M1 against a large-output terminal workload before the framing is relied on.
- M1 qualification also proves progress under two conditions: one terminal saturating output, and another terminal whose consumer is stalled. In both, control round-trips (stop, permission reply, resize, close) still complete, and the other channels keep flowing.

## Reversal cost

Medium. Transport and framing sit behind one package on each side. Message semantics, versioning and capability negotiation are expensive to change once sessions depend on them.
