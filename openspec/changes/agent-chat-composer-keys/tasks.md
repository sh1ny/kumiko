# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| Agent composers support keyboard editing and submission | Submit a nonblank draft with Enter | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter sends the draft once` | green |
| Agent composers support keyboard editing and submission | Enter on a blank draft or during a reply | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter leaves blank and streaming drafts untouched` | green |
| Agent composers support keyboard editing and submission | Confirm an IME candidate | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter leaves IME confirmation to the input method` | green |
| Agent composers support keyboard editing and submission | Insert a line break with Shift+Enter | `packages/desktop/test/agent_composer_keys_test.dart` | `Shift+Enter replaces the selection with a line break` | green |
| Agent composers support keyboard editing and submission | Recall the last accepted prompt | `packages/desktop/test/agent_composer_keys_test.dart` | `Up recalls only the latest accepted prompt` | green |
| Agent composers support keyboard editing and submission | Recall skips a refused prompt | `packages/desktop/test/agent_composer_keys_test.dart` | `Up skips a host-refused prompt` | green |
| Agent composers support keyboard editing and submission | Recall does not cross conversations or restore history | `packages/desktop/test/agent_composer_keys_test.dart` | `Up does not reuse another conversation or restored history` | green |
| Agent composers support keyboard editing and submission | Navigate a nonempty composer | `packages/desktop/test/agent_composer_keys_test.dart` | `Up uses native caret movement when the draft is nonempty` | green |

## 1. Composer keys

- [x] 1.1 Check the desktop input path for A1 and A2 in the pinned Flutter SDK before implementing it. Confirm how the Windows engine filters IME-processed keys and handles unclaimed Enter, and how GTK and AppKit receive an unclaimed key. Cover active composition and follow-up Enter in the widget test; leave actual Windows candidate confirmation to 2.1. Linux and macOS native IME behavior remains unobserved.
- [x] 1.2 Add the test map cases and run the focused Windows-targeted widget file before production edits. Observe failures for the missing shortcuts. Pair the no-op and editing assertions with working submission or recall; refuse B through the fake host RPC, not local validation.
- [x] 1.3 Implement D1 and D2 in the shared composer and session link. Verify all test map cases, including focus, exact prompt text, held Enter, and one submission through the existing host call. Confirm Windows-targeted widget coverage exercises the shared composer for Claude Code, Codex, and OMP.
- [x] 1.4 Carry C1 and C2 in the `agent-sessions` delta and link the M2-F1 roadmap entry to this change and issue #11. Do not count the item as done before its archive reaches main. Run `openspec validate agent-chat-composer-keys --strict` and record the widget results in the map.

SDK evidence for 1.1: Flutter 3.47.9 (`mise.toml:5`). Windows `keyboard_key_embedder_handler.cc:177-184` claims `VK_PROCESSKEY` before the framework; `flutter_windows_view.cc:599-617` calls the text plugin on unhandled keys; `text_input_plugin.cc:86-104,483-502` adds a newline for an unhandled multiline Enter. Linux `fl_text_input_handler.cc:499-539` filters through GTK before the newline fallback. macOS `FlutterTextInputPlugin.mm:647-675` calls AppKit text input. This is source evidence, not native candidate confirmation.

Widget verification for 1.2 and 1.3: Enter, Shift+Enter, recall, and the Windows composing-Enter claim failed before the application edits. Afterward, all 181 tests passed in the composer, agent, Codex, OMP, draft, and launcher-link test files.

## 2. Native Windows IME verification

- [x] 2.1 [user] On the Windows release build for this PR, verify A1 with Microsoft Japanese IME and Microsoft Pinyin. Confirm a candidate with Enter and observe no send and no line break. Press Enter again and observe one send. Record both IMEs, the Windows build, the tested commit, and each outcome before archive.

The owner tested the [Windows CI release artifact](https://github.com/sh1ny/kumiko/actions/runs/45815090122/artifacts/15117230855) at `076fe312b0de69058e604ecc42b11355f5fe17dc` on their own PC. Windows 11 Pro 26H2, build 26300.9974, was read from the registry. The owner authorized recording their result and ticking this task (Ormy item 83, event `e2539`).

| Input method | Owner's result |
|---|---|
| Microsoft Japanese IME | Passed. Enter confirmed the candidate without sending; a second Enter sent once. |
| Microsoft Pinyin | Passed. Enter confirmed the candidate without sending; a second Enter sent once. |

## Workflow follow-up

- Run the independent pre-ship review, open the PR for issue #11, and watch CI and reviews.
- After the native IME check and review, archive on the PR branch and wait for the archive head's checks. Do not merge.
