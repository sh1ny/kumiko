# Review

## Metadata

- **Round:** 4
- **Prior round:** Round 3 codex APPROVE_WITH_CHANGES; all three required changes applied and accepted, with CHANGES_APPLIED recorded as yes; verdict voided by amendments `8a727d2` and `d2da4dc`.
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** Both amendment diffs; round-3 review, re-check and rebuttals at `d2da4dc`; `git log main..HEAD`; host-terminals proposal, design, tasks, spike results and all four delta specs; roadmap and architecture; ADRs 0001, 0002, 0003, 0006, 0009 and proposed 0010; specified containment and host terminal sources; `terminal_test.dart`, `pty_windows_test.dart`, and the terminal byte fixture; supplied Flutter test-architecture skill as data; Microsoft pseudo-console and standard-handle documentation and Linux termios documentation. Read-only planning review; no tests executed.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — The amended POSIX guarantee still promises bytes the PTY can legitimately transform.**

`specs/terminal-sessions/spec.md:66` promises the PTY-produced bytes, then states that on Linux and macOS these are the bytes the program wrote. That equivalence does not hold generally: terminal output processing can translate LF to CR-LF, among other transformations. See [termios output flags](https://man7.org/linux/man-pages/man3/termios.3.html).

The POSIX spawn and shim sources preserve terminal operation rather than establishing an immutable, transparent output mode. The fixture explicitly excludes LF from `blob()` to avoid line-discipline transformation. Its passing comparison therefore cannot establish the unconditional POSIX claim.

**Consequence:** ordinary shell output can violate the scenario while the host correctly relays every master-side byte. Implementing transparency to satisfy that wording would also interfere with normal terminal semantics. The contract should consistently begin at the PTY output boundary on every OS.

**M2 — The Windows test-map rows do not prove the retained byte-preservation guarantee.**

Both amended rows at `tasks.md:25-26` are green and map to the raw-bytes integration test. Its Windows branch checks ordered `BEGIN;`/`END;` markers and only `expect(received, isNotEmpty)` for their contents.

Those checks establish neither equality with ConPTY output nor preservation of the intervening sequence. A host that decodes malformed data, strips escape sequences, or drops or reorders interior bytes can still pass.

ConPTY’s re-rendering makes comparison with the program’s original blob inappropriate, but does not remove the requirement to preserve the bytes ConPTY actually emits. Microsoft explicitly describes relaying pseudo-console output without local transcoding in [Creating a Pseudoconsole session](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session).

**Consequence:** the map declares the amended Windows byte contract covered while its defining invariant remains untested. This needs a deterministic relay-boundary assertion, alongside the existing real-ConPTY smoke test.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Correct the POSIX output claim.** In “Binary-safe output,” remove the unconditional statement that POSIX PTY output equals the program’s writes. State that the desktop receives exactly the bytes read from the PTY output endpoint, in order and unchanged by the host. If retaining a program-byte comparison, condition it on a fixture-controlled output mode. Update its test-map description and task 5.3 accordingly; include an assertable POSIX case with output processing enabled that preserves the resulting PTY bytes.

2. **Separate Windows re-rendering coverage from relay fidelity.** Update both amended test-map rows and tasks 5.1/5.3 to require:
   - a real-ConPTY test asserting the surrounding printable text remains in order despite NUL/invalid-UTF-8 input;
   - a deterministic test at the terminal-service relay boundary comparing a known PTY-reader byte sequence with the complete desktop-received sequence, including escape sequences, NUL and malformed UTF-8 across chunk boundaries.

   Keep the fidelity coverage pending until that equality assertion exists; marker order and nonempty contents alone must not mark it green.

CHANGES_APPLIED: no

## Rebuttals

- **Required Change 1 (POSIX output claim): fixed.** specs/terminal-sessions/spec.md "Binary-safe output" now promises exactly the bytes read from the pseudo-terminal, unmodified by the host; the program-byte comparison is conditioned on the default output processing and states the LF to CR LF translation, so it is assertable. tasks.md test-map row "Binary-safe output" describes the POSIX case with every byte value, LF included, expected as CR LF.
- **Required Change 2 (Windows relay fidelity): fixed.** The "Binary-safe output" row is back to red and now requires a scripted PTY-reader sequence (escape sequences, NUL, malformed UTF-8 split across chunk boundaries) compared with the complete desktop-received sequence on all OSes. The "Windows pseudo-console re-renders output" row covers only the real-ConPTY check that the printable text around the NUL and invalid UTF-8 bytes arrives in order, and points to the Binary-safe row for fidelity. Tasks 5.1 and 5.3 are already done and committed, so the added work is the new task 5.6 rather than an edit to their text; 5.6 keeps the row red until the equality assertion passes on all three OSes.

Round-3 findings remain resolved as recorded in its accepted re-check.

The Windows inheritance amendment matches the implementation; Microsoft’s pseudo-console example also uses `bInheritHandles=FALSE`. No concrete blocking launch defect was established. The Windows re-rendering clarification is consistent with ADR 0006’s native ConPTY backend and desktop engine boundary, and does not require changing proposed ADR 0010. The outstanding findings concern the output contract and its planned proof.