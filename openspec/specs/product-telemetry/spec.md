# product-telemetry Specification

## Purpose

Keep Kumiko free of client product telemetry and crash or error reporting by construction: no shipped dependency may carry analytics, crash-report or remote-logging capability (D25, D46).

## Requirements

### Requirement: Shipped dependencies exclude telemetry and reporting packages
The resolved dependencies of every shipped package SHALL contain no product-analytics, crash-report or remote-logging package. CI SHALL fail when one is added. This carries the dependency part of the backlog's "Telemetry-free builds exclude the capability" and "Client product telemetry and reports are not gathered" (D25).

#### Scenario: Clean dependency set
- **WHEN** CI runs the dependency audit on main
- **THEN** the audit passes and lists every resolved package it checked

#### Scenario: A reporting package is added
- **WHEN** a change adds a crash-report, analytics or remote-logging package directly or transitively
- **THEN** the audit fails naming the package and the shipped package that pulls it in, and CI fails

#### Scenario: Audit cannot read the resolved dependencies
- **WHEN** a lock file is missing or unreadable during the audit
- **THEN** the audit fails stating which lock file it could not read, rather than passing
