# Review

## Metadata

- **Round:** 12.
- **Prior round:** Round 11, REVISE; second consecutive REVISE, followed by the owner’s administrator-trust decision.
- **Reviewer:** Codex, fresh-context, read-only adversarial design reviewer.
- **Reviewed:** `AGENTS.md`; revised qualification-wrapper rule and D5 removed-entry/approval-diagnostic bullets in `design.md`; native-wrapper amendment in `tasks.md`; Attempt 12 paragraph in `proposal.md`; Round 11 `review.md`; twelfth-attempt qualification section and JSON receipt; `evaluateCanaryApproval`, `allowedCanaryApproval` and qualification-loop caller; Specwright review template.
- **Method:** Repository reads only. No modifications, builds, tests, native Codex execution, provider calls or native Codex-home access.

## Findings

### Critical (blocking)

None.

### Moderate

**M1. The diagnostic definition accidentally makes optional `-NoProfile` mandatory.**

Design item 6 defines `wrapperNoProfile` as whether the second word is `-NoProfile`, then defines `wrapperMatches` as “all four hold” with the appropriate word count. Read literally, the four flags include `wrapperNoProfile`.

For the explicitly permitted argv:

```text
[trustedShell, -Command, approvedCommand]
```

the shell, command-flag and script checks pass, but `wrapperNoProfile` is false. Item 6 therefore reports `wrapperMatches: false`, contradicting item 2 and the tasks’ positive fixture.

This is a localized specification defect, not an identified approval bypass. It nevertheless undermines the next receipt’s purpose and creates conflicting requirements for test-first implementation. Specify the conjunction explicitly and assert the diagnostic for both permitted shapes.

### Suggestions

None beyond the required correction.

## Verdict

The wrapper admission rule is sufficiently narrow under the owner-approved trust assumption. Exact decoded argv length, literal case-sensitive flags and exact final-script equality reject additional arguments, alternative flags and command suffixes. ASCII-only case comparison avoids Unicode case-folding surprises; trusted-set membership and lexical restrictions exclude arbitrary PowerShell basenames and alternative path spellings. Registered PowerShell 7 is acceptable for this qualification fixture.

The decoder specifies single quotes, double-quoted escapes, adjacent fragments, empty words and outside-quote escapes precisely enough to implement independently. Its control-character and active-syntax refusals are deliberate restrictions. No concrete legitimate POSIX join of the described single-line canary wrapper was identified that those restrictions would reject. The synthetic complete-wrapper fixture now exercises the important quoting interactions.

The administrator trust assumption is explicit in design item 4 and repeated in tasks. ACL inspection is intentionally excluded by the owner’s decision and is not reopened here. Ancestor reparse traversal is separately prohibited and covered by planned tests.

Round 11 disposition:

| Item | Round 12 assessment |
|---|---|
| Required Change 1: ancestor traversal, executable replaceability and trust assumption | Ancestor traversal addressed; replaceability resolved by the explicit owner-approved trust assumption |
| Required Change 2: resolution-failure semantics | Addressed: candidates fail independently; mixed success retains valid entries; an empty set refuses before consuming approval |
| S1: malformed-argv diagnostic positions | Addressed positionally, subject to M1’s aggregate-flag correction |
| S2: representative complete source-shaped join | Addressed by the synthetic full-wrapper fixture |

The amendment preserves every other approval check and the caller’s one-answer guard. It introduces no persistent grant, new prompt, native policy override or automatic retry. Its scope as qualification-helper behavior is consistent with no product spec scenario changes.

The proposed diagnostic fields remain content-free booleans and bounded counts. The task list adequately covers parser behavior, shell admission, malformed shapes and failures across the unchanged fence, subject to M1.

Proposal, design and tasks consistently distinguish the Codex 0.165 source-supported explanation from the unobserved command shape in the Codex 0.166.0 attempt-12 receipt. The historical qualification records correctly remain INCOMPLETE. The current matcher still implements the original exact rule; the amendment is explicitly pending implementation.

## Required Changes

1. In design item 6, replace “all four hold” with an explicit definition:

   ```text
   wrapperMatches =
       observedArgvParsed
       && wrapperShellTrusted
       && wrapperCommandFlag
       && wrapperScriptMatches
       && decodedWordCount == (wrapperNoProfile ? 4 : 3)
   ```

   Use the actual decoded count for shape validation, independently of the clamped diagnostic count.

2. In the tasks’ diagnostic coverage, explicitly require `wrapperMatches: true` for both valid three-word and four-word wrappers, with `wrapperNoProfile: false` and `true` respectively.

## Rebuttals

Round 11’s ancestor-traversal, resolution-failure and complete-wrapper-fixture responses are accepted. The ACL portion is resolved by the recorded owner decision. Malformed-shape diagnostic positions are accepted; the aggregate predicate needs the correction above.

VERDICT: APPROVE_WITH_CHANGES

## Focused Recheck (Round 12 Required Changes)

### Required Change 1 — Applied

Evidence: `openspec/changes/codex-app-server-session/design.md:133` explicitly defines `wrapperMatches` as `observedArgvParsed && wrapperShellTrusted && wrapperCommandFlag && wrapperScriptMatches`, together with an actual decoded word count of exactly four when `wrapperNoProfile` holds, otherwise exactly three. It explicitly distinguishes the actual count from the clamped diagnostic count and states that `-NoProfile` remains optional.

No new inconsistency found with design items 1–5 and 7 (`design.md:127–134`). The definition admits both shapes in item 2, retains the decoder and trusted-shell requirements, and preserves the exact-match route, other approval checks and authorization limits.

### Required Change 2 — Applied

Evidence: `openspec/changes/codex-app-server-session/tasks.md:567–568` explicitly requires valid wrappers to report `wrapperMatches: true`, with `wrapperNoProfile: false` for the three-word shape and `true` for the four-word shape.

No new inconsistency found with the rest of the amendment section (`tasks.md:527–584`). This requirement agrees with the positive fixtures at lines 541–544 and the revised design predicate. Malformed-shape positional diagnostics, parse-failure behavior, exact-match field omission, unchanged-fence refusals and the observational role of diagnostics remain consistent.

CHANGES_APPLIED: yes