# ADR 0017: Tests never gate on elapsed time

Status: Accepted  
Date: 2026-11-24  
Amends: ADR 0014, the Consequences sentence that the draft latency test "fails above a 100 ms median". ADR 0014's decisions, including the 100 ms bound that reopens decision 12, remain in force.

## Context

Kumiko's CI runs every suite on hosted Windows, Linux and macOS runners. A
hosted runner can be many times slower than a developer machine at any moment:
antivirus, a cold process start, a slow fsync or a noisy neighbour. An audit of
about 60 days of failed Windows jobs (issue #28) found that more than half of the
failures were timing, deadline or order races, not bugs. The draft store suite
was a repeat offender: durable writes asserted under 250 ms, test hosts running
800 ms and 1000 ms draft deadlines as global clocks, and a worker unit test that
failed when the fsync median rose above 100 ms (issue #26).

Each of these tests could turn red with more time alone. Rerunning such a test
hides the problem instead of fixing it, and costs a CI round each time.

## Decision

1. **A test asserts order and outcome, never elapsed time.** No test fails
   because an operation took longer than some bound. A correctness test asserts
   what happened and in what order (rule 1 of #28).
2. **A deadline or timeout under test runs on an injected or fake clock, or is
   fired explicitly.** When the behaviour under test is a timeout, the test
   drives it with a fake timer, or fires the deadline once the code has reached
   the stage being tested. A real budget that also has to cover startup, I/O or
   unrelated work is never used (rule 3).
3. **Real time is only a hang guard.** A real-time limit exists only to stop a
   hung test. It is generous (minutes, not seconds), and its expiry is never an
   expected outcome (rule 4).
4. **Performance is measured, not gated.** A measurement is printed as
   `measured:` and checked by a later qualification slice or an opt-in
   benchmark, not by a test failure. In CI a test may assert work counts
   instead (rule 7).

The ten shared rules that implement this decision, including waiting for events
instead of durations and never retrying to get green, live in `AGENTS.md`,
section "Tests that run in Windows CI".

## Consequences

- No test fails on elapsed time. A measurement is printed as `measured:` and
  checked by the later qualification slice, not by a test failure. One example
  is the draft fsync median and its 100 ms threshold for reopening ADR 0014
  decision 12: the unit test `measured: draft save and removal latency` prints
  the median on every platform and no longer fails above 100 ms. This amends
  ADR 0014's Consequences sentence that the test "fails above a 100 ms median".
  The threshold itself stands; the later qualification slice of #28 checks it.
- The elapsed bounds in the specs and the architecture (the 250 ms control
  bound, `hostLossBound`, the launcher's quit wait and the host's cleanup bound
  after desktop loss) stay product contracts. Tests in the PR gate prove the
  order behind them (control and cleanup never wait on drafts); the bounds
  themselves move to automated qualification.
- Product code that has deadlines takes an injectable timer or a test hook that
  fires the deadline, so tests can reach it without real waiting. The draft
  store is the first: an injected timer factory and the `test/draft.expire`
  hook of the test host (ADR 0008 keeps such hooks out of the release host).
- Existing tests that gate on elapsed time are fixed slice by slice under #28.
  Until a slice lands, its tests remain known risks; they are fixed, never
  rerun to get green.
