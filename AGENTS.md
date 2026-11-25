# Kumiko

Kumiko is a Flutter desktop workbench for agentic software development on
Windows, Linux and macOS: coding-agent runtimes (Claude Code, Codex, OMP), real
terminals, source control and light editing in one window. A Flutter desktop app
talks to a separate Dart execution host over a versioned protocol.

These instructions are shared by every harness (Claude Code, Codex, OMP). Keep
them harness-neutral. `CLAUDE.md` only imports this file.

## Where things are

- `packages/desktop`: the Flutter app. `packages/host`: the execution host.
  `packages/host_protocol`: the desktop-host messages. `packages/domain`: the
  platform-independent workbench model. `packages/process_containment`:
  contained process units (Windows jobs, POSIX sessions).
- `third_party/`: vendored components, each with a `KUMIKO.md` recording its
  source, licence and changes. Leave their code alone unless a change says so.
- `tool/`: repository tools (dependency audit, qualification record, host
  bundling) and their tests.
- Planning uses OpenSpec with Specwright (`openspec/`, `openspec/specwright.yaml`).
  The strategy, architecture and roadmap are `openspec/strategy.md`,
  `openspec/architecture.md` and `openspec/roadmap.md`; decisions are ADRs in
  `docs/adr/`.

## Commands

The toolchain is pinned in `mise.toml`: Flutter (with its bundled Dart) and
Rust. Run everything through mise from this directory, either as a task or as
`mise exec -- <command>`. Never use a bare `dart` or `flutter` from `PATH`, and
never pin or install a separate Dart SDK: build hooks compiled by one SDK are
refused by another ("Invalid SDK hash").

| Task | Use |
| --- | --- |
| `mise run check` | Pre-commit gate: `format:check`, `analyze`, `test:fast`. Must pass before you commit or report work as done |
| `mise run analyze` | `dart analyze --fatal-infos` for the workspace, then `flutter analyze --fatal-infos` for the desktop |
| `mise run format` / `format:check` | Format, or check formatting of, the source folders under `packages/` and `tool/` |
| `mise run test:fast` | Every suite except the host's: the edit loop |
| `mise run test:host` | Host tests, including the integration tests (builds the test host first; about a minute) |
| `mise run test` | Every package's tests, as CI runs them |
| `mise run test:<package>` | One package: `tool`, `domain`, `host_protocol`, `process_containment`, `host`, `desktop` |
| `mise run build:host` / `build:host-test` | Build the release or test host bundle |
| `mise run audit` | Dependency audit and qualification record check |

- Run the affected test files directly as well, for example
  `mise exec -- dart test test/it/terminal_test.dart` in `packages/host` or
  `mise exec -- flutter test test/terminal_test.dart` in `packages/desktop`.
- A change to the host, the protocol or process containment needs
  `mise run test:host` before it is reported done.
- Desktop integration tests (`packages/desktop/integration_test/`) run one file
  per `flutter test` with `--dart-define=KUMIKO_HOST=<host bundle>`; CI shows the
  exact invocation per OS in `.github/workflows/ci.yml`.
- Enable the pre-commit hook once per clone: `git config core.hooksPath .githooks`.
  It runs `mise run check`.

## Tests that run in Windows CI

A test must never fail because the runner is slow. A hosted Windows runner can be 10-50x slower than your machine at any moment (antivirus, cold process start, fsync, a noisy neighbour). If more time alone can turn green into red, the test is wrong.

1. **Assert order and outcome, not elapsed time.** No `elapsed < X`, no Stopwatch upper bounds, no "at most N ms" in a correctness test. Assert what happened and in what order.
2. **Wait for the event, never for a duration.** No sleep to "let it settle", "let the child start" or "let the write land". Wait on a completer, a ready or ack message, a process-exit handle, a stream event, or a file the code under test writes when it's done.
3. **Deadlines and timeouts under test use an injected or fake clock.** When the behaviour being tested *is* a timeout, drive it with a fake or manual clock, or fire it explicitly once the code has reached the stage being tested (a per-fault deadline). Never give a real budget that also has to cover startup, I/O or unrelated work.
4. **Real time only as a hang guard.** A real-time limit exists only to stop a hung test. Make it generous (minutes, not seconds), put one around the test, and never use its expiry as an expected outcome or map it to a value (such as `false`).
5. **Process and file lifecycles are confirmed, not assumed.** A returned kill, taskkill or launcher exit doesn't mean the child exited or its handles closed. Await the exit or the handle before reusing a lock, a file or a directory. Don't delete a directory a watcher or child may still hold.
6. **Polls are not deadlines.** A poll loop that gives up after N tries must fail loudly with what it was waiting for. It must never carry on silently, and it doesn't replace rule 2.
7. **Performance is a benchmark, not a gate.** Throughput, latency and "complexity" checks go in an opt-in benchmark or a nightly report, not in the PR gate. In CI, assert work counts (operations, batches, copies) instead.
8. **No retries to get green.** Never rerun a red test, add a retry around a flaky assertion, or tell agents to rerun known flaky rows. Fix the test. Retries are allowed only for downloading setup tools.
9. **Tests don't share process state.** No `Directory.current` or cwd changes, global env or fixed temp paths shared across concurrently running test files. Pass absolute paths and a working directory.
10. **Keep real OS coverage, behind barriers.** Tests of real Job Objects, pipes, locks, firewall rules or services stay. They synchronise on events, as above, with one outer hang guard.

When fixing a flaky test, say which rule it broke in the commit or PR.

## Agent tooling

- The official Dart and Flutter MCP server (`dart`) is configured for every
  harness: `.mcp.json` (Claude Code), `.codex/config.toml` (Codex) and
  `.omp/mcp.json` (OMP), all with
  `mise exec -- dart mcp-server --enable cli,flutter_app_lifecycle`.
  mise sets `DART_DATA_HOME` to `.dart_tool/dart-data`, so this repository's
  server does not collide with servers other projects or agents have running.
  Verification goes through the mise tasks; the MCP tools are for analysis,
  pub.dev lookups and running the app.
- The official Dart and Flutter skills (from dart-lang/skills and
  flutter/agent-plugins) are installed in `.claude/skills/` (Claude Code) and
  `.agents/skills/` (Codex). OMP reads both. They come from the owner's
  PromptHub library, where each is bound to its upstream directory:
  `prompthub skill check-update <name>` compares it with upstream, and
  `prompthub skill update-source <name>` pulls a new upstream version into the
  library. Then refresh the project copy with
  `prompthub skill project-install <name> --project . --target <folder> --force`
  for both folders. Do not edit installed skills by hand. Their licences
  are in `.claude/licenses/` and `.agents/licenses/`.
- The Specwright and OpenSpec workflow skills, commands and agents live in the
  same folders and in `.omp/`.

## Rules

- Never copy code from studied open-source projects; see `ACKNOWLEDGEMENTS.md`.
- Clean up the temporary files, worktrees and processes you create.
