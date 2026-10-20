---
name: specwright-release
description: "Opt-in release tagging for Specwright projects (release.enabled): bumps the version files as a tracked task in a change, and after the change is on main publishes the annotated tag and the GitHub release through scripts/release.sh. Backfills an older untagged version on request. Triggers: 'release', 'tag', 'publish v0.5.0', 'backfill a tag', or specwright-finish, specwright-pr watch and specwright-roadmap close offering a release."
metadata:
  version: 0.7.0
---

# Specwright Release

The script lives in `${CLAUDE_SKILL_DIR}/scripts/` (in other harnesses: the `scripts/` folder next to this SKILL.md); below, `scripts/release.sh` means that path. Run it with `bash` (Git Bash on Windows) from the code checkout, as `bash scripts/release.sh [--dir <repo>] <sub>`. It prints one JSON document. Exit 0 = done, 1 = stop (show its `message`), 2 = usage error, 3 = a git or `gh` network call failed or was refused.

Acts only with `release.enabled: true` in `openspec/specwright.yaml`; otherwise do nothing and mention no release.

```yaml
release:
  enabled: false                      # opt in
  version_files:                      # path or glob -> regex; the first is the primary
    VERSION: '^(\d+\.\d+\.\d+)$'
  tag: "v{version}"
  github_release: true                # also create the GitHub release from the tag's message
  auto: false                         # true = callers publish without asking
```

`release.enabled` with `pr.merge_method: rebase` is refused: a rebase rewrites the release commit.

## bump

A tracked task in the change's last task group, committed by the orchestrator through `specwright-commit`: `bash scripts/release.sh bump --to <version>` rewrites every version file and commits nothing. Verify with `bash scripts/release.sh check`, which reports the target version when all files agree.

Two changes can bump to the same version, and main's history then shows it once. `bash scripts/release.sh check --main <ref>` also compares a bumped branch with `<ref>`'s version and refuses (`version_not_ahead_of_main`) one that is not greater: bump again with a greater target. A branch that did not bump, or a `<ref>` with no readable version, passes. With `release.enabled` true, `specwright-pr` **ship** (`--main origin/<main>`, after a fenced fetch of main, before any push) and **watch** (before it reports ready and before the merge), and `specwright-finish` before a local merge (`--main <main>`), run it.

## publish

Once the change is on main (callers: `specwright-finish`, `specwright-pr` **watch**, `specwright-roadmap` **close**):

**Run login.** Use the run login the caller handed over (`run login: <login>`). A publish the user started directly has none: take `github.login` from `openspec/specwright.yaml`, else run `bash <specwright-pr>/scripts/as.sh --resolve` once (it prints the active github.com account; exit 3 → stop and tell the user). Keep it for the whole run. "Origin on github.com" means its fetch URL, `git remote get-url origin` (after `insteadOf`; `github.com.` included), never the raw `remote.origin.url`: a shorthand such as `corp:acme/app` that expands to github.com is on github.com. With origin on github.com, every step below runs through `as.sh <run login>`, never unfenced; plain calls are only for an origin elsewhere.

1. Fetch main only, without tags, fenced when origin is on github.com (`bash <specwright-pr>/scripts/as.sh <run login> git fetch --no-tags origin <main>`), else plain `git fetch --no-tags origin <main>`. Never `--tags`, and keep `--no-tags` (a clone with `remote.origin.tagOpt=--tags` fetches every tag otherwise): a local tag that differs from origin's (a lost push race) would fail the fetch before publish can report it. `release.sh` reads origin's tags itself (`ls-remote`) and fetches only the tag it publishes. Pass `--main origin/<main>` after a fetch, `--main <main>` otherwise.
2. `bash <specwright-pr>/scripts/as.sh <run login> bash scripts/release.sh untagged --main <ref>` (it reads origin's tags; plain `bash scripts/release.sh untagged ...` only when origin is not on github.com) lists the versions after the latest published one that are not published, oldest first (none published: only the current version). Published means the tag is on origin (with no origin remote: a local tag); a version whose tag is local but not on origin (a failed push) is always listed, and a re-run pushes it. Publish each oldest first and stop at the first failure. `untagged --local` reads local tags only, with no network call and no login (`specwright-finish` in `finish: local`); its output says `"tags": "local"`, since a local tag may be missing on origin. Publish still reads origin.
3. `bash <specwright-pr>/scripts/as.sh <run login> bash scripts/release.sh publish --version <version> --main <ref>` from the code repo, so every git and `gh` call inherits the fence; plain `bash scripts/release.sh publish ...` only when origin is not on github.com. It checks the remote, stops on a conflicting tag, creates the annotated tag, pushes only `refs/tags/<tag>` and creates the GitHub release. It is idempotent: a re-run resumes.
4. Store-backed: add `--store <store toplevel>` (and `--store-main <ref>`, `--store-prefix <P>`) to `status` and `publish`, so the notes come from the store's archive. Only the code repo is tagged.

The tagger is git's committer identity: the commit-identity rules of the project (CLAUDE.md/AGENTS.md) apply.

Report per version: `release v0.5.0: tag pushed at <sha>, GitHub release created`, or `release v0.5.0: already published`.

## Stops

Show the error and tag nothing more. None is fixed by moving, deleting or forcing a tag.

| Exit | Error | Do |
|---|---|---|
| 1 | releases disabled | do nothing |
| 1 | `pr.merge_method` rebase, or a rebase-merged release commit | report the commit or settings; the user tags by hand or changes the merge method |
| 1 | version files disagree | the user fixes them by hand; run `check` |
| 1 | version not on main | publish after the release commit reaches main |
| 1 | tag exists at another commit | the user fixes it by hand |
| 1 | a lightweight tag at the release commit | the user replaces it by hand with an annotated tag, or deletes it |
| 1 | `push_url_mismatch`: origin pushes to another repository than it fetches from | the user fixes `remote.origin.pushurl`, or publishes from a remote whose URLs agree |
| 1 | `tag_mismatch`: the local tag and origin's are different tag objects (a lost push race) | the user deletes the local tag (`git tag -d <tag>`); a re-run fetches origin's |
| 1 | a `version_files` entry outside the repository, or a symlink | the user fixes `release.version_files` (list the file a link points to) |
| 1 | an older version is untagged | publish it first (`untagged` lists it) |
| 1 | `version_not_ahead_of_main`: the branch bumped to a version not greater than main's | rerun `bump --to` with a greater version, commit it, and ship or merge again |
| 3 | network or fence failure | report it; a re-run of publish resumes |

## Backfill

`publish --version <old>` for an older untagged version, only when the user asks.

## Never

Never delete or move a tag, use `--force` or `--tags`, push a branch, tag the store, or publish without `release.enabled`.
