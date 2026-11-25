## MODIFIED Requirements

### Requirement: Stopping a unit confirms its processes are gone
When the host ends a unit, it SHALL terminate its containment. On POSIX it SHALL also terminate every process of the current user that carries the unit's marker. The unit is *cleaned* only when termination is confirmed and no marked process remains. Otherwise it is *unresolved*. When the kernel refuses a signal to the unit's leader, failing it for any reason other than that no such process exists, the host SHALL count it as a failed kill unless it then confirms that the leader has exited, or that the leader's pid now belongs to another process. When the leader has no process group to signal, the host SHALL signal the leader's pid directly, as the unit's leader, only for a unit it started in its current run and only after confirming that the pid still belongs to the leader; a unit recorded by an earlier host is never signalled by its pid alone; a confirmed exit removes the kill failure, not the checks that decide whether the unit is cleaned. A process in the marker scan's population that the scan cannot read SHALL prevent a clean result unless the kernel confirms its full exit, or the reuse of its pid: on the first pass, before the scan lists the processes again; on the final pass, when the scan checks that pid right after it fails to read it. By the owner's decision, on macOS a pid that the scan cannot read is taken as another user's, and so outside the population, when the current user's process listing lacks it and a full listing made right after holds it, even though a process of the current user may have reaped and reused that pid between the two listings. By the owner's decision, a descendant started by a process after the scan's final listing, when that process vanishes before the scan reads it, is outside what the scan verifies and is left to OS-provided process grouping.

#### Scenario: Unit with an escaped descendant is ended
- **WHEN** the host ends a test unit whose descendant left the unit's POSIX session
- **THEN** the descendant is terminated through the marker scan and the unit is cleaned

#### Scenario: A process exits during the marker scan
- **WHEN** a process in the scan population cannot be read on the first pass, and the kernel confirms that it has fully exited (no thread of it remains) or that its pid now belongs to another process, at the recheck or while the scan settles and before it lists the processes again
- **THEN** that process contributes no failure, and the unit is cleaned only if its termination is confirmed, no marked process remains, and no other process is left unreadable

#### Scenario: A process exits while the process table is listed
- **WHEN** a process exits while the host lists the current processes for the marker scan, so that its entry vanishes during the listing, and a later attempt of the bounded listing completes
- **THEN** the scan uses that listing and does not fail for that reason

#### Scenario: The process table cannot be listed
- **WHEN** every attempt of the bounded listing fails because entries vanish, or the listing fails for any other reason
- **THEN** the marker scan fails because the process table could not be listed, and the unit is not cleaned

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
- **WHEN** the host stops a unit recorded by an earlier host, its first check finds the leader alive with the recorded start time, and the signal to the unit's process group answers that no such group exists
- **THEN** the host does not signal the leader's pid directly as the unit's leader (a marked process holding that pid is left to the marker scan), and counts a failed kill unless it confirms that the leader has exited or that its pid belongs to another process

#### Scenario: A live process cannot be inspected
- **WHEN** a process in the scan population cannot be read, and the kernel has not confirmed its full exit or the reuse of its pid before the scan lists the processes again (or, on the second pass, when it is read)
- **THEN** the unit is not cleaned, even if the process disappears later in the scan, and the marker scan's reason names that process unless a reason that takes precedence in the scan (the process table could not be listed, or the scan timed out) is reported instead

#### Scenario: A marked process survives
- **WHEN** a marked process cannot be terminated (the kill fails, or it is still alive after the termination timeout)
- **THEN** the unit is unresolved with that reason, and its target workspace is *cleanup unresolved*

#### Scenario: A refused signal whose leader is not confirmed gone
- **WHEN** the kernel refuses the signal to the unit's leader, and the host cannot then confirm that the leader has exited or that its pid belongs to another process
- **THEN** the unit is not cleaned: it is recorded unresolved with a kill-failed reason and its target workspace is *cleanup unresolved*, unless the host is shutting down, when a unit not yet recorded unresolved is left for the next host to reconcile
