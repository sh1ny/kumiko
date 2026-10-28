# Review

## Metadata

- **Round:** 1
- **Review action:** Focused re-check of Required Changes 1-3; not a new full-review round.
- **Prior round:** none
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** `openspec/architecture-review.md`, `openspec/architecture.md`, `openspec/strategy.md`, ADRs `0001`–`0007`, and relevant lifecycle, ownership, failure, and resource-bound passages in `openspec/changes/document-kumiko-direction/design.md`. Textual review only; no files edited.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — Per-instance hosts violate the per-user sole-writer assumption. — Resolved**

The exclusive per-user lock remains mandatory before execution, with second-instance refusal and automatic release on owner death (`docs/adr/0001-desktop-and-child-execution-host.md:15–17`). Store opening and migration require that lock (`docs/adr/0003-host-owned-local-sqlite-store.md:20`). Simultaneous-launch and owner-death qualification remain required (`docs/adr/0001-desktop-and-child-execution-host.md:74–75`).

**M2 — Host failure removes the process responsible for cleanup. — Resolved**

The current text satisfies Required Change 2 as restated:

- Durable pending ledger entries precede spawn; PID and start time follow it. Inherited unit markers support discovery of POSIX descendants that escape their process group (`docs/adr/0001-desktop-and-child-execution-host.md:23–33`).
- Unconfirmed pending entries, failed or unavailable scans, failed termination, and surviving marked processes produce unresolved cleanup rather than success (`docs/adr/0001-desktop-and-child-execution-host.md:34–36`).
- The affected workspace blocks resume, relaunch, new agent sessions, and new terminals until reconciliation succeeds or the user explicitly confirms the old processes are gone. Projectless terminals use their working directory as the target (`docs/adr/0001-desktop-and-child-execution-host.md:38`).
- ADR 0004 and the architecture consistently carry that workspace gate and durable ownership (`docs/adr/0004-runtime-adapters-and-session-identity.md:41`; `openspec/architecture.md:52,56,82`).
- Three-platform qualification covers escaped descendants, both pending/spawn/PID-write crash windows, and attempted replacement launches (`docs/adr/0001-desktop-and-child-execution-host.md:68–73`).

The inability to detect descendants that both escape their session and clear their environment is explicitly disclosed; “cleaned” and desktop wording are limited to recorded or marked processes (`docs/adr/0001-desktop-and-child-execution-host.md:40`). This does not silently classify the specified pending-entry or observable escape cases as successful cleanup.

**M3 — Logical channels do not establish control responsiveness on shared pipes. — Resolved**

Maximum frame sizes, control priority, round-robin data scheduling, per-channel credit, and independent receiver draining remain specified (`docs/adr/0002-versioned-desktop-host-protocol.md:21–27`). Qualification still requires control and unrelated-channel progress under saturated output and stalled consumers (`docs/adr/0002-versioned-desktop-host-protocol.md:42`). Architecture bounds remain aligned (`openspec/architecture.md:76–77`).

### Suggestions

None. No new Critical or Moderate contradiction was identified. The edits preserve the initial nonpersistent lifecycle and honest recovery boundaries (`openspec/strategy.md:21,28`; `openspec/changes/document-kumiko-direction/design.md:98–109,888`), host-owned tool authorization (`docs/adr/0005-host-tool-service-and-authorization.md:13–18`), terminal ownership and layout-only reopening (`docs/adr/0006-host-owned-ptys-and-terminal-rendering.md:18–33`), and local/shared authority separation (`docs/adr/0007-optional-team-server-boundary.md:19–24`).

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

CHANGES_APPLIED: yes

Required Changes 1–3 are satisfied. No required changes remain from this focused re-check.

## Rebuttals

None.