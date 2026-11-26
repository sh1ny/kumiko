# Contributing to Kumiko

Thanks for helping. Kumiko is a Flutter desktop workbench for agentic software development on Windows, Linux and macOS: coding-agent runtimes, real terminals, source control and light editing in one window. A Flutter desktop app talks to a separate Dart execution host over a versioned protocol.

Kumiko is early and changes fast. Expect breaking changes between versions.

## Ways to help

- **Report a bug or suggest an idea.** Open an [issue](https://github.com/sh1ny/kumiko/issues/new/choose). The forms say what helps; only the first box is required.
- **Fix something small** (a typo, a doc, an obvious bug): send a pull request straight away.
- **Anything bigger** (a new feature, a new dependency, or a change to how the parts talk to each other): open an issue first, so we can agree on the approach before you spend time on it.
- **Found a security problem?** Don't open an issue. Report it privately as [SECURITY.md](SECURITY.md) describes.

## How the project is planned

Maintainers plan work with [OpenSpec](https://github.com/Fission-AI/OpenSpec) and [Specwright](https://github.com/sh1ny/specwright): milestones live in `openspec/roadmap.md` and each larger change gets a folder under `openspec/changes/`. You don't need either tool to contribute. If your change is larger, a maintainer may write it up as an OpenSpec change and ask you a question or two. Please don't edit `openspec/changes/` in your pull request unless you're asked to.

Much of the maintainers' own work is done with AI coding agents, and an automated reviewer may comment on your pull request. A person makes every decision. AI-assisted contributions are welcome too, as long as you understand and have tested what you send.

## Setup

Install [mise](https://mise.jdx.dev/). It provides the pinned Flutter and Dart; don't use a `dart` or `flutter` from elsewhere on your `PATH`.

```sh
mise install
git config core.hooksPath .githooks   # once per clone: runs `mise run check` before each commit
mise run check                        # format, analyze and the fast tests
```

`mise run test:<package>` runs one package's tests (`tool`, `domain`, `host_protocol`, `process_containment`, `host`, `desktop`). If you change the execution host, also run `mise run test:host` (it builds a test host first and takes about a minute).

## Making a change

- Branch from `main` and keep each pull request to one change.
- **Tests.** Add or update tests for behaviour you change. A test must never fail because a machine is slow: wait for an event or a result, never sleep for a fixed time.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, for example `fix(map): show transits on Reserve`. If you get it wrong, a maintainer will fix it when merging.
- **Write it yourself.** Don't copy code from other projects, including translating it from another language. Adding a dependency is fine when its licence is compatible, but mention it in the pull request.

### Rules specific to Kumiko

- Keep the desktop app and the execution host separate: they only talk through `packages/host_protocol`. A change to the protocol is a bigger change, so open an issue first.
- `packages/domain` stays platform-independent: no Flutter and no `dart:io` there.

## Pull requests

The template asks for three things: a short **Summary**, what it's **Linked** to (an issue, or "none"), and how you **tested** it. Everything else is optional.

CI runs on every pull request. If it fails and you can't see why, say so in the pull request and we'll help. A maintainer reviews and merges.

## Licence

By contributing, you agree that your contribution is licensed under the project's [Apache-2.0 licence](LICENSE).
