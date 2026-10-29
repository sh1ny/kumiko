# local-store Specification

## Purpose

Keep Kumiko's durable local state in a host-owned, versioned store that only the profile's lock holder opens or migrates, and that is never silently reset (ADR 0003, D7, D29).

## Requirements

### Requirement: Only the lock holder opens the store
The host SHALL open or migrate the store only while it holds the profile lock. The desktop SHALL never open the store; it reads and changes durable state only through the host.

#### Scenario: Store opened after the lock
- **WHEN** a host starts and takes the profile lock
- **THEN** it opens the store in the profile directory and completes the handshake

#### Scenario: Host without the lock
- **WHEN** a host fails to take the profile lock
- **THEN** it does not open the store file, create it, or create its journal files

### Requirement: Migrations are versioned and transactional
The store SHALL record its schema version. At startup the host SHALL apply each pending forward migration in a transaction. A failed migration SHALL leave the store at its previous version and stop startup with a visible error.

#### Scenario: Fresh profile
- **WHEN** a host starts on a profile with no store
- **THEN** it creates the store at the current schema version

#### Scenario: Migration fails
- **WHEN** a migration step fails during startup
- **THEN** the store's schema version and contents are unchanged, the handshake reports a store-migration error, and the desktop shows it and offers no execution action

### Requirement: A store is never reset or downgraded
The host SHALL never delete, recreate or truncate an existing store to recover from an error. A store whose schema version is newer than the host supports SHALL be refused unchanged.

#### Scenario: Store from a newer Kumiko
- **WHEN** a host starts on a store whose schema version is newer than it supports
- **THEN** it does not modify the file, the handshake reports the store as newer than supported with both versions, and the desktop shows that error

#### Scenario: Store file cannot be opened
- **WHEN** the store file exists but cannot be opened or read as a database
- **THEN** the file is left in place unchanged, and the desktop shows a store error naming its path
