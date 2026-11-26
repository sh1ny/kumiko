# Spec Delta

## ADDED Requirements

### Requirement: Agent composers support keyboard editing and submission

Claude Code, Codex, and OMP SHALL share composer shortcuts: unmodified Enter follows Send, Shift+Enter inserts a line break without sending, and Up recalls the last accepted prompt only into an empty composer. Enter that confirms an IME candidate SHALL NOT send. Recall SHALL edit the draft without sending or reading saved history. With text present, Up SHALL retain normal caret behavior. Source: M2-F1, issue #11, direction D7 and D29.

#### Scenario: Submit a nonblank draft with Enter
- **WHEN** the focused composer contains a nonblank draft, Send is available, and the user presses Enter outside IME composition
- **THEN** it submits the draft once through the Send path without adding a line break

#### Scenario: Enter on a blank draft or during a reply
- **WHEN** the user presses Enter and the draft is empty or whitespace-only, or a reply is streaming and Send is disabled
- **THEN** the draft remains unchanged and Kumiko does not send, queue, or steer a prompt

#### Scenario: Confirm an IME candidate
- **WHEN** Enter confirms an active IME composition in the composer
- **THEN** the IME can finish the composition without Kumiko sending the draft or inserting a line break

#### Scenario: Insert a line break with Shift+Enter
- **WHEN** the user presses Shift+Enter at a caret or over selected text outside IME composition
- **THEN** a line break replaces the selection, the caret follows it, and no prompt is sent

#### Scenario: Recall the last accepted prompt
- **WHEN** the user presses unmodified Up with an empty composer after sending prompts in this open conversation
- **THEN** the composer contains the most recent accepted prompt with the caret at its end, without sending it

#### Scenario: Recall skips a refused prompt
- **WHEN** prompt A was accepted in this conversation, a later prompt B was refused before dispatch, and the user empties the composer and presses Up
- **THEN** the composer contains A with the caret at its end, and nothing is sent

#### Scenario: Recall does not cross conversations or restore history
- **WHEN** the composer is empty and no prompt has been accepted in this open conversation, including after a pane is closed and reopened or Kumiko restarts with restored history
- **THEN** Up leaves the composer empty and sends nothing

#### Scenario: Navigate a nonempty composer
- **WHEN** the user presses Up from a lower line in a multiline draft
- **THEN** the caret moves to the previous line without replacing any draft text
