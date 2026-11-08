# Spec Delta

## ADDED Requirements

### Requirement: The host records whether the desktop quit
The host SHALL record, for its own instance, that the desktop quit only when the desktop announced a quit before closing the connection. Any other end (desktop killed, pipe broken, host killed or crashed) SHALL leave the instance recorded as not quit. Source: ADR 0001, D7.

#### Scenario: Normal quit
- **WHEN** the user quits Kumiko and the host exits
- **THEN** the host's instance row records a quit

#### Scenario: Desktop killed
- **WHEN** the desktop process is killed and the host ends every unit and exits
- **THEN** the host's instance row does not record a quit, even though every unit was cleaned

#### Scenario: Host killed
- **WHEN** the host process is killed
- **THEN** its instance row does not record a quit

### Requirement: An unexpected previous end is shown at the next launch
When the desktop's first host reports that the previous instance did not record a quit, the desktop SHALL show *Kumiko did not close normally last time* once reconciliation ends, with its outcome: every process cleaned, or the count of *cleanup unresolved* workspaces with *Show cleanup list*. It SHALL be dismissible, and SHALL NOT appear after a quit, on first launch, or after Restart host. Source: direction "Recovery preserves saved history without replay guarantees", D7.

#### Scenario: Reopen after the desktop was killed
- **WHEN** the desktop was killed while a terminal ran vim, and the user starts Kumiko again
- **THEN** after reconciliation the workbench shows *Kumiko did not close normally last time* stating that every process was cleaned, and the restored layout is shown with the terminal pane *ended, not restored*

#### Scenario: Reopen with unresolved cleanup
- **WHEN** the previous host was killed and one of its units cannot be confirmed gone on the next launch
- **THEN** the notice states that 1 workspace has *cleanup unresolved* and offers *Show cleanup list*, which opens that workspace's units

#### Scenario: Reopen after a normal quit
- **WHEN** the user quit Kumiko normally and starts it again
- **THEN** no previous-exit notice is shown

#### Scenario: First launch on a new profile
- **WHEN** Kumiko starts on a profile with no earlier host instance
- **THEN** no previous-exit notice is shown

#### Scenario: Restart host after a loss
- **WHEN** the host was lost while the desktop ran and the user chooses Restart host
- **THEN** no previous-exit notice is shown, and the cleanup outcome appears in the existing cleanup status

#### Scenario: Reconciliation removes the previous instance row
- **WHEN** the desktop was killed, reconciliation cleans every unit of that instance and removes its instance row, and an older instance still has an unresolved unit
- **THEN** the notice still reports the immediately previous instance as not quit, as captured before reconciliation, and not the older instance

#### Scenario: Previous exit cannot be read
- **WHEN** the host fails to read the previous instance's row
- **THEN** no notice is shown, the failure is written to the host diagnostic log, and startup continues
