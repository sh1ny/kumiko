# Tasks

## Test map

| Requirement | Scenario | Check | Test or task | State |
|---|---|---|---|---|
| Real OMP qualification is recorded separately from regression tests | Approved Windows desktop walk completes | Live Windows release desktop and the exact installed OMP | 3.2 owner-visible checks and 3.3 sanitized evidence; no fixture substitution | user |
| Real OMP qualification is recorded separately from regression tests | A required observation fails or does not occur | Live walk notes and the checked evidence | 3.2 owner confirms what appeared or was missed; 3.3 records the actual failed or unverified item without a claim | user |
| The OMP evidence audit runs offline | Complete passing evidence | `tool/test/check_qualification_test.dart` | `OMP audit reports a complete Windows attempt for its exact version` | green |
| The OMP evidence audit runs offline | Failed and incomplete attempts stay separate | `tool/test/check_qualification_test.dart` | `OMP audit does not combine failed and incomplete attempts` | green |
| The OMP evidence audit runs offline | Malformed evidence is not a qualification claim | `tool/test/check_qualification_test.dart` | `OMP audit rejects invalid files without printing pass`; `OMP audit rejects reused approval references` | green |
| The OMP evidence audit runs offline | No real run is recorded | `tool/test/check_qualification_test.dart` | `OMP audit makes no claim when no attempt is recorded` | green |

## 1. Offline evidence audit and runbook

- [x] 1.1 Write the named red tests against `tool/check_qualification.dart` using disposable synthetic inputs, never an installed-runtime launch. Cover missing, invalid UTF-8 or JSON and oversized inputs, invalid identity and approval fields, duplicate attempt ids or approval digests, duplicate, missing or unknown items, unsupported OS, and whitespace-only notes. Assert exit status and checked output, including no positive OMP status on a malformed file with an otherwise valid passing row. Confirm the new behavior fails before implementation and retain the red command/output for the commit.
- [x] 1.2 Implement the offline audit from D1. Add the empty checked-in Windows record and keep the two-positional-argument Claude tooling and default Codex behavior intact. Verify the four offline scenario rows and existing CLI tests in `tool/test/check_qualification_test.dart`. Confirm `mise run audit` reads the empty OMP record and reports no OMP claim without contacting a runtime. Check C1, C2 and C5 in the delta spec.
- [x] 1.3 Write `docs/qualification/omp-rpc.md` with the Windows release walk, privacy and cleanup boundaries, full required result criteria, and separate compatibility and observations sections. Include the offline record shape and verification commands. Carry C3 and C4 from ADRs 0018 and 0019 into the runbook's shared-contract comparison without editing the accepted ADRs. Review the runbook against all D2–D4 steps, including the prompt budget, exact plan hash and spent marker, separate close and save outcomes, and opt-in only. Link the new evidence from the runtime qualification section of `openspec/architecture.md`.

## 2. Prepare the isolated Windows walk

- [x] 2.1 After explicit build approval and a clear gaming guard, build the packaged Windows release with the release host. Confirm the desktop and bundled host identity against the build revision. Do not start OMP. Settle A1 with installed version/help and exact-version public source. Verify the scratch layout, root and child model selection, target and storage paths, isolated desktop launch environment and unchanged native sign-in resolution using non-secret metadata only. Stop before live work if any fact cannot be established.
- [x] 2.2 Prepare the exact D2 plan with the synthetic prompts, click and observation sequence, release and runtime identities, profile arguments and model. Validate the plan against the on-disk scratch targets and check the provider workload is within D3. Present the exact plan and digest for separate explicit owner approval. Do not launch or claim the attempt without approval. A build approval or Orca fallback does not count.

## 3. Observe and record the approved walk

- [x] 3.1 Before launching, recheck D2 and the gaming guard, and consume the approval once. Run only the approved walkthrough in the temporary profile. Settle A2 by recording each observed or missed event without another prompt or attempt. Keep the private notes and owned process handles until evidence capture and cleanup.
- [ ] 3.2 [user] Check the running Windows desktop during 3.1 after separate approval. Observe start and streaming, approve and deny, tools, active Stop, the read-only child pane, close and quit decisions, and the saved pane and restored history after explicit Continue. Report missing or unexpected observations. Leave the check pending if the owner has not confirmed what they observed.
- [x] 3.3 [evidence] Record the exact approved Windows attempt in `docs/qualification/omp-rpc-windows.json` and the capability differences in `docs/qualification/omp-rpc.md`. Verify with `mise run audit`, compare the audit verdict to the observed rows, and verify owned processes settled and scratch data was removed. Bring failed required observations or an upstream OMP defect to the owner before treating qualification as complete. Record the source revision, version, audit result and path to the durable record in the change evidence. → evidence/windows-observation.md

## Workflow follow-up

- Complete the separate pre-ship review, push and open the Kumiko PR with the fenced GitHub identities, and watch the required checks and reviews.
- Archive on the PR branch after the user check and reviews settle. Watch the archive head and report the ready PR without merging it.
