# Spec Delta

## ADDED Requirements

### Requirement: Lifecycle, activity and draft methods are capability-gated
`app/quit` and `app/previousExit` SHALL need the `lifecycle` capability, `terminal/activity` the `terminal` capability, and `agent/draftSave`, `agent/draftLoad`, `agent/draftReset` and the `agent/draftStoreReady` notification the `agent` capability, each advertised by both peers in `hello`. Without it they SHALL fail with `method-not-available` and the rest of the session SHALL keep working. Source: ADR 0002.

#### Scenario: Both peers support lifecycle
- **WHEN** desktop and host both advertise `lifecycle`
- **THEN** `app/quit` and `app/previousExit` succeed

#### Scenario: Host without lifecycle
- **WHEN** a desktop that advertises `lifecycle` connects to a host that does not
- **THEN** `app/previousExit` fails with `method-not-available`, no previous-exit notice is shown, and quitting still closes the connection and ends every unit

### Requirement: Activity and draft requests are bounded
`terminal/activity` SHALL name at most 64 terminals and be answered within the activity deadline; ids past the bound SHALL be refused `invalid-params`. A draft's encoded JSON string contents, UTF-8 and escaping counted, SHALL be at most 256 KiB, so a draft always fits a control message; a larger `agent/draftSave` SHALL be refused `draft-too-large`, and one past the total draft bound `draft-cap`. Both SHALL stay answered within the control-latency bound under saturated output. Source: ADR 0002.

#### Scenario: Too many terminals
- **WHEN** the desktop sends `terminal/activity` naming 65 terminals
- **THEN** the host refuses it `invalid-params` and reads no process table

#### Scenario: Oversized draft
- **WHEN** the desktop sends `agent/draftSave` whose text encodes to one byte over 256 KiB of JSON string contents
- **THEN** the host refuses it `draft-too-large` and the stored draft is unchanged

#### Scenario: Unknown session
- **WHEN** the desktop sends `agent/draftSave` for a session id with no saved record
- **THEN** the host refuses it `unknown-session` and stores nothing

#### Scenario: Draft save under saturated output
- **WHEN** terminal A streams output continuously, session B's event channel has no credit, and the desktop saves session C's draft
- **THEN** the save is acknowledged within the control-latency bound

### Requirement: Draft storage never delays control or cleanup
A stalled or failed draft store SHALL NOT delay reconciliation, Stop, permission replies or desktop-loss cleanup. A draft operation past the draft deadline, or arriving while the store is not responding or full, SHALL fail `draft-unavailable`. A `stale-revision` refusal SHALL carry the stored revision. The host SHALL send `agent/draftStoreReady` whenever the store becomes available again. Source: ADR 0002, D7.

#### Scenario: Draft store stalls at start
- **WHEN** the previous host was killed with a unit still running and the next host's draft store is held inside its open
- **THEN** the next host reconciles that unit and accepts launches as usual, and draft requests fail `draft-unavailable` within the draft deadline

#### Scenario: Draft commit stalls
- **WHEN** a draft save is held inside its commit and the user presses Stop in session B and answers a permission request in session C
- **THEN** both are acknowledged within the control-latency bound, and the save fails `draft-unavailable` within the draft deadline

#### Scenario: Desktop lost while a draft commit stalls
- **WHEN** a draft save is held inside its commit and the desktop is killed
- **THEN** the host ends every unit and exits within the desktop-loss bound

#### Scenario: Stale save reports the stored revision
- **WHEN** the desktop saves a draft at revision 3 and the stored revision is 500
- **THEN** the host refuses it `stale-revision` with stored revision 500 and the stored draft is unchanged

#### Scenario: Store answers again
- **WHEN** the draft store was not responding and its stuck operation returns
- **THEN** the host sends `agent/draftStoreReady`, and the next draft save is accepted

#### Scenario: Reset refused while storage works
- **WHEN** the draft store is open and working and the desktop sends `agent/draftReset`
- **THEN** the host refuses it `draft-store-in-use` and every stored draft is unchanged

#### Scenario: Second reset during a reset
- **WHEN** drafts are disabled, a first `agent/draftReset` is held while the host replaces the draft worker, and a second `agent/draftReset` arrives
- **THEN** the second is refused `draft-store-in-use`, exactly one new draft worker serves draft requests, and a draft save acknowledged after `agent/draftStoreReady` is still stored after a host restart
