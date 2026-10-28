# ADR 0007: Optional team server as sole authority for shared records; no offline replica

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D1, D2, D13, D26, D27, D29, D53

## Context

Teams share these records through a self-hosted server:
- projects, tasks, milestones and roadmaps;
- documents;
- human project chat;
- membership.

Solo use must not need it (D1). Shared operations must fail visibly when it is unreachable, with no offline queue (D2). Private development never travels through it (D29). Client and server must interoperate whichever upgrades first (D26). Serverpod is the preferred backend candidate, not a selection. The server is not built before M4, but its boundary constrains the local design now.

## Decision

1. **The team server is the sole writer of shared records.** The desktop never holds a writable replica of them. Shared reads may be cached for display only and are refreshed after reconnecting. They are never used as a source for writes.
2. **The desktop talks to the team server directly**, not through the execution host, for human-initiated shared operations. Agent tool calls that touch shared records go through the host tool service (ADR 0005). That service calls the server with the owner's current authorization, so the server checks every write regardless of path.
3. **Private data never crosses** this connection: agent transcripts, terminal streams, working-copy content, local layouts, unsent drafts and personal usage. Shared execution associations carry only minimal metadata decided by the change that introduces them. The rule is structural: the local store (ADR 0003) has no sync path, and the shared protocol has no message types for private data.
4. **Reconnection:** revalidate the session and grants, negotiate the protocol/capabilities (D26), fetch current state, and only then re-enable shared features. Never replay earlier writes.
5. **Domain rules** shared between solo and team operation live in the pure `domain` package. Solo projects (M3) use the same rules through the host's local operation path. Converting a solo project to a shared one is a separate, explicit operation, never synchronization.
6. **Technology is open.** This ADR fixes the boundary only. The backend framework, database and deployment shape are decided by an ADR at the start of the team milestone.

## Rejected alternatives

- **Offline-writable local replica with later reconciliation** (rejected in D2).
- **Routing all team traffic through the execution host.** It couples UI collaboration to process ownership and makes a future remote host a team-data proxy.
- **Choosing Serverpod now.** No team code is near, and authorization, stream permission changes and migrations are unqualified.

## Reversal cost

High. Authority, privacy and offline semantics shape storage and protocols on both sides.
