## Purpose



Defines native Codex conversations in Kumiko, including safe control, recovery and attribution of delegated work while Codex owns execution and history.



## ADDED Requirements



### Requirement: Codex uses its native App Server connection

Codex sessions SHALL use the user's configured Codex App Server over private stdio, with no ACP intermediary or network listener. Each root session SHALL own its contained process tree. Native runtime configuration and sign-in SHALL remain user-owned. Source: owner decision 2026-11-10, amended direction D6 and D20.



#### Scenario: Start native Codex

- **WHEN** the user starts Codex with an available compatible profile in workspace A

- **THEN** one contained App Server starts in A, initialization completes before thread creation, and the desktop shows the saved native thread as Idle



#### Scenario: Initialization fails

- **WHEN** Codex exits, times out or returns malformed initialization data before thread creation

- **THEN** start fails visibly, no saved conversation is created, the per-run tool grant is revoked and containment is settled or reported unresolved



### Requirement: Codex capability claims name the native runtime version

The host SHALL associate claims with the exact Codex runtime version, protocol family and OS. Codex 0.166.0 or newer SHALL run without an exact-version allowlist. Features SHALL follow the implemented native contract and actual support, independently of recorded version evidence. Missing native support SHALL remain unavailable even when a version is listed. Source: ADR 0004 evidence rule as amended by this change.



#### Scenario: Qualified native recovery

- **WHEN** a supported Codex run implements the required native methods

- **THEN** it exposes Continue for that original native thread



#### Scenario: Unsupported recovery

- **WHEN** the runtime version is below the minimum or a required method is unsupported

- **THEN** Continue reports the version and reason, sends no prompt and leaves the saved record unchanged



### Requirement: Native turn acceptance and completion are distinct

The chat SHALL commit a user prompt only after bounded native admission. A successful turn-start response SHALL NOT mark a turn completed; native terminal events SHALL determine its outcome. Failed admission SHALL preserve composer text and create no user event. Duplicate native items SHALL NOT duplicate displayed content.



#### Scenario: Start acknowledgement precedes output

- **WHEN** turn start is acknowledged and reply events arrive later

- **THEN** the chat stays Running and appends the reply once in native order until the terminal turn event



#### Scenario: Native input is full

- **WHEN** the bounded native write queue cannot admit a prompt

- **THEN** Send is refused busy, the session remains Idle and the composer text is retained



#### Scenario: Native transport breaks after admission

- **WHEN** an admitted request's write fails even after a native response was received

- **THEN** the session becomes Failed and settles containment instead of returning to a usable Idle state



### Requirement: Codex approvals and questions require explicit answers

Codex command, file-change and permission approvals and structured questions SHALL identify their originating session and retain native choice semantics. Only an explicit user answer, Stop, close, native retirement or a visible capacity refusal SHALL resolve them; none SHALL grant approval automatically. Unsupported request kinds SHALL fail visibly without granting permission. Answers to retired requests SHALL be refused. Source: direction D37 and shared approval contract.



#### Scenario: Approve a command

- **WHEN** Codex requests command approval and the user selects an offered choice

- **THEN** exactly that native choice is returned once to that request in that conversation



#### Scenario: Answer a structured question

- **WHEN** Codex presents a question with choices and the user answers

- **THEN** its question identifier and answer reach the originating native request without starting an unrelated conversation



#### Scenario: Request is retired before answer

- **WHEN** a turn ends or its process exits before the user submits an answer

- **THEN** the controls are retired, a late answer is refused and no native write occurs



#### Scenario: Unknown native request

- **WHEN** a compatible runtime requests an unimplemented privileged operation

- **THEN** it receives an unsupported request response, the user sees the limitation and no operation is authorized automatically



### Requirement: Stop interrupts work without substituting process termination

Codex Stop SHALL cancel pending interactive requests and request native interruption of the active turn. Success SHALL require native completion reporting interruption. Refusal or timeout SHALL be visible and SHALL NOT be replaced by process termination. Confirmed close SHALL remain the separate contained-process cleanup action. Source: direction D7.



#### Scenario: Native interruption succeeds

- **WHEN** the user presses Stop during a Codex turn and Codex reports it interrupted

- **THEN** the session becomes Idle, history remains available and the App Server remains live



#### Scenario: Interruption cannot be confirmed

- **WHEN** interruption is unsupported or misses its deadline

- **THEN** Stop reports unsupported or timed out, does not claim Idle completion and does not kill the process



### Requirement: Steering is an explicit operation on the current turn

A compatible Codex session SHALL offer explicit steering during a running turn. Steering SHALL target that exact turn, retain unsent text on refusal and never start another turn as fallback. Ordinary Send SHALL remain disabled while Running. Steering text SHALL follow the same draft-removal and admission guarantees as Send.



#### Scenario: Steer running work

- **WHEN** the user explicitly steers active turn T and native admission and turn validation succeed

- **THEN** the input joins T once and the composer clears only if it still contains that submitted text



#### Scenario: Turn ended before steering

- **WHEN** T ends before the steer is accepted

- **THEN** steering is refused with the text retained and no new turn starts



### Requirement: Continue restores native history without executing it

Reopen SHALL start no Codex process. Explicit Continue SHALL validate the original target, runtime kind and native thread, resume only that thread and restore available history through the bounded event channel. It SHALL NOT replay prompts as new work, alter saved identity or silently create a replacement thread. Source: direction D7, D29-D30.



#### Scenario: Continue a saved thread

- **WHEN** the user continues a compatible saved Codex conversation

- **THEN** its available native history appears once, the session becomes Idle and no model turn or tool is initiated by restoration



#### Scenario: Missing native history

- **WHEN** the saved thread no longer exists in Codex history

- **THEN** Continue reports resume unavailable, retains the saved record and offers an explicit New session separately



#### Scenario: Empty native thread has no resumable history

- **WHEN** a saved thread created without a prompt has no native history on Continue

- **THEN** resume unavailable is shown and its saved record is retained



#### Scenario: Interactive capacity reached

- **WHEN** a new native interaction exceeds the pending request bound

- **THEN** it is refused or cancelled visibly without granting permission and accepted requests remain answerable



#### Scenario: Untracked child asks permission

- **WHEN** a child beyond the tracked identity bound sends an approval

- **THEN** it is refused visibly as untracked delegated work, never attributed to the root author or auto-approved



#### Scenario: Another runtime profile is the default

- **WHEN** the saved Codex profile is removed and the current default is Claude

- **THEN** Continue requires a compatible Codex selection and never launches Claude for that native thread



### Requirement: Delegated activity preserves child identity

The session event contract SHALL retain root, child, immediate parent and native thread identities for recognized Codex subagent activity. Child messages, plans and tools SHALL NOT become the parent's own reply. Unresolved relationships SHALL be visibly unknown rather than inferred from display names. Full child browsing and direct child controls are outside this change.



#### Scenario: Child emits output

- **WHEN** a recognized spawned child emits a message and tool updates

- **THEN** normalized events identify the child and parent, tool identities cannot collide across children, and the root chat shows an attributed delegated-activity summary



#### Scenario: Parent information is missing

- **WHEN** child output arrives before its relationship metadata

- **THEN** bounded pending attribution is resolved when metadata arrives or an unknown-child notice is shown without assigning it to the root author



#### Scenario: Nested and restored children

- **WHEN** native history contains a child and grandchild with proven parent relationships

- **THEN** restoration preserves those relationships and their original attribution without starting either child



### Requirement: Child requests retain root authority and truthful status

Recognized child approvals and questions SHALL be answerable through the root conversation with child attribution. They SHALL use the root run's authorization and immutable Kumiko target. Root close SHALL settle every descendant process. Unknown child outcomes SHALL NOT be displayed as completed successfully. Future child browsing SHALL not depend on copying native history into Kumiko storage.



#### Scenario: Child asks permission

- **WHEN** a child requests command approval

- **THEN** the root chat shows the child's identity and request, and answering routes once to the correct native child request



#### Scenario: Root closes during child work

- **WHEN** the user confirms root close while children are active

- **THEN** all child interactions are retired and the contained unit is settled or reported cleanup unresolved



#### Scenario: Child outcome is unknown

- **WHEN** the native connection is lost before a child completion is observed

- **THEN** its last known state is shown as unknown or disconnected, never successful



### Requirement: Real Codex qualification is recorded separately from regression tests

Each recorded Codex evidence section SHALL name version and OS and include launch/streaming, tools, command approval, Stop, close/descendant cleanup, MCP call and auth-required (pass with signature or unverified). Recovery, steering, structured questions and child attribution SHALL be separate optional observations. Fixtures SHALL NOT establish real observations. Missing observations SHALL NOT disable supported runtime features. M2 close SHALL require passing required Windows observations.

#### Scenario: Real Windows evidence passes

- **WHEN** the approved real-runtime walk records all claimed capabilities passing for one exact version on Windows

- **THEN** only that version/OS evidence is marked passed; later runtime versions remain admissible without new entries



#### Scenario: Tests pass but walk is unrun

- **WHEN** synthetic contract tests pass and the real walk has not run

- **THEN** the evidence states the missing checks without disabling supported runtime features



### Requirement: Codex updates do not require a Kumiko version allowlist

A valid Codex executable at or above 0.166.0 SHALL be admitted without a per-version registry update. Unknown additive data SHALL NOT prevent supported operations. Missing, inconsistent or below-minimum identity SHALL fail before native thread creation. Feature support SHALL be checked through supported contracts and ordinary native responses, never by starting paid turns as probes.



#### Scenario: Newer untested installed version

- **WHEN** installed Codex reports a valid version newer than the minimum with no evidence entry

- **THEN** it starts normally, supports the implemented feature contract, and evidence remains honestly labeled unverified for that version



#### Scenario: Experimental metadata changes in a newer version
- **WHEN** a newer Codex changes the shape of experimental child metadata
- **THEN** the run continues with delegated activity incomplete and its reason shown, while root prompts, approvals and Stop keep working

#### Scenario: Missing or invalid version

- **WHEN** the version probe returns missing or unparseable identity

- **THEN** launch is refused before thread creation with the version diagnostic



#### Scenario: Initialization version mismatch

- **WHEN** initialization reports a version different from the contained probe

- **THEN** start fails visibly and its unit is settled without creating a native thread



#### Scenario: Below minimum

- **WHEN** installed Codex reports a version below 0.166.0

- **THEN** the launcher names the minimum requirement and no native thread is created



### Requirement: Codex authentication stays native

Kumiko SHALL use native Codex sign-in and SHALL NOT manage provider credentials. A known authentication-required signature SHALL produce Codex-specific native sign-in guidance and explicit Retry. Unrecognized errors SHALL remain bounded native diagnostics without reusing Claude's classifier.



#### Scenario: Known Codex authentication failure

- **WHEN** a start or turn reports a signature established by real Codex authentication evidence

- **THEN** the pane names Codex native sign-in and offers explicit Retry without replacing saved identity



#### Scenario: Unknown auth-like diagnostic

- **WHEN** an unrecognized error mentions authentication

- **THEN** its native diagnostic is shown without falsely classifying it as the confirmed auth-required case



