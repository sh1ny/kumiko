# Review

## Metadata

- **Round:** 1 (second re-check of Required Changes)
- **Prior round:** none
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** `openspec/changes/scaffold-desktop-and-host/review.md`; `openspec/changes/scaffold-desktop-and-host/design.md`; all five change specifications: `desktop-host-protocol`, `execution-host`, `host-process-cleanup`, `local-store`, and `product-telemetry`; `docs/adr/0001-desktop-and-child-execution-host.md`; `docs/adr/0002-versioned-desktop-host-protocol.md`.

## Findings

### Critical (blocking)

None. No fix introduces a new Critical problem.

### Moderate

The seven round-1 findings are retained below with their current disposition.

1. **Workspace identity can bypass the cleanup gate through path aliases.** Addressed. D4 resolves filesystem paths and directory identities before ledger insertion and gate checks. Identity matching handles aliases without unconditional case folding. The cleanup specification covers aliases, distinct case-sensitive directories, and unavailable targets.

2. **Ordinary process exit during a marker scan becomes a cleanup failure.** Addressed. D9 rechecks existence and start time after an environment-read failure. Disappearance or pid replacement counts as gone; a genuinely unreadable live process remains a conservative failure. Both outcomes have scenarios.

3. **The unit cap does not bound channel memory.** Addressed. D6 and Resource Bounds cap open data channels at 32, refuse excess opens with `channel-cap`, and bound aggregate channel buffering at 8 MiB per side. The protocol specification covers repeated opens independently of unit count.

4. **Recovery results can exceed the protocol’s own message limit.** Addressed. D5 defines a constant-size summary, bounded workspace and unit pages, revision handling, and workspace-wide cleanup actions. The reconciliation diagram now sends a summary followed by paginated queries; it no longer embeds `unresolved[]`. Its `counts` shorthand is consistent with D5’s explicit count fields.

5. **Shutdown deadlines do not accommodate the specified cleanup procedure.** Addressed. Parallel termination and shared scans fit within the 30-second host deadline, with a 35-second desktop wait. Unconfirmed rows remain durable. The desktop-killed scenario covers terminable processes; the survivor scenario explicitly injects kill failure and makes the next reconciliation outcome conditional. This is consistent with ADR 0001’s successful-cleanup qualification and its explicit unresolved treatment of failed kills and survivors.

6. **Writer batching weakens the one-data-frame control guarantee.** Addressed. D7, Resource Bounds, and the data-flow diagram consistently require one frame followed by flush before the next scheduling decision. The protocol scenario and recording-sink test cover control arriving during a data-frame write, preserving ADR 0002’s guarantee.

7. **The second-launch byte-identity scenario cannot attribute writes correctly.** Addressed. The scenario uses a quiescent lock holder, and D10 and Flow & State Gaps define the corresponding test fixture. This removes competing profile writes during the assertion interval.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

CHANGES_APPLIED: yes

1. **Define host-side filesystem identity resolution before ledger insertion and gate checks, including alias handling and volume-appropriate case behavior. Add scenarios for two paths to the same checkout and distinct case-sensitive paths.**  
   **Applied.** D4 and the cleanup scenarios satisfy the requirement without contradicting ADR 0001’s workspace gate.

2. **Define marker-scan handling for processes that disappear during inspection. Add a concurrent-exit scenario that preserves conservative handling of genuinely unreadable live processes.**  
   **Applied.** D9 and the paired cleanup scenarios distinguish disappearance or pid replacement from an unreadable live process.

3. **Set a host-wide channel or aggregate-buffer limit, define refusal behavior, and test repeated channel opening independently of unit count.**  
   **Applied.** D6, Resource Bounds, and the repeated-channel-opens scenario consistently define the cap, aggregate bound, and refusal behavior.

4. **Define bounded, paginated cleanup-result messages, including a workspace containing many unresolved units. Ensure reconciliation completion and cleanup actions remain reachable when results exceed 1 MiB.**  
   **Applied.** D5 supplies bounded summaries and pages, including per-workspace unit pagination and actions covering all units. The corrected sequence diagram agrees with that contract.

5. **Reconcile scan and shutdown deadlines. Specify cancellation, durable unresolved-state handling and the observable survivor outcome; align the desktop-killed scenario with that contract.**  
   **Applied.** Resource Bounds defines the shared scan budget, deadline cutoff, retained ledger state, and subsequent reconciliation. The revised scenarios distinguish successful termination from injected kill failure and report unresolved cleanup only when reconciliation cannot confirm cleanup. No ADR amendment is required for that distinction.

6. **Specify writer submission behavior that preserves the one-frame guarantee, and test control arriving while bulk output is already being flushed.**  
   **Applied.** D7, the corrected data-flow diagram, Resource Bounds, and the protocol scenario agree on per-frame submission and priority.

7. **Replace global profile byte identity with an assertion that attributes attempted writes to the refused instance, or explicitly quiesce the owning instance for that scenario.**  
   **Applied.** The quiescent lock-holder scenario and fixture make the byte-identity assertion attributable.

## Rebuttals

The author’s rebuttals and follow-up are supported by the current artifacts. RC4’s embedded recovery list and RC6’s batched writer diagram have been corrected. RC5 now distinguishes the successful desktop-kill qualification from injected termination failure, retains unconfirmed ledger entries, and correctly conditions the next launch’s unresolved report on reconciliation results.

All seven Required Changes are fully applied. No fix introduces a contradiction with the reviewed specifications or the in-force ADRs.