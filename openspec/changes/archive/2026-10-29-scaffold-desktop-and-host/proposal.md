# Proposal

## Why

Kumiko has no code yet, and every later M1 change (terminals, the Claude ACP session, tool delivery, exit and reopen) needs the same base: a desktop that launches one child execution host per user profile, a framed protocol between them, a durable process ledger that makes crash cleanup provable, and CI on three OSes. This is change 1 of **M1 - Local development loop (walking skeleton)**, the walking skeleton's first slice. It retires the riskiest assumptions first: the child host and its process cleanup, and the multiplexed protocol.

It advances these M1 exit criteria:
- **CI and dependency audit** (agent): CI builds the desktop app with its bundled host for Windows, Linux and macOS from main, and the dependency audit finds no analytics, crash-report or remote-logging package. This change delivers it in full.
- **Progress under load** (agent, ADR 0002): this change builds and qualifies the framing, fair writer and per-channel credit with host test channels. The terminal-level demonstration lands with `host-terminals`.
- **Process cleanup** (agent, per OS, ADR 0001): killing the desktop leaves no host process; an abruptly killed host ends with every unit cleaned or its workspace *cleanup unresolved* and refusing new launches; two simultaneous launches yield one host. This change qualifies it with host test units. Agents and shells reuse the same mechanism in later changes.

## What Changes

- A Dart pub workspace with the packages from ADR 0001: `domain` (pure, no I/O), `host_protocol`, `host` (headless executable) and `desktop` (Flutter). Native platform calls (job objects, process groups, process start times, environment scans) live behind one package boundary, `process_containment`, used by both the desktop and the host. The desktop never depends on `host`.
- The desktop launches the bundled host as a child over its stdio and runs the versioned `hello` handshake with capability negotiation. A missing common version is shown as an incompatibility error, never guessed past.
- Length-prefixed multiplexed framing with bounded frames, a fair writer that sends control before the next data frame and round-robins data channels, and per-channel credit (ADR 0002). Numeric frame, credit and queue sizes are set here and recorded in the architecture.
- One host per user profile through an exclusive OS lock. A second launch starts no execution: it shows "Kumiko is already running" and exits. Bringing the first window forward is **not** built in M1; it needs a single-instance channel, which is later work (user decision, 2026-10-29).
- **Store core pulled forward from change 2** (user decision, 2026-10-29): the SQLite binding probe, its follow-up ADR, and a host-owned store with versioned transactional migrations, opened only under the profile lock (ADR 0003). This change's schema holds only the process ledger and host-instance records. Change 2 (`local-store-and-workbench-shell`) keeps the layout and working-set schema. The roadmap descriptions of changes 1 and 2 are updated to match.
- Containment units and the process ledger (ADR 0001): a pending entry written before every spawn, pid and start time after it, the `KUMIKO_UNIT` marker, a Windows job per unit inside a desktop-held kill-on-close job, POSIX sessions, reconciliation by the next lock holder before any launch, and the *cleanup unresolved* workspace gate with retry and user confirmation.
- Host lifetime tied to the desktop: on lost connection the host terminates its units and exits. The desktop shows *host lost*, and on Windows it terminates the host's job. A restarted host reconciles before launching anything.
- A minimal desktop window: host status (starting, connected with versions, cleaning up, incompatible, already running, store error, host lost with restart), and the *cleanup unresolved* list with reasons, **Retry cleanup** and **Confirm processes are gone**.
- Test-only host capabilities (test units and flood/stall channels), compiled only into test builds of the host, so the qualification runs against the real executable without shipping an arbitrary-spawn command.
- GitHub Actions CI on Windows, Linux and macOS: analyze, test (including contract tests that run the real host executable), the dependency audit, the host build, and the desktop build with the host bundled.

## Capabilities

### New Capabilities
- `execution-host`: launching the bundled host, one owner per user profile, the second-launch outcome, host lifetime tied to the desktop, and host-lost visibility.
- `host-process-cleanup`: containment units, the durable process ledger, reconciliation after an abrupt host exit, and the *cleanup unresolved* workspace gate with retry and confirmation.
- `desktop-host-protocol`: the `hello` handshake and capability negotiation, bounded frames, control priority and fair data scheduling, and per-channel credit.
- `local-store`: the host-owned versioned store, opened and migrated only under the profile lock, with failed or newer-schema stores refused, never reset.
- `product-telemetry`: shipped dependencies exclude product-analytics, crash-report and remote-logging packages, enforced in CI. Carries D25 and the backlog requirements "Client product telemetry and reports are not gathered" and "Telemetry-free builds exclude the capability" (dependency part only) from `document-kumiko-direction`.

### Modified Capabilities

None. No main specs exist yet.

## Impact

- **New code:** the whole Dart workspace (`domain`, `host_protocol`, `process_containment`, `host`, `desktop`), a dependency-audit tool, and `.github/workflows/` CI.
- **Dependencies:** a Dart SQLite binding chosen by the probe (candidates from `package:sqlite3`, bundled or system library); `ffi` for OS calls. Every dependency passes the audit.
- **Planning files:** `openspec/roadmap.md` (descriptions of changes 1 and 2), and during apply `openspec/architecture.md` (numeric bounds, the extra package, the new ADR index row) and a new ADR recording the SQLite binding choice.
- **Toolchain:** Dart 3.13 and Flutter 3.47 (installed locally through mise; pinned in CI).
- **Not in this change:** terminals and PTYs, agent sessions, tools, layout and working sets, window focus on a second launch, and code signing or notarization.
