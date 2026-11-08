# Acknowledgements

## Applications studied

While designing Kumiko we studied the following open-source applications to
understand how existing tools approach similar problems: workspaces,
terminals, agent sessions, usage accounting, documents and task tracking.
Our design documents under `openspec/` cite them by name where they informed
a product or design decision, often to explain why Kumiko chose differently.

We studied them; we did not copy any part of their source code. They are not
dependencies of Kumiko, and Kumiko does not include, translate or port their
code.

| Application | Repository | Licence |
|---|---|---|
| Orca | <https://github.com/stablyai/orca> | MIT |
| T3 Code | <https://github.com/pingdotgg/t3code> | MIT |
| ItsAPlan | <https://github.com/croffasia/itsaplan> | AGPL-3.0-only |

Thanks to their authors for building in the open.

## Vendored third-party components

Kumiko vendors some third-party components under `third_party/`. Each keeps
its own licence, and each has a `KUMIKO.md` that records its source, licence
and any changes Kumiko makes to it.

The vendored `flutter_alacritty` package contains comments, written by its
upstream author, that credit Orca for terminal scrolling behaviour. Those
comments are part of the upstream package, and Kumiko leaves them unchanged.

## Agent skills

`.claude/skills/` and `.agents/skills/` include the official Dart and Flutter
agent skills, copied unchanged from these projects (installed through the
owner's PromptHub library). They guide coding agents working on this
repository; they are not part of Kumiko and do not ship with it.

| Skills | Repository | Licence |
|---|---|---|
| `dart-*` | <https://github.com/dart-lang/skills> | BSD-3-Clause |
| `flutter-*` | <https://github.com/flutter/agent-plugins> | BSD-3-Clause |

Their licence texts are in `.claude/licenses/` and `.agents/licenses/`.
