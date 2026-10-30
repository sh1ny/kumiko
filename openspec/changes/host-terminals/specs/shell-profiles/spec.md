# Spec Delta

## Purpose

Describe how terminal shells are launched: host-owned argv profiles, detected for installed shells or defined by the user, with one default and no silent substitution.

## ADDED Requirements

### Requirement: A shell profile is an argv launch description
A shell profile SHALL hold a name, an executable path, an argument list, an optional working directory and environment overrides. The argument list SHALL be a list of separate arguments, never a single command string assembled for a shell to parse.

#### Scenario: Save a profile with arguments
- **WHEN** the user saves a profile with executable `/usr/bin/fish` and arguments `--login` and `--private`
- **THEN** the stored profile holds those two arguments as separate list entries

#### Scenario: Profile with an empty executable
- **WHEN** the user tries to save a profile with an empty executable path
- **THEN** the save is refused with a message that the executable is required, and no profile is stored

### Requirement: Installed shells are detected as built-in profiles
The host SHALL detect installed shells it knows, at least PowerShell (Windows PowerShell and pwsh), Nushell, bash, zsh and fish, and offer each found one as a built-in profile. A shell that is not installed SHALL NOT be offered.

#### Scenario: Windows with pwsh and Nushell installed
- **WHEN** the host starts on Windows where Windows PowerShell, pwsh and `nu` are installed
- **THEN** the profile list includes built-in profiles for Windows PowerShell, pwsh and Nushell, each with its resolved executable path

#### Scenario: fish is not installed
- **WHEN** the host starts on macOS where fish is not installed
- **THEN** no fish profile is offered, and zsh is offered if installed

#### Scenario: A detected shell is removed later
- **WHEN** a shell detected at an earlier start is uninstalled before the next host start
- **THEN** its built-in profile is no longer offered after that start

### Requirement: The user can define, edit and remove their own profiles
The user SHALL be able to add, edit and remove their own shell profiles, including shells the host does not detect. User profiles SHALL be stored by the host in the local store and survive restarts. Built-in profiles SHALL NOT be editable or removable, but can be copied into a user profile.

#### Scenario: Add a profile for an unknown shell
- **WHEN** the user adds a profile for `C:\tools\elvish.exe` with no arguments
- **THEN** the profile is listed after a restart, and a terminal opened with it runs elvish as a basic terminal

#### Scenario: Edit a profile while a terminal uses it
- **WHEN** the user edits a profile's arguments while a terminal opened from it is running
- **THEN** the running terminal is unchanged, and terminals opened afterwards use the new arguments

#### Scenario: Try to edit a built-in profile
- **WHEN** the user tries to edit a detected built-in profile
- **THEN** the edit is refused, and the user is offered a copy as a new user profile

#### Scenario: Store write fails
- **WHEN** saving a user profile fails because the store cannot be written
- **THEN** the failure is shown, and the profile list is unchanged

### Requirement: One profile is the default
Exactly one available profile SHALL be the default used by the Terminal launcher, **New terminal** and pane splits. On first launch the default SHALL be the platform's preferred detected shell. When the default profile becomes unavailable, the launcher and the split actions SHALL say so and ask the user to pick another, without substituting one silently.

#### Scenario: First launch on Windows
- **WHEN** Kumiko starts for the first time on Windows with pwsh and Windows PowerShell detected
- **THEN** pwsh is the default profile

#### Scenario: Choose a new default
- **WHEN** the user sets their Nushell profile as the default
- **THEN** the Terminal launcher opens Nushell, also after a restart

#### Scenario: Default profile removed
- **WHEN** the user removes the profile that is the default
- **THEN** the next Terminal launch asks the user to choose a profile, naming the removed default, and no shell starts until they choose

#### Scenario: No shell is detected
- **WHEN** no known shell is detected and the user has defined no profile
- **THEN** the Terminal launcher says no shell profile is available and offers to add one, and no terminal starts

### Requirement: An unavailable executable is reported, never substituted
When a profile's executable cannot be found or started, the host SHALL report the failure with the profile name, the executable path and the operating-system reason, and SHALL NOT start a different shell instead.

#### Scenario: Executable path is wrong
- **WHEN** the user opens a terminal from a profile whose executable path does not exist
- **THEN** the terminal shows that the executable was not found, with its path, and no other shell is started

#### Scenario: Executable is not runnable
- **WHEN** the profile's executable exists but the operating system refuses to start it
- **THEN** the terminal shows the operating-system error, and no other shell is started

### Requirement: Environment overrides apply only to the profile's terminals
A profile's environment overrides SHALL be applied on top of the host's environment for terminals started from that profile only, and SHALL NOT change the environment of the host, other terminals or other units.

#### Scenario: Set a variable in a profile
- **WHEN** a profile sets `EDITOR=hx` and the user opens terminals from that profile and from another profile
- **THEN** `EDITOR` is `hx` in the first terminal only

#### Scenario: Invalid variable name
- **WHEN** the user saves a profile with an environment override whose name is empty or contains `=`
- **THEN** the save is refused naming the invalid entry, and no profile is stored
