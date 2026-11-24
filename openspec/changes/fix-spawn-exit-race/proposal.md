# Proposal

## Why

A unit that exits at once can fail to spawn on Linux and macOS (issue #18). `spawnPosixUnit` reads the unit's start time right after `Process.start`. When the unit has already exited and `dart:io` has reaped it, the read finds no process, and the spawn throws `StateError('unit … exited before its start time could be read')` instead of returning a unit whose exit code the caller can read.

It happens on both paths:

- with a pseudo-terminal, first seen in PR #17's CI;
- without one, in PR #32's CI (run 45412658114, ubuntu-latest, `spawn_test.dart`: "exit code of the unit reaches exitCode", fixture `exit 5`).

The failure is a race in the product, not only in the test. A user command that ends at once (a terminal running `exit`, a tool that prints its version) can be refused at launch for no reason. It also turns PR CI red at random, which blocks #32 and #29. The owner asked for it to be fixed first, as its own change ("Fix #18 first as its own change, then #32").

## What Changes

- When the start-time read finds no process and the OS confirms that no process has the pid, the spawn returns the unit as already exited instead of throwing. Its exit code still arrives through `exitCode`.
- Such a unit carries a start time that means "the leader is known to be gone". The guards (termination, liveness and the next host's reconcile) act on it without reading or signalling the pid, so a reused pid is never touched. The marker scan still covers its descendants.
- On the PTY path, the status pipe still decides first: a timeout or a reported setup or `execve` failure is still `SpawnFailed`, and only an empty status from a gone unit returns the exited unit.
- A start-time read that is refused, or a null read while the OS still reports a process at the pid, fails the spawn as it does today.
- A failed status-pipe setup in the shim already reads as a started program. This change adds no new way to reach it, and it is filed as #33.
- Tests:
  - A unit that has exited and been reaped before its start time is read spawns on both paths and reports its exit code. The test reaches that state by waiting for the exit, not by retrying the race.
  - A refused read still fails the spawn.
  - A reaped PTY unit whose `execve` failed still reports `SpawnFailed`.
  - A recorded -1 row is never signalled.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-process-cleanup`: "Every launch is recorded before it starts" gains a scenario. A unit that exited before its start time could be read is still a launched unit: the ledger records its pid with a start time that matches no process, and cleanup treats its leader as gone.

## Impact

- `packages/process_containment/lib/src/posix_unit.dart`: `spawnPosixUnit` (both paths), `killProcessGroup`, `posixIsProcessAlive`, and a named start-time constant for a unit that exited before the read.
- `packages/host/lib/src/ledger.dart`: a doc comment on `markRunning` only.
- `packages/process_containment/lib/src/contained_unit.dart`: the `startTime` doc names that value.
- Tests in `packages/process_containment/test/` (spawn and PTY) and `packages/host/test/it/reconcile_test.dart`.
- No protocol, ledger schema or Windows change: Windows holds the process handle, so its start time stays readable after the exit.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting (`decision_making: autonomous` in openspec/specwright.yaml)

### S1: Fix the spawn, not the test

- **Choice:** Make `spawnPosixUnit` return an already-exited unit when its start time cannot be read because the process is gone, on both the PTY and plain paths.
- **Rejected:** Changing `spawn_test.dart` to use a fixture that lives longer: it hides a race real users hit when a command ends at once. Retrying the spawn: a unit is not safe to start twice, and the repository test rules (issue #26) forbid retrying to get green.
- **Reversal cost:** low
- **Important:** yes. It changes behaviour users see: a command that exits at once launches instead of failing.
- **Chosen by:** user ("Fix #18 first as its own change, then #32")

### S2: Leave Windows and the refused-read case as they are

- **Choice:** Only a read that proves the process gone changes. A refused read on POSIX, and the Windows spawn, keep their current errors.
- **Rejected:** Treating every failed read as an exit: a refused read is no evidence that the process is gone, so a live unit could then go untracked.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** agent
