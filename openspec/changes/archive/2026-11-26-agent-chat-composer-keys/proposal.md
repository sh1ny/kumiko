# Proposal

## Why

Sending every prompt by mouse slows down daily agent work on Windows. This change delivers M2-F1 and advances M2's Windows daily-driver exit criterion, which the owner will walk at milestone close because using the shortcuts in a widget test does not prove an ordinary development task on the release build.

## What Changes

- Enter submits the draft in the shared Codex, Claude Code, and OMP composer when Send allows it. It does nothing for a blank draft or while Send is disabled. Enter that confirms an IME candidate does not send.
- Shift+Enter inserts a line break. Up recalls the most recent accepted prompt in this open conversation only when the composer is empty. With text present, Up keeps its normal caret behavior.
- Leave saved history, native runtime behavior, and the `omp-rpc-history-and-children` change separate.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `agent-sessions`: Add keyboard editing and submission to the shared chat composer.

## Impact

Flutter desktop agent composer, its session link, and widget tests. No host, protocol, dependency, or persistence changes.

## Decision Making

DECISION_MAKING: autonomous
Source: setting

### S1. Keyboard behavior belongs in the shared composer

- Choice: Ship the three shortcuts together for all agent runtimes. During a reply, Enter behaves like the disabled Send control.
- Rejected: Special-case a runtime or use Enter to queue or steer. Either changes the meaning of Send across chats.
- Reversal cost: low.
- Important: yes. Changes behavior users see.
- Chosen by: user.

### S2. Recall is limited to the open conversation

- Choice: Recall the last accepted prompt from this open conversation only, with no recall after close or restart.
- Rejected: Consult restored conversation history. That would couple the shortcuts to adapter-specific history support and the next OMP change.
- Reversal cost: low.
- Important: yes. Sets the user-visible boundary for recall.
- Chosen by: user. "Only this open conversation."
