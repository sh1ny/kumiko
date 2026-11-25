# Review

## Metadata

- **Round:** 4
- **Prior round:** REVISE. The user required verification after first-pass exit confirmation and deferred the race after the final listing to OS grouping (#9).
- **Reviewer:** Fresh-context reviewer (OMP), read-only.
- **Reviewed:** Proposal, FULL design, round-3 review and author rebuttals, cleanup spec delta and main spec, execution-host shutdown requirement, architecture, ADRs 0001 and 0014, scaffold D9, the six requested Dart sources, relevant host shutdown code and marker-scan tests, and the installed `dart-add-unit-test` skill.
- **Evidence limits:** Checked cited repository paths against the worktree index; `git ls-files` was unavailable. No external planning store was referenced. No external kernel source was opened and no runtime checks ran.

## Findings

### Critical (blocking)

1. **Linux `/proc` absence is not always proof of exit.** D2 accepts ENOENT on `stat` or `status` unconditionally. [INFERENCE: Linux procfs visibility semantics] With `hidepid=2`, a same-user process can be listed while inspectable, then become non-dumpable and return ENOENT while still alive. The verification listing can omit that same live process. This can clear an unread PID and let `settler.dart:278–281` delete the ledger row. It is not D6: the process was alive before the final listing and never exited. Require independent evidence of absence when procfs can hide a live PID; otherwise return false. A2 must state the visibility prerequisite.

2. **Reading one task’s status does not justify accepting `Threads: 0`.** D2 accepts `Z`/`X` with *at most* one thread, but A2’s own argument requires the observed leader to still count as **one**. [INFERENCE: Linux status generation and leader handoff] A status reader can retain the old task across a sibling’s `exec`, sample its zombie state, and then lose access to its signal state before the thread count is emitted. A zero count does not prove that the replacement group has no runnable thread. Require exactly one thread and establish that `Z`/`X` plus that count is sound across handoff. Map a `Z`/`X` plus zero regression; `R` plus one does not exercise this case.

3. **The new waiting macOS call can prevent the host from reaching its shutdown deadline.** D2 and A3 acknowledge that `proc_pidinfo(arg: 1)` can sleep with no stated upper bound. Non-leaf protects other isolates’ safepoints, not the calling isolate’s timer. `unit_manager.dart:504–529` uses a same-isolate timeout, and `host.dart:557–571` awaits shutdown before finishing. A stalled call can therefore keep the profile lock held and prevent the next host from reconciling. The execution-host spec requires exit within the deadline (`openspec/specs/execution-host/spec.md:46–59`); the caveat in `architecture.md:204` does not change that requirement. Keep the waiting probe off the deadline-owning path, with bounded outstanding work and unconfirmed results on timeout, or obtain an explicit decision to change the shutdown contract.

### Moderate

4. **D1 does not preserve the population boundary for readable zombie snapshots.** `marker_scan.dart:132–142` skips zombies before checking UID and age. Replacing that skip with D1’s pending branch can make a Linux zombie leader with live threads block cleanup even when its snapshot establishes another UID or a start before the window. Preserve the population filter when the snapshot supplies reliable exclusion evidence; do not use macOS’s placeholder start time as such evidence. Extend the existing population test with an out-of-population zombie whose exit probe would return false.

5. **D6 is an explicit owner-approved limit, not an existing ADR 0001 exception.** ADR 0001 §5 names an escapee that clears its environment; D6 also permits missing a descendant that retains its marker. ADR 0014 §D2 links #9 for escapees in the *activity read*, not for marker-scan verification. The cleanup delta still says no marked process remains. Carry the accepted final-listing limitation into the cleanup requirement, attribute it to the owner’s decision, and qualify D1’s “the second pass reads it” claim to descendants still present and in the scan population. Do not reopen the owner’s decision.

6. **The macOS fallback is not linear in the process population.** A fresh full listing per failed probe costs \(O(PN)\) per sweep for \(P\) fallback PIDs and \(N\) table entries. The existing `listPids` can make a sizing call and four buffer attempts (`posix_process_table.dart:271–304`). At \(P=\Theta(N)\), one sweep is quadratic and can run entirely past the settle clock. State that cost and the requirement for a complete, non-truncated listing, or amortize one fresh complete listing across the failed probes in a sweep without using evidence older than those probes.

7. **The delta still promises a PID-bearing scan reason when listing failure or timeout can win.** “A live process cannot be inspected” no longer dictates the *unit* reason, but still dictates the *scan* reason. An unresolved first-pass PID followed by an unlistable verification pass satisfies both scenarios; `marker_scan.dart:42–49` selects `scan-unlistable`. Specify that unconfirmed unreadability prevents a clean result, and qualify the named reason by scan precedence. Map the combined case.

8. **The real-zombie fixture does not prove that it exercised the zombie branch.** Printing a background PID and `exec`ing the shell does not establish that the child exited *after* the shell stopped reaping, or even that it exited before the probe. A true result can pass through absence instead. Synchronize the fixture and independently establish that the child is present and unreaped at the probe. Keep the waited-child case separate.

9. **The planning artifacts still give implementers conflicting instructions.** Proposal S1 says confirmation must occur *during* settle, excluding D1’s immediate recheck. The T3 diagram lists again only on the pending branch. The T4 diagram retains the rejected split Linux reads and macOS ESRCH proof. C3 rejects “an errno” without distinguishing Linux’s proposed absence evidence from macOS’s unreliable errno. Correct these to match the final decisions. Also fix two unsupported context citations: `marker_scan.dart:59–64` shows the current pass record, not pending state; `posix_process_table.dart:385–412` omits the first sysctl failure path at lines 380–384. D3 should say a timed-out first pass still attempts kills for matches already collected before returning, as `marker_scan.dart:79–91` does.

### Suggestions

None.

## Verdict

VERDICT: USER_OVERRIDE

The round-4 reviewer returned REVISE and asked to escalate the open blockers before another full round: "Preserve D6; the blockers concern false exit evidence and the host shutdown deadline, not the accepted race after the final listing."

**Owner decision after round 4.** The owner accepted the design after round 4, with these fixes applied and no round 5:

> fix all 9 findings, taking the non-waiting macOS evidence for #3 (drop the waiting arg-1 call; confirm only on absence from proc_listpids or a different start time from the leaf read), then go to tasks with no design round 5. Record in review.md that the owner accepted the design after round 4 with these fixes.

## Required Changes

CHANGES_APPLIED: n/a

The fixes the owner accepted, each applied to the planning artifacts:

1. **Fixed.** Linux ENOENT/ESRCH confirms an exit only when `/proc` is not mounted with `hidepid` (read from `/proc/self/mountinfo`; unreadable counts as `hidepid`). A2 states the visibility fact. Decoding tests map `hidepid` on and off. (D2, A2, C3, test map)
2. **Fixed.** `Threads:` must be exactly 1 with `Z`/`X`; a zero count is mapped as a regression. (D2, C3, test map)
3. **Fixed, by the owner's choice.** The waiting `arg` 1 call is dropped. macOS confirms only on a start-time difference from the existing leaf `arg` 0 read, or absence from one complete `proc_listpids` made after those reads. No call can wait, and no errno is read. An unreaped macOS zombie stays unconfirmed (cost stated in D3 and Risks). (D2, A3, C8, T4, ledger)
4. **Fixed.** The population filter (uid, known start before the window) runs before a snapshot makes a pid pending; the macOS placeholder start time excludes nothing. An out-of-population zombie test is mapped. (D1, C1, test map)
5. **Fixed.** The final-listing limit is in the cleanup requirement text as the owner's decision, and D1's claim is qualified to descendants still present and in the population. (spec delta, D1, proposal)
6. **Fixed.** `confirmedExits` takes a set of pids and makes one complete listing per call, so one settle sweep makes one listing. The cost is stated in the bounds table. (D2, Resource Bounds)
7. **Fixed.** "A live process cannot be inspected" says the unit is not cleaned and qualifies the named reason by scan precedence; the combined unlistable case is mapped. (spec delta, test map)
8. **Fixed.** The real-zombie fixture is synchronized: it waits for the parent's `exec`, releases the child, and polls the snapshot until it is a zombie (rule 6, loud failure) before probing. Linux confirms it; macOS does not until it is reaped. The waited-child case stays separate. (test map)
9. **Fixed.** Proposal S1 says "before the second listing"; T3 shows the second pass after any not-read pid; T4 lists only the final evidence; C3 separates Linux ENOENT from macOS errno; the citations are `marker_scan.dart:59-64` as today's pass record and `posix_process_table.dart:380-412`; D3 says a timed-out first pass still kills its collected matches.

## Rebuttals

1. **Accepted.** D1 and the test map now require a second listing after immediate first-pass exit confirmation, even without a match. The owner explicitly settled the remaining final-listing race. Finding 5 concerns where that limit is recorded.
2. **Partially accepted.** One status read removes the original cross-lookup bug. It does not establish that a zero count is valid exit evidence during leader handoff.
3. **Partially accepted.** The separate non-leaf binding and removal of macOS errno fix the binding issue. The calling isolate can still wait, and the fixture can pass without exercising the zombie path.
4. **Partially accepted.** The design removes the unsupported latency estimate and accounts for full iterations, sweeps and Linux listings. It still understates macOS fallback work and does not reconcile the waiting call with the normative shutdown deadline.
5. **Partially accepted.** Modified Capabilities now preserves first-pass unreadability and no longer dictates the unit reason. Proposal S1 and the delta’s scan-level precedence still need correction.
6. **Accepted.** The design acknowledges that one refusal after a normal first-pass match can fail verification, and explicitly plans to correct the Linux zombie documentation without changing snapshot callers.