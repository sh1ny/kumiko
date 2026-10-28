# ADR 0001: Desktop UI with a child execution host process

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D1, D6, D7, D9; user decision 2026-10-28

## Context

Kumiko runs agent runtimes, PTYs/shells and a local tool service for the user. D1 separates execution from UI and team coordination even on one machine. D7 rules out a persistent daemon: processes end when their tab or the app closes, and reopening restores layout and saved conversations, not processes. A later remote execution host is plausible but not in scope.

## Decision

1. The **Flutter desktop app** is the UI process. It renders, takes input and owns no child processes except the host.
2. The desktop launches exactly one **execution host** per running app instance: a headless Dart executable (`dart compile exe`) bundled with the app and started as a direct child process. The host owns every agent runtime, adapter, PTY/shell and the local Kumiko tool service. It is also the sole writer of local durable state (ADR 0003).
3. **One owner per user profile.** Before migrating the store or launching anything, a host takes an exclusive OS-level lock on the per-user state directory: a lock file held with an OS advisory/exclusive lock. The OS releases the lock when the holder dies, so a crash never leaves a stale owner.

   A second desktop launch whose host cannot take the lock starts no execution. It brings the running instance's window forward where the platform supports that; otherwise it says Kumiko is already running and exits. There is never a second host for the same profile.
4. **Lifetime is tied to the desktop.** When its connection to the desktop closes (normal quit, UI crash or kill), the host terminates the process trees it started and exits. It never keeps work alive for later reattachment.
5. **Cleanup does not depend on the host surviving.** Each runtime and shell is started as its own containment unit:
   - on Windows, inside a Job Object that the desktop creates and holds, with kill-on-close set;
   - on POSIX, as the leader of its own process group/session.

   Every launch is recorded in a **process ledger** in the store in two steps:
   - a *pending* entry (session or terminal id, target workspace, containment id) is written durably **before** the spawn;
   - pid and process start time are added right after it.

   Every spawned process also carries a per-unit marker in its environment (`KUMIKO_UNIT=<containment id>`), which its descendants inherit. Windows jobs are created without breakaway, so descendants stay contained.

   If the host dies abruptly:
   - on Windows the desktop terminates the job;
   - on every OS, the **next host to take the lock** reconciles the ledger before launching anything:
     1. terminate each still-live recorded unit, matching on pid plus start time so a reused pid is never killed;
     2. on POSIX, scan the current user's processes for the unit marker and terminate matches; this finds descendants that escaped their group by creating a new session;
     3. treat a *pending* entry without a pid as unresolved, unless its Windows job was confirmed terminated.

   A unit is **cleaned** only when termination was confirmed and the scan found no marked process. Anything else is **unresolved**: a failed kill, a failed or unavailable scan, a surviving marked process, or a pending entry that cannot be confirmed.

   An unresolved unit marks its session *termination unconfirmed* and its **target workspace** *cleanup unresolved*. For a projectless Personal terminal, the target is its working directory. While a workspace is *cleanup unresolved*, the host refuses every new execution that targets it: no resume, relaunch, new agent session or new terminal. This holds until a retried reconciliation cleans the unit, or the user explicitly confirms that the old processes are gone. The desktop shows the affected sessions, workspaces and unresolved reasons.

   Stated limit: a descendant that both leaves its POSIX session and clears its environment cannot be detected. *Cleaned* therefore means "no recorded or marked process remains", never more, and the desktop wording says that.
6. **The code is one Dart workspace** of separate packages:
   - `domain`: pure rules, no I/O;
   - `host_protocol`: the desktop-host contract, ADR 0002;
   - `host`: the executable;
   - `desktop`: the Flutter app.

   The desktop depends on `host_protocol` and `domain`, never on `host`. A future team server reuses `domain` (ADR 0007).
7. Native code is allowed only behind a package boundary for platform needs: PTY backends, and the terminal emulation core if the selected engine requires it (ADR 0006).

## Rejected alternatives

- **Services inside the Flutter process (isolates).** Simpler at first. But a UI crash takes the process owner with it, nothing enforces the "no process survives" guarantee in a separate place, and a later remote host would need the contract extracted from in-process calls.
- **Persistent per-user daemon.** It contradicts D7 (process survival is deferred). It also adds install, upgrade and orphan problems before the product needs them.
- **A Rust or Node host.** The ACP and OMP adapter ecosystems are reachable from Dart via subprocess/stdio. A second language splits domain code from the future Dart team server.

## Consequences

- Every UI action that touches processes or durable state crosses the ADR 0002 contract, so the desktop can be restarted against a fresh host. The contract is the seam for a future remote host.
- Packaging must bundle and sign a helper executable per platform. On macOS this includes hardened-runtime signing of the helper (unqualified).
- A host crash is visible to the desktop as a lost connection. The desktop must report affected sessions as stopped or unknown, never as running (ADR 0004).

## Reversal cost

High. Process ownership, the IPC contract and crash semantics all follow from this split. Moving services in-process later is cheaper than the opposite move, which is one reason to start out of process.

## Qualification in M1

On each of Windows, Linux and macOS:
- the host builds and launches;
- killing the desktop process leaves no host, agent or shell process behind;
- abruptly killing the host while an agent, a shell, a shell-spawned descendant and a descendant that started its own session (`setsid`/double fork) are running ends with every unit cleaned, or with its workspace *cleanup unresolved*;
- a host killed between the pending ledger write and the spawn, and between the spawn and the pid write, leaves the workspace *cleanup unresolved* unless cleanup is confirmed;
- while a workspace is *cleanup unresolved*, attempts to resume, relaunch, start a new agent session or open a new terminal against it are refused with a visible reason;
- two simultaneous launches yield exactly one host;
- after the owning host is killed, the next launch takes the lock and reconciles.
