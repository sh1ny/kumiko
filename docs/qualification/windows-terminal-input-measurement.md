# Windows terminal input retention measurement

Observed on Windows, 2026-11-10, during `codex-app-server-session` group 3.
The terminal buffering implementation and original qualification test were
unchanged by that group's routing work. The existing architecture limit remains
576 KiB (589,824 bytes) per terminal. This record qualifies Windows only.

## Original failure and inconclusive rerun

The coordinator's `mise.exe run check` passed. Its subsequent
`mise.exe run test:host` failed the terminal qualification assertion at line 279:
2,816 KiB (2,883,584 bytes) of completed input writes, `blocked=true`, exceeded
the test's 704 KiB (720,896 bytes = 576 KiB plus an assumed 128 KiB OS allowance).
The other 624 host tests passed; 13 were skipped.

The isolated command, from `packages/host`, was:

```text
mise.exe exec -- dart test test/it/terminal_qualification_test.dart --plain-name 'a shell that stops reading input bounds what the host queues'
```

It completed 8,192 KiB of writes with `blocked=false`, then marked the test
skipped: 0 passed, 1 skipped. A prior worker's 624-pass/14-skip run had the same
unobservable acceptance result. Neither skipped run cleared the original failure.

## Cause and corrected measurement

`ChannelWriter.write` completes after its last frame reaches and flushes the
desktop transport sink. That is neither host queue admission nor host retention.
Completed writes can include desktop/transport buffering and bytes already
accepted by the OS/ConPTY. ConPTY acceptance varies with scheduling and need not
stop at the former test's assumed OS allowance. Aggregate completed writes cannot
prove or disprove the host-owned 576 KiB bound.

The host pauses its input subscription while its PTY writer owns one chunk.
Credit stops returning for subsequently queued bytes. `Connection._Inbound`
also has a stream-controller delivery stage: during `onListen`, queued payloads
can leave its explicit queue and enter pending delivery before the consumer's
pause takes effect. Those payloads remain host-owned. Counting only the explicit
queue would undercount them.

Passive counters now observe actual payload ownership at these boundaries:

- Inbound retention increases by each received payload's length. It decreases
  at actual stream delivery, cancellation, or disposal of queued payloads.
  Closing a channel drops its explicit queue, but keeps counting staged stream
  deliveries until they are consumed or cancelled.
- Writer retention starts with the submitted chunk's actual length, including
  its isolate transfer and pending native write. It ends on the native reply
  (success or error), or writer exit. OS-owned bytes after native acceptance
  are excluded.
- Each terminal records the maximum concurrent inbound-plus-writer payload
  retention on ownership transitions. These are payload-byte counts, not RSS,
  allocation counts, transport buffers, or total accepted input. No data queue,
  history, clamping, or flow-control policy was added.

The existing test-host-only `test/terminal.stats` hook exposes current component
counts, current total and peak total. The release host still has no test method.
The qualification asserts the measured peak directly against 589,824 bytes,
requires a nonzero measurement and eventual zero retention after draining,
and preserves the fixture's every-accepted-byte and byte-order assertions.
Aggregate completed writes and whether they blocked remain diagnostic output;
OS absorption no longer causes this measurement to be skipped.

Scope: this qualifies `TerminalService`'s immediate-subscription path and the
tested paused/staged ownership cases. It does not qualify arbitrary consumers
that register inbound channels and leave them unlistened. Separately, code
inspection found that the existing inbound pump can stage pre-listener payloads
and return credit on controller submission. The deterministic test preloads one
window to reach that staging path; this work did not exercise or establish a
global unboundedness result for permanently unlistened channels, and made no
generic flow-policy change.

## Test-first evidence

All commands used the pinned SDK through `mise.exe`. The sandbox could not read
mise's trust state; the same command was then run using approved outside-sandbox
execution. No trust settings or SDK installations were changed.

From `packages/host_protocol`, against a compiling no-op observer scaffold:

```text
mise.exe exec -- dart test test/input_retention_test.dart
```

Result: 0 passed, 4 failed. Actual retained count was 0; expected counts were
262,144 bytes for a paused full window and 123 bytes before cancellation,
connection close and transport error. The pressure test also verified that a
three-window producer stayed blocked until resume, then delivered every byte in
order. The final suite additionally covers `onListen` staging: 192 KiB of paused
deliveries plus 256 KiB of renewed-credit arrivals are measured together as
448 KiB; close drops the queued 256 KiB while the staged 192 KiB remains counted
until ordered delivery resumes.

From `packages/host`, against a compiling no-op writer observer scaffold:

```text
mise.exe exec -- dart test test/terminal/terminal_io_test.dart
```

Result: 0 passed, 1 failed, expected `[317]`, actual `[]`. The test submits a
valid-size chunk to an invalid native handle to exercise a real failed native
write and verifies retention before submission returns and release on error.
The final test passes with observations `[317, 0]` and joins the writer isolate.
Successful native writes and eventual release are exercised by the real fixture.

## New Windows results

```text
# From packages/host_protocol
mise.exe exec -- dart test test/input_retention_test.dart test/credit_test.dart test/terminal_channels_test.dart test/codex_messages_test.dart
# From packages/host
mise.exe exec -- dart test test/terminal/terminal_io_test.dart test/it/terminal_qualification_test.dart test/it/codex_test.dart
```

Protocol/accounting/channel/group-3 message tests: 28 passed, no skips.
Writer, complete real terminal qualification file and group-3 routing tests:
10 passed, no skips.

The real input case measured **524,288 bytes (512 KiB)** of peak host retention
against the unchanged **589,824-byte (576 KiB)** limit. Aggregate completed writes
were **8,388,608 bytes (8 MiB)**, `blocked=false`. The fixture received all
**8,388,608 bytes in order**, and host retention returned to zero. The other
qualification rows measured 5 ms worst resize acknowledgement and 10.7 MiB host
RSS growth while transferring 100 MiB with a slow consumer; their existing
assertions passed.

From the repository root, sequentially after the focused checks:

```text
mise.exe run check
mise.exe run test:host
```

`check` passed: 259 source files needed no formatting changes, Dart and Flutter
analysis found no issues, and all fast suites passed. The formatter emitted the
existing package-resolution warning for the SQLite probe's analysis-options
include; it did not fail the formatting gate.

`test:host` passed: **626 passed, 13 skipped, 0 failures**, in 90 seconds.
Its input row again measured **524,288 bytes peak host retention**, **8,388,608
aggregate completed bytes**, `blocked=false`, with **all 8,388,608 bytes delivered
in order** and eventual zero host retention. The input row was not skipped.
The slow-consumer row measured 11.0 MiB host RSS growth in that aggregate run.

These new observations resolve the faulty measurement; they do not rewrite the
original failed or skipped runs. All test/build commands completed, the native
writer test joined its isolate, and fixture teardown owned process and temporary
directory cleanup. No standalone temporary files or background processes were
created for this measurement work.

## Coordinator verification

The coordinator independently reran the four protocol/accounting files above
(28 passed), the writer/terminal-qualification/Codex files (10 passed, no skips),
`mise.exe run check` (passed), and `mise.exe run test:host` (626 passed, 13 skipped,
no failures). Both coordinator input runs measured 524,288 bytes of peak host
retention with all 8,388,608 bytes delivered in order and eventual zero retention.
The direct slow-consumer run measured 14.8 MiB RSS growth; the full host run
measured 11.5 MiB. These are Windows fixture observations, with no Linux/macOS
or real Codex provider result claimed.
