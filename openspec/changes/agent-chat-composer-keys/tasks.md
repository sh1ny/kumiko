# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| Agent composers support keyboard editing and submission | Submit a nonblank draft with Enter | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter sends the draft once` | red |
| Agent composers support keyboard editing and submission | Enter on a blank draft or during a reply | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter leaves blank and streaming drafts untouched` | red |
| Agent composers support keyboard editing and submission | Confirm an IME candidate | `packages/desktop/test/agent_composer_keys_test.dart` | `Enter leaves IME confirmation to the input method` | red |
| Agent composers support keyboard editing and submission | Insert a line break with Shift+Enter | `packages/desktop/test/agent_composer_keys_test.dart` | `Shift+Enter replaces the selection with a line break` | red |
| Agent composers support keyboard editing and submission | Recall the last accepted prompt | `packages/desktop/test/agent_composer_keys_test.dart` | `Up recalls only the latest accepted prompt` | red |
| Agent composers support keyboard editing and submission | Recall skips a refused prompt | `packages/desktop/test/agent_composer_keys_test.dart` | `Up skips a host-refused prompt` | red |
| Agent composers support keyboard editing and submission | Recall does not cross conversations or restore history | `packages/desktop/test/agent_composer_keys_test.dart` | `Up does not reuse another conversation or restored history` | red |
| Agent composers support keyboard editing and submission | Navigate a nonempty composer | `packages/desktop/test/agent_composer_keys_test.dart` | `Up uses native caret movement when the draft is nonempty` | red |

## 1. Composer keys

- [ ] 1.1 Check the desktop input path for A1 in the pinned Flutter SDK before implementing it. Confirm how the Windows engine filters IME-processed keys and how Flutter propagates an unhandled key. Cover active composition and follow-up Enter in the widget test; leave actual candidate confirmation to 2.1.
- [ ] 1.2 Add the test map cases and run the focused Windows-targeted widget file before production edits. Observe failures for the missing shortcuts. Pair the no-op and editing assertions with working submission or recall; refuse B through the fake host RPC, not local validation.
- [ ] 1.3 Implement D1 and D2 in the shared composer and session link. Verify all test map cases, including focus, exact prompt text, held Enter, and one submission through the existing host call. Confirm Windows-targeted widget coverage exercises the shared composer for Claude Code, Codex, and OMP.
- [ ] 1.4 Carry C1 and C2 in the `agent-sessions` delta and link the M2-F1 roadmap entry to this change and issue #11. Do not count the item as done before its archive reaches main. Run `openspec validate agent-chat-composer-keys --strict` and record the widget results in the map.

## 2. Native Windows IME verification

- [ ] 2.1 [user] On the Windows release build for this PR, verify A1 with Microsoft Japanese IME and Microsoft Pinyin. Confirm a candidate with Enter and observe no send and no line break. Press Enter again and observe one send. Record both IMEs, the Windows build, the tested commit, and each outcome before archive.

## Workflow follow-up

- Run the independent pre-ship review, open the PR for issue #11, and watch CI and reviews.
- After the native IME check and review, archive on the PR branch and wait for the archive head's checks. Do not merge.
