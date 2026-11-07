# Spec Delta

## MODIFIED Requirements

### Requirement: Closing a pane or tab checks for live work
Closing a pane or a tab SHALL first show one confirmation naming every view in it that warns: running agent sessions (agent-sessions) and busy or unknown-activity terminals (terminal-sessions). Cancel SHALL leave the pane or tab and its arrangement unchanged, except a pane whose shell exits on its own meanwhile. When some closes of a confirmed tab close fail, the closes that succeeded SHALL stay done, each failed pane SHALL stay with its error, and the tab SHALL stay while any pane remains.

#### Scenario: Close a tab holding live terminals
- **WHEN** the user closes a tab whose panes hold two terminals running programs and a Workspace overview
- **THEN** one confirmation names both terminals, and on confirm the tab closes and the terminals' processes end

#### Scenario: Cancel closing a tab
- **WHEN** the user closes a tab with a busy terminal and cancels the confirmation, and no shell in it exits while the confirmation is open
- **THEN** the tab, its panes, their split arrangement and ratios are unchanged, and the terminal keeps running

#### Scenario: Close a pane holding a live terminal
- **WHEN** the user closes a pane whose terminal runs a program
- **THEN** a confirmation names that terminal, and on confirm the pane closes and its sibling takes its space

#### Scenario: Tab with no live work
- **WHEN** the user closes a tab whose panes hold a Workspace overview, an ended terminal and a terminal at its shell prompt
- **THEN** the tab closes without a confirmation, and the idle shell is terminated

#### Scenario: Part of a tab close fails
- **WHEN** the user confirms closing a tab holding a Workspace overview and two busy terminals, and the host cannot confirm the cleanup of one terminal
- **THEN** the overview and the other terminal close and their space goes to the remaining pane, the failed terminal pane stays with the same identity and its error, and the tab stays open
