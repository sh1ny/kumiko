# Spec Delta

## ADDED Requirements

### Requirement: The host reports whether a terminal is busy
On request the host SHALL report each named terminal as busy, idle, ended or unknown. Busy SHALL mean its unit holds a live process besides its shell, or its leader runs an image other than the profile's resolved executable (after `exec`); idle that it holds only the shell. Missing evidence or a read past the activity deadline SHALL give unknown. Busy reports carry up to three program image names, never arguments. Source: D7, user decision 2026-11-02.

#### Scenario: Shell at its prompt
- **WHEN** a terminal's shell waits at its prompt with no child process
- **THEN** the host reports it idle with no program names

#### Scenario: Program running
- **WHEN** a terminal's shell runs vim in the foreground
- **THEN** the host reports it busy with the program name `vim` (`vim.exe` on Windows)

#### Scenario: Background job
- **WHEN** a terminal's shell started `sleep 600 &` and waits at its prompt
- **THEN** the host reports it busy with the program name `sleep`

#### Scenario: Shell replaced by exec
- **WHEN** the user runs `exec vim` in a terminal on Linux or macOS, so vim keeps the shell's process id
- **THEN** the host reports it busy with the program name `vim`, and closing its pane or quitting warns about it

#### Scenario: Startup file runs exec
- **WHEN** a bash profile's startup file runs `exec vim` before the host reads the leader's image
- **THEN** the host reports the terminal busy with `vim`, because the leader's image is not the profile's resolved executable

#### Scenario: Leader image unreadable
- **WHEN** the host cannot read the image of a terminal's leader process
- **THEN** it reports that terminal unknown

#### Scenario: Process table cannot be read in time
- **WHEN** the activity read for a terminal does not finish within the activity deadline
- **THEN** the host reports that terminal unknown, and other terminals in the same request are still reported

#### Scenario: Unknown terminal id
- **WHEN** the request names a terminal id the host does not hold
- **THEN** that id is reported ended, and the other ids are still reported

## MODIFIED Requirements

### Requirement: Closing live terminals warns about process loss
Closing a pane or a tab that holds busy terminals, or terminals whose activity is unknown, SHALL first warn that their running processes will end, naming every such terminal and its reported programs. Cancel SHALL keep them running, apart from a shell that exits on its own meanwhile; confirm SHALL end the terminals still alive. Idle and ended terminals close without a warning, and their shells end. Moving SHALL NOT warn or end any process. Source: D7, user decision 2026-11-02.

#### Scenario: Close a terminal running vim
- **WHEN** the user closes a terminal pane running vim and confirms the warning
- **THEN** the warning named `vim`, the shell and vim are terminated, the pane is removed and its sibling takes its space, and nothing keeps running invisibly

#### Scenario: Close a terminal at its prompt
- **WHEN** the user closes a terminal pane whose shell waits at its prompt with no child process
- **THEN** no warning is shown, the shell is terminated, and the pane is removed

#### Scenario: Cancel the warning
- **WHEN** the user closes a terminal pane running a program and chooses Cancel, and the shell does not exit while the warning is open
- **THEN** the pane, its place in the split, its shell and the running program remain intact, with no input or output lost

#### Scenario: Close a tab with several terminal panes
- **WHEN** the user closes a tab whose panes hold three terminals running programs, one terminal at its prompt and one whose shell has ended
- **THEN** one warning names the three busy terminals, and confirming terminates all four live shells and closes the tab

#### Scenario: Activity unknown
- **WHEN** the user closes a terminal pane and the host reports its activity unknown
- **THEN** the warning names the terminal as *may be running programs*, and nothing is ended until the user confirms

#### Scenario: Move a live terminal
- **WHEN** the user moves a pane whose terminal runs vim to a new tab, then moves that tab into a split of another tab
- **THEN** no warning is shown, and vim keeps running with the same shell, scrollback and binding

#### Scenario: A shell exits cleanly while the warning is open
- **WHEN** the warning for two busy terminals is open and one shell exits with status 0 and complete output
- **THEN** that pane closes at once, and confirming closes only the other terminal while cancelling leaves it running

#### Scenario: A shell ends otherwise while the warning is open
- **WHEN** the warning is open and a shell ends with a non-zero status
- **THEN** that pane stays, ended, and confirming removes it without sending another close

#### Scenario: Close an ended terminal
- **WHEN** the user closes a terminal pane whose shell has already exited
- **THEN** the pane closes without a warning

#### Scenario: Close a terminal that is still starting
- **WHEN** the user closes a terminal pane before its shell launch has finished
- **THEN** no warning is shown, the pane is removed, and when the launch completes its shell is terminated at once, with no process left running

#### Scenario: Program ignores termination
- **WHEN** the user confirms closing a terminal whose program ignores SIGTERM
- **THEN** the pane shows *Closing…*, the process tree is terminated and its cleanup confirmed within the overall settlement deadline and the pane is removed, or the pane stays with an error and its workspace shows *cleanup unresolved*
