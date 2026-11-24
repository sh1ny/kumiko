## MODIFIED Requirements

### Requirement: Stopping a unit confirms its processes are gone
When the host ends a unit, it SHALL terminate its containment. On POSIX it SHALL also terminate every process of the current user that carries the unit's marker. The unit is *cleaned* only when termination is confirmed and no marked process remains. Otherwise it is *unresolved*. When the kernel refuses a signal to the unit's leader, failing it for any reason other than that no such process exists, the host SHALL count it as a failed kill unless it then confirms that the leader has exited, or that the leader's pid now belongs to another process. When the leader has no process group to signal, the host SHALL signal the leader's pid directly, as the unit's leader, only for a unit it started in its current run and only after confirming that the pid still belongs to the leader; a unit recorded by an earlier host is never signalled by its pid alone; a confirmed exit removes the kill failure, not the checks that decide whether the unit is cleaned.

#### Scenario: Unit with an escaped descendant is ended
- **WHEN** the host ends a test unit whose descendant left the unit's POSIX session
- **THEN** the descendant is terminated through the marker scan and the unit is cleaned

#### Scenario: A process exits during the marker scan
- **WHEN** a process in the scan population exits, or its pid is reused, between being listed and having its environment read
- **THEN** the scan counts it as gone, and the unit is cleaned if no marked process remains

#### Scenario: The leader exits while it is being stopped
- **WHEN** the unit's leader exits after the host found it running, the kernel refuses the signal to its group, and the host then confirms that the leader has exited
- **THEN** the host records no kill failure for the leader, and the unit is cleaned only if its termination is then confirmed and the marker scan completes with no marked process left

#### Scenario: The leader's pid is not confirmed before a direct signal
- **WHEN** the unit's process group does not exist when the host signals it, and the host cannot confirm that the leader's pid still belongs to the leader
- **THEN** the host does not signal that pid as the unit's leader, and any marked process holding that pid is left to the marker scan

#### Scenario: The leader has no process group yet
- **WHEN** the host stops a unit it started in its current run, the unit's process group does not exist yet, and the host confirms that the leader's pid still belongs to the leader
- **THEN** the host signals the leader directly, and if that signal finds no such process, the host counts the leader as exited rather than as a failed kill

#### Scenario: A recorded unit's leader has no process group
- **WHEN** the host stops a unit recorded by an earlier host, and the unit's process group does not exist
- **THEN** the host does not signal the leader's pid directly as the unit's leader (a marked process holding that pid is left to the marker scan), and counts a failed kill unless it confirms that the leader has exited or that its pid belongs to another process

#### Scenario: A live process cannot be inspected
- **WHEN** a process in the scan population is still running with the same start time but its environment cannot be read
- **THEN** the unit is unresolved with a reason naming that process

#### Scenario: A marked process survives
- **WHEN** a marked process cannot be terminated (the kill fails, or it is still alive after the termination timeout)
- **THEN** the unit is unresolved with that reason, and its target workspace is *cleanup unresolved*

#### Scenario: A refused signal whose leader is not confirmed gone
- **WHEN** the kernel refuses the signal to the unit's leader, and the host cannot then confirm that the leader has exited or that its pid belongs to another process
- **THEN** the unit is not cleaned: it is recorded unresolved with a kill-failed reason and its target workspace is *cleanup unresolved*, unless the host is shutting down, when a unit not yet recorded unresolved is left for the next host to reconcile
