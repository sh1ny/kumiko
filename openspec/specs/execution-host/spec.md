# execution-host Specification

## Purpose

Run all of Kumiko's execution in one headless child host per user profile, launched by the desktop and ended with it, so a UI crash never leaves work running unseen and two instances never own the same profile (ADR 0001, D1, D7).

## Requirements

### Requirement: Desktop launches its bundled host
On startup the desktop SHALL launch the execution host bundled with it as a direct child process and connect to it over the host's stdio. Until the handshake completes the desktop SHALL show the host as starting. It SHALL offer no action that needs the host.

#### Scenario: Normal launch
- **WHEN** the user starts Kumiko and no other instance holds the profile
- **THEN** exactly one host process is a child of the desktop, the handshake completes, and the desktop shows the host as connected with the negotiated protocol version

#### Scenario: Bundled host missing or not executable
- **WHEN** the desktop starts and the bundled host executable is absent or fails to start
- **THEN** the desktop shows a host start error naming the expected host path, and no execution action is offered

#### Scenario: Host does not answer the handshake
- **WHEN** the host process starts but sends no handshake reply within the handshake timeout
- **THEN** the desktop terminates that host, shows a host start error stating the timeout, and offers Restart host

### Requirement: One host owns a user profile
A host SHALL take an exclusive OS-level lock on the per-user profile directory before it opens the store or launches anything. A host that cannot take the lock SHALL open no store and launch nothing. It SHALL report the profile as in use and exit.

#### Scenario: Two simultaneous launches
- **WHEN** two desktops are started at the same moment against the same profile
- **THEN** exactly one host holds the lock and completes the handshake, and the other host reports the profile in use and exits without opening the store or starting any unit

#### Scenario: Lock released by a crashed owner
- **WHEN** the host holding the lock is killed and Kumiko is launched again
- **THEN** the new host takes the lock, without any manual removal of a lock file, and completes the handshake

### Requirement: A second launch reports the running instance and exits
A desktop whose host reports the profile in use SHALL show that Kumiko is already running and exit when the user dismisses it. It SHALL write nothing to the profile, including diagnostic logs.

#### Scenario: Launch while Kumiko runs
- **WHEN** the user starts Kumiko while another instance holds the profile
- **THEN** the new window shows "Kumiko is already running", and after dismissal the new desktop and its host have exited while the first instance keeps running unchanged

#### Scenario: Second launch leaves the profile untouched
- **WHEN** a launch is refused because the profile lock is held by a quiescent holder that writes nothing to the profile
- **THEN** every file in the profile directory is byte-identical to before that launch, and no file was created or deleted

### Requirement: Host lifetime is tied to the desktop
When its connection to the desktop closes for any reason, the host SHALL terminate every unit it started and then exit within the shutdown deadline. Units not confirmed cleaned by then SHALL stay in the ledger for the next host to reconcile. The host SHALL never keep work running for later reattachment.

#### Scenario: Desktop quits normally
- **WHEN** the desktop closes its connection to a host running test units
- **THEN** every unit's processes have ended, their ledger entries are cleaned, and the host process has exited

#### Scenario: Desktop is killed
- **WHEN** the desktop process is killed while its host runs test units whose processes can all be terminated
- **THEN** no host process and no process carrying a recorded unit marker remains afterwards

#### Scenario: A unit survives past the shutdown deadline
- **WHEN** the desktop connection closes and a marked process of a test unit cannot be terminated before the shutdown deadline (an injected kill failure)
- **THEN** the host exits at the deadline and the unit's ledger entry remains. The next host reconciles it: the workspace is listed as *cleanup unresolved* only if the process still cannot be confirmed gone, and the unit is cleaned otherwise

### Requirement: Losing the host is visible
When the host exits or its connection closes while the desktop runs, the desktop SHALL show *host lost* and mark everything the host ran as stopped or unknown, never running. It SHALL offer Restart host. A restarted host reconciles before it launches anything.

#### Scenario: Host killed while the desktop runs
- **WHEN** the host process is killed while the desktop runs
- **THEN** the desktop shows *host lost* within the host-loss detection bound and offers Restart host, and no unit is shown as running

#### Scenario: Restart after host loss
- **WHEN** the user chooses Restart host after a host loss
- **THEN** a new host takes the lock, reports reconciliation in progress, and refuses unit launches until reconciliation has finished
