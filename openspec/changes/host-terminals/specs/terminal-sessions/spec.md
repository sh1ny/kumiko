# Spec Delta

## Purpose

Provide interactive terminals that run the user's chosen shell in a host-owned pseudo-terminal, render in the desktop, warn before process loss, and reopen as layout only.

## ADDED Requirements

### Requirement: A terminal runs its profile's shell in a host-owned pseudo-terminal
Opening a terminal SHALL make the execution host start the selected shell profile's executable with exactly its argument list, working directory and environment overrides, attached to a pseudo-terminal the host owns. The desktop SHALL NOT own the shell process or its pseudo-terminal (ADR 0006).

#### Scenario: Open a Nushell terminal on Windows
- **WHEN** the user opens a terminal with a Nushell profile whose executable is installed
- **THEN** the host starts that executable with the profile's arguments in the profile's working directory under a pseudo-terminal, and the terminal shows the Nushell prompt

#### Scenario: Arguments are passed as a list
- **WHEN** a profile's argument list contains an argument with spaces and quote characters
- **THEN** the shell receives that argument as one unchanged argument, not split or re-quoted

#### Scenario: Profile executable is missing at launch
- **WHEN** the user opens a terminal whose profile executable no longer exists
- **THEN** the terminal reports that the executable was not found, naming its path, and no other shell is started in its place

### Requirement: A terminal in a workspace starts in that workspace
A terminal opened from a group bound to a workspace SHALL start in that workspace's directory unless its profile sets a working directory. A terminal opened in Personal with no workspace SHALL start in the user's home directory unless its profile sets one.

#### Scenario: Open a terminal in a checkout
- **WHEN** the user opens a terminal from a group bound to the workspace `C:\src\kumiko` with a profile that sets no working directory
- **THEN** the shell's working directory is `C:\src\kumiko`

#### Scenario: Open a terminal in Personal
- **WHEN** the user opens a terminal from a Personal group with no workspace on first launch
- **THEN** the shell starts in the user's home directory, with no project, server or network prompt

#### Scenario: Workspace is unavailable
- **WHEN** the user opens a terminal for a workspace shown as *unavailable*
- **THEN** the launch is refused with the reason that the workspace directory is unavailable, and no shell is started

### Requirement: Terminal launch follows the host's unit limits
Each terminal's shell process tree SHALL be a contained unit of the host, counted against the host unit cap and refused while its workspace is under *cleanup unresolved*, with the refusal shown to the user.

#### Scenario: Unit cap reached
- **WHEN** the user opens a terminal while the host already runs its maximum number of units
- **THEN** the launch is refused with the reason `unit-cap` shown in the terminal tab, and no shell is started

#### Scenario: Workspace cleanup unresolved
- **WHEN** the user opens a terminal in a workspace under *cleanup unresolved*
- **THEN** the launch is refused naming that state, and the workspace's existing state is unchanged

### Requirement: Terminal processes end with the terminal, the desktop or the host
A terminal's shell and every process it started SHALL be terminated when the terminal is closed with confirmation, when the desktop exits or dies, or when the host exits. After an abrupt host death the next host SHALL clean them or mark the workspace *cleanup unresolved* (ADR 0001).

#### Scenario: Desktop is killed with terminals open
- **WHEN** the desktop process is killed while two terminals run vim and a shell
- **THEN** no shell, vim or other process from those terminals remains running

#### Scenario: Host dies abruptly
- **WHEN** the host is killed while a terminal runs a long-lived child process, and the desktop starts a new host
- **THEN** the new host ends that process tree, or marks the terminal's workspace *cleanup unresolved* and refuses new launches there

### Requirement: Terminal I/O is relayed as raw bytes
The host SHALL relay pseudo-terminal output to the desktop and desktop input to the pseudo-terminal as unmodified bytes, without interpreting terminal sequences. Emulation, rendering and scrollback SHALL happen in the desktop.

#### Scenario: Binary-safe output
- **WHEN** a program writes bytes that include escape sequences, invalid UTF-8 and NUL bytes
- **THEN** the desktop receives exactly those bytes in order from the host, unmodified, before they reach the emulator

#### Scenario: Output arrives faster than the desktop reads
- **WHEN** a terminal runs `cat` on a 100 MB file and the desktop consumes slower than the program writes
- **THEN** the host stops reading that pseudo-terminal until the desktop grants more credit, host memory for that terminal stays within its stated buffer bound, and no output bytes are dropped

### Requirement: Terminal size follows the view
The desktop SHALL report the terminal view's size in columns and rows, and the host SHALL apply it to the pseudo-terminal so the running program sees the new size.

#### Scenario: Resize a running TUI
- **WHEN** the user resizes a split containing a terminal running htop
- **THEN** htop redraws at the new column and row count

#### Scenario: Resize storm
- **WHEN** the view is resized many times within one second while a TUI runs
- **THEN** the pseudo-terminal ends at the final view size, and the shell and TUI remain responsive

### Requirement: Shell exit is shown, not hidden
When a terminal's shell exits on its own, the terminal SHALL stay open showing that the shell ended and its exit status, and SHALL NOT start a new shell automatically.

#### Scenario: User types exit
- **WHEN** the user types `exit` in a bash terminal
- **THEN** the terminal shows that the shell ended with exit status 0 and offers **Start shell**, and no new shell runs until the user chooses it

#### Scenario: Shell crashes
- **WHEN** the shell process is killed by a signal or an external tool
- **THEN** the terminal shows that the shell ended with the observed status, and the earlier output stays visible

#### Scenario: Final output before exit
- **WHEN** a program prints an error message as its last output and the shell exits immediately
- **THEN** the error message is shown in the terminal before the ended state, or the terminal states that output may be incomplete

### Requirement: The adopted terminal engine meets the daily-driver bar
The terminal SHALL use an engine adopted only when, on every OS, each daily-driver bar item is recorded as pass, or (a user-verified item on Linux or macOS only) as unproven. An engine that fails any item SHALL NOT be adopted (ADR 0006). An unproven item SHALL stay listed and SHALL NOT count as passed.

#### Scenario: Fullscreen TUIs and input
- **WHEN** the user runs vim, lazygit, htop or btop, and tmux in the terminal on each OS
- **THEN** each renders correctly and receives keyboard input with modifiers, function and navigation keys, and mouse reporting

#### Scenario: Colour, Unicode and IME
- **WHEN** 256-colour and 24-bit colour test output, wide characters and emoji are printed, and CJK text is entered through an IME
- **THEN** colours render as specified, wide characters and emoji take their correct widths, and the IME commits exactly the composed text

#### Scenario: Paste, selection and search
- **WHEN** the user pastes multi-line text into a shell with bracketed paste enabled, then selects, copies and searches scrollback
- **THEN** the paste arrives as one bracketed paste without executing line by line, and the copied and found text match the screen

#### Scenario: Throughput and interrupt
- **WHEN** `cat` of a 100 MB file runs and the user presses Ctrl+C
- **THEN** the UI keeps responding to input during the output, and the program is interrupted promptly

#### Scenario: Conformance subset
- **WHEN** the named vttest subset (cursor movement, screen features, character sets) runs
- **THEN** every item in the subset passes

#### Scenario: A candidate fails an item
- **WHEN** a candidate engine fails any bar item on any OS
- **THEN** that engine is not adopted, the failure is recorded with the OS and item, and if every candidate failed the change escalates to the user before any engine is adopted

#### Scenario: User-verified items not yet run on Linux or macOS
- **WHEN** the user has not yet run the interactive bar items on Linux or macOS
- **THEN** those items are recorded as unproven, the engine can be adopted provisionally, and the results check lists every unproven item by OS and item

### Requirement: Terminals are distinct from agent tool shells
A human terminal SHALL be its own host-owned process, separate from any agent's tool shell or structured agent connection. Choosing a shell profile for terminals SHALL NOT change the shell agents use to run commands.

#### Scenario: Change the default terminal profile
- **WHEN** the user changes their default terminal profile from PowerShell to Nushell
- **THEN** new terminals use Nushell, and no agent tool-shell setting changes

#### Scenario: No agent session exists
- **WHEN** the user opens a terminal while no agent session is running or configured
- **THEN** the terminal opens and works without any agent adapter

### Requirement: Coding-agent CLIs run in a terminal without an adapter
The user SHALL be able to run an installed coding-agent CLI such as Claude Code, Codex or OMP in a terminal as ordinary terminal work, with no project, repository, team account or Chat UI adapter, and with the left sidebar visible or collapsed.

#### Scenario: Run Claude Code in a Personal terminal
- **WHEN** a user with no project or workspace starts `claude` in a Personal terminal
- **THEN** the CLI runs with normal input and output in the terminal, and no adapter or mode change is required

#### Scenario: The CLI is not installed
- **WHEN** the user types the name of a CLI that is not installed
- **THEN** the shell's own not-found error is shown in the terminal, and the terminal stays usable

### Requirement: Closing live terminals warns about process loss
Closing a tab, tab group or split that holds terminals whose shell is alive SHALL first warn that their running processes will end, naming every affected terminal. Cancel SHALL keep them open and running; confirm SHALL terminate their process trees and close the views. Terminals whose shell has ended close without a warning.

#### Scenario: Close a terminal running vim
- **WHEN** the user closes a terminal tab running vim and confirms the warning
- **THEN** the shell and vim are terminated and the tab is removed, and nothing keeps running invisibly

#### Scenario: Cancel the warning
- **WHEN** the user closes a terminal tab with a live shell and chooses Cancel
- **THEN** the tab, its shell and any running program remain intact, with no input or output lost

#### Scenario: Close a group with several terminals
- **WHEN** the user closes a tab group holding three terminals with live shells and one whose shell has ended
- **THEN** one warning names the three live terminals, and confirming terminates all three and closes the group

#### Scenario: Close an ended terminal
- **WHEN** the user closes a terminal tab whose shell has already exited
- **THEN** the tab closes without a warning

#### Scenario: Close a terminal that is still starting
- **WHEN** the user closes a terminal tab and confirms before its shell launch has finished
- **THEN** the tab is removed, and when the launch completes its shell is terminated at once, with no process left running

#### Scenario: Program ignores termination
- **WHEN** the user confirms closing a terminal whose program ignores SIGTERM
- **THEN** the tab shows *Closing…*, the process tree is terminated and its cleanup confirmed within the overall settlement deadline and the tab is removed, or the tab stays with an error and its workspace shows *cleanup unresolved*

### Requirement: Reopen restores terminal arrangement, not processes
Quit and reopen SHALL restore each terminal tab in its group and position, shown as *ended, not restored* with its profile name and a **Start shell** action. Reopen SHALL NOT start a shell, re-run an earlier program or command, or claim that one is running or resumed.

#### Scenario: Reopen a four-pane terminal arrangement
- **WHEN** the user quits with four terminal panes running vim and lazygit, then reopens Kumiko
- **THEN** the four panes are restored in place, each shown as *ended, not restored*, and no shell, vim or lazygit process is started

#### Scenario: Start a shell in a restored pane
- **WHEN** the user chooses **Start shell** in a restored terminal pane
- **THEN** a new shell starts from that pane's profile in its workspace, with empty scrollback and no earlier command replayed

#### Scenario: Restored profile was deleted
- **WHEN** a restored terminal pane refers to a profile the user has since removed
- **THEN** the pane shows that its profile no longer exists, **Start shell** offers the default profile instead, and nothing starts until the user chooses it
