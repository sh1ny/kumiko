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
- Timing rows in the host suite can fail under a loaded machine: the 250 ms
  control round-trip bounds in `protocol_qualification_test` and
  `agent_qualification_test`, and the close-acknowledgement bound in
  `terminal_qualification_test`. `terminal_test`'s "no terminal start leaves a
  reserved channel behind" has also failed intermittently on macOS. Re-run them
  alone before treating a failure as real.
- Enable the pre-commit hook once per clone: `git config core.hooksPath .githooks`.
  It runs `mise run check`.

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
