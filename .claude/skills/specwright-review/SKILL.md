---
name: specwright-review
description: "External Claude reviews for Specwright changes, always launched through Orca skills in a fresh tab or pane with structured report-back. Validates findings and fails closed; pre-ship mode blocks on concrete P0/P1 defects, not an open-ended zero-findings loop. Triggers: 'review before ship', 'run the pre-ship review', a design review step (FULL tier, roadmap baseline), or specwright-commit, specwright-pr ship and specwright-finish calling it."
metadata:
  version: 0.10.0
---

# Specwright Review

The script lives in `${CLAUDE_SKILL_DIR}/scripts/` (in other harnesses: the `scripts/` folder next to this SKILL.md); below, `scripts/review-run.sh` means that path, and other skills call it `<specwright-review>/scripts/review-run.sh`. Run it with `bash` (Git Bash on Windows) from the code checkout. It needs bash, git and Python 3.8+, makes no `gh` call, and prints one JSON document per call. Exit 0 = ok, 1 = stop (show its `message`), 2 = usage error, 3 = failed review.

## Settings

This project's reviewer is always external Claude through Orca. Helper limits remain configurable in `openspec/specwright.yaml`:

```yaml
review:
  cross_model: true
  order: [claude]
  # Omit model/effort overrides unless the user requested them; Orca inherits
  # the configured Claude default.
  timeout: 20m
  max_diff_kb: 3072
  preship: true              # false = no pre-ship review and no ship/merge gate
```

## Routes

Every local code, design and pre-ship review uses this route, including when the authoring harness is Claude:

If you are already the dispatched Claude review worker, perform the assigned review and report using the live Dispatch preamble; do not launch another reviewer. The steps below belong to the coordinator.

1. Read the `orca-cli` and `orchestration` skills, resolve the Orca executable once, and load their version-matched guides. Use real Orca runtime state, not an in-process subagent.
2. Bind a coordinator Run and launch a fresh worker with `ORCA orchestration worker-start --spec "<self-contained read-only review>" --worktree current --agent claude --json`. `ORCA` means the executable resolved by the skill. Each review starts in a new Orca tab or pane; never reuse the author's session or run a hidden direct CLI reviewer. Inherit the user's configured Claude model unless they named an override.
3. Give the worker the exact reviewed HEAD/range, artifact paths, reviewer brief and required report schema. Keep it read-only except its report files; no builds, tests, formatters, product/provider processes or product edits. Require evidence-backed consumer impact and a realistic trigger; distinguish severity from likelihood.
4. Receive its report through the orchestration `worker_done`/coordinator inbox flow. Validate the active Dispatch, report file and reviewed HEAD before acknowledging completion; release the settled worker according to the orchestration skill. Do not substitute a terminal's silence for a completed review.
5. Use `review-run.sh preflight`, `record` and `gate` for bounds and validated receipts, recording the external report with `--route claude`. `select` may supply CLI availability metadata but never authorizes a subagent or alternate-provider fallback; `run` is not this project's launch path. Missing Claude/Orca or invalid output is a failed review, not permission to review inline.
6. Report the Orca Run/Dispatch/agent identity and findings. Requested settings are not proof of the effective model; report unavailable model metadata as unknown. The helper's generic receipt is not proof of Orca process isolation.

Do one bounded review of the requested change and regressions. P2/P3 findings are non-blocking; do not automatically repeat adversarial sweeps until every finding is gone. A focused verification of an addressed blocker is distinct from reopening the whole scope.

## Design reviews

Use the external Orca/Claude route above for FULL-tier and roadmap baseline reviews. First allocate the report with `bash scripts/review-run.sh record --kind design --change <change-name> --scratch`; give that path, the requested artifacts and review template to the worker.

After its report arrives, run `bash scripts/review-run.sh record --kind design --change <change-name> --result <scratch> --out <review file> --route claude`. It atomically writes the change's `review.md` (or baseline architecture review) only when the verdict and `CHANGES_APPLIED` markers validate. Add `--store <store toplevel>` when planning is store-backed. Exit 3 leaves the prior review untouched and is not a pass.

## Pre-ship review

Reviews the finished change, `<main>...HEAD` of the code repo and, store-backed, of the store, before the change's first PR or a local merge. With `review.preship: false`, skip this whole section and the gate.

**When.** `specwright-commit` step 3 runs it once every task is committed. `specwright-pr` ship (before the change's first PR) and `specwright-finish` (before a local merge) run the **gate** first and come here only on `missing`.

1. **Review.** Resolve the planning repo as the calling skill does, then:
   - Run `bash scripts/review-run.sh preflight --kind preship --change <change-name> --base <main> --prefix <P>` (store-backed: add `--store <store toplevel> --store-base <store main>`) and save its exact output. It checks the complete combined diff against `review.max_diff_kb` and names the reviewed heads and artifacts.
   - Launch external Claude through Orca as specified in Routes. Supply that HEAD, the complete `<main>...HEAD` context, artifact paths, `references/brief.md`, `references/findings.schema.json`, and the report path. Keep the requested review bounded; do not supply author rationale.
   - After structured completion, validate with `bash scripts/review-run.sh record --kind preship --change <change-name> --result <findings file> --route claude --preflight <preflight output>` (store-backed: add `--store <store toplevel>`). If HEAD moved, the record fails closed; never attach a review to a head it did not inspect.
   - Exit 1 `diff_too_large` → no reviewer ran. Report the size and ask the user to raise `review.max_diff_kb` or set `review.preship: false`. Never review a cut-down diff.
   - Exit 3 is a failed review: report its status/error, preserve the prior record, and do not fall back to another reviewer.
2. **Read the result.** P0 and P1 findings block; P2 and P3 do not. No P0/P1 → the review passed: report it and hand back to the caller. Leave P2/P3 findings as they are: the PR description lists them, and fixing them now would leave the new head without a pass. Fix them only when the user asks, or in a round commit you make anyway (step 4).
3. **Blocked.** Show every open P0/P1 finding (id, file, title) with the options: fix, or waive. A waiver comes only from the user: run `bash scripts/review-run.sh waive --change <change-name> --prefix <P> --finding <id> --reason "<the user's reason>"` (store-backed: `--store <store toplevel>`) only after the user explicitly answers that this finding is accepted, with their reason. Never waive a finding on your own judgement. No answer → no pass, and ship does not start. Once every P0/P1 is waived, `gate` reports `pass`.
4. **Fix round.** Before fixing anything, `bash scripts/review-run.sh rounds --change <change-name>` (store-backed: `--store <store toplevel>`) gives `n`, the highest `Preship-Round:` trailer on the branch in either repo. When `n` is 2 or more and the review still has an unwaived P0/P1, stop fixing: list the open findings and ask the user how to proceed (another round, waive, or stop). Otherwise this is round `n+1`:
   - fix each `code` and `test` finding, test-first where it changes behaviour, and run the tests;
   - commit the fixed files by name under the `specwright-commit` rules, one commit per changed repo (store-backed: the store first, same subject and trailer in both), with the subject `<type>(<change-name>): address pre-ship review` and the trailer `Preship-Round: <n+1>`. Never use `address review feedback` or a `Feedback-Round:` trailer for these: those count PR fix rounds;
   - run a new pre-ship review (step 1): the new head has no pass until one passes.
5. **Spec findings** (`category: spec`) carry the reviewer's `spec_class`:
   - **clarification:** one reading of the spec fits every other scenario, and the code and tests already match it. Check that yourself. If it holds, edit the wording in the planning repo and commit it by name as `<type>(<change-name>): amend specs` with the trailer `Amendment: clarification`, then run a new pre-ship review. If it does not hold, treat it as a behaviour change.
   - **behaviour_change:** after the edit, the requirement or scenario would allow something different. Do not edit the spec. Ask the user whether to change the behaviour (the spec, then the code) or the code to fit the spec. Only on their approval: follow the apply drift rule (an `amend specs` commit with the trailer `Amendment: behaviour-change`, a new design review step when the tier is FULL, test and code updates), then run a new pre-ship review.
   - You may treat a clarification as a behaviour change and ask; never the other way round.
6. **Report:** the route and receipt, the findings by priority, what was fixed, amended or waived, and the P2/P3 findings left open.

## Gate

`bash scripts/review-run.sh gate --change <change-name> --prefix <P>` (store-backed: `--store <store toplevel>`) prints `status`:
- `pass`: a record for the current head (or the head before the change's archive commit) has no unwaived P0/P1. Continue.
- `missing`: no record for this head (a new commit, another machine, a lost state dir). Run the pre-ship review.
- `blocked`: the record has open P0/P1 findings (`open`). Go to Pre-ship review step 3.
Records are machine-local (ADR 0007), so a `missing` from another checkout only costs a review.

## Archive-only check

`specwright-pr` watch runs `bash scripts/review-run.sh archive-only --base <ready head> --head <archive head> --change <change-name> --dir <planning repo toplevel> --prefix <P>` after the archive push. `archive_only: true` means the only commit is the change's `archive change` commit and it touches only the archive paths and the synced main specs.

## Credits

The reviewer brief and findings format draw on compound-engineering's [`ce-code-review`](https://github.com/EveryInc/compound-engineering-plugin) skill and oh-my-pi's [`reviewer.md`](https://github.com/can1357/oh-my-pi) agent.
