# Spec Delta

## ADDED Requirements

### Requirement: Unsent drafts are stored per session
The composer text of a session with a saved record SHALL be stored by the host under that session only: while typing within the draft save bound, when its pane closes and when the app quits. A draft SHALL NOT be sent automatically, logged, or moved to another session. Text in a pane with no saved record SHALL stay in memory only, marked *Draft not saved*. Source: direction "Unsent conversation drafts remain local and scoped", D7.

#### Scenario: Draft survives quit
- **WHEN** the user types "check the tests" into session A's composer without sending and quits Kumiko
- **THEN** the store holds that text as A's draft, and no prompt was sent to A's adapter

#### Scenario: Draft survives a desktop kill
- **WHEN** the user types into session A's composer, waits longer than the draft save bound, and the desktop is killed
- **THEN** the store holds the typed text as A's draft

#### Scenario: Draft survives closing the pane
- **WHEN** the user types into idle session A's composer and closes its pane
- **THEN** the pane closes without a prompt and the store still holds A's draft

#### Scenario: No saved record yet
- **WHEN** the user types into a pane whose session start failed before a native id
- **THEN** the pane shows *Draft not saved*, and no draft is stored

#### Scenario: Draft too large
- **WHEN** the composer text exceeds the per-draft bound
- **THEN** the pane shows *Draft not saved: too long*, the previously stored draft stays as it was, and the composer keeps the text

#### Scenario: Draft storage full
- **WHEN** saving a new draft would exceed the total draft bound
- **THEN** the save is refused, the pane shows *Draft not saved: draft storage full*, and every other stored draft is unchanged

#### Scenario: Save fails
- **WHEN** a draft save fails because the host is lost
- **THEN** the pane shows *Draft not saved*, the composer keeps the text, and the next edit after the host restarts saves it again

### Requirement: Closing with an unsaved draft says it will be lost
Closing a chat pane or tab, or quitting, while a draft's latest text is not stored (its save was refused or failed, or a flush did not complete) SHALL name that pane in the close confirmation or exit dialog as *Draft not saved* with the reason, stating the text will be lost. Cancel SHALL keep the pane and its text. A draft whose latest text is stored SHALL NOT cause a prompt. Source: D7.

#### Scenario: Close a pane with a refused draft
- **WHEN** session A's latest draft save was refused `draft-cap` and the user closes A's pane
- **THEN** the confirmation names A as *Draft not saved: draft storage full*, Cancel keeps the pane and the composer text, and confirming closes it

#### Scenario: Close a pane with a stored draft
- **WHEN** session A's latest draft text is stored and A is idle, and the user closes its pane
- **THEN** no confirmation is shown and A's draft stays stored

### Requirement: A restored pane shows its session's draft
When a chat pane is restored on reopen, its composer SHALL show the stored draft of its own session, before and after Continue. *New session* in that pane SHALL start with an empty composer and leave the old session's draft stored with it. If the old composer's text cannot be stored when the user chooses *New session*, the pane SHALL name the reason and ask before the text is lost. Source: direction "Unsent conversation drafts remain local and scoped", D7.

#### Scenario: Draft returns on reopen
- **WHEN** the user quits with an unsent draft in session A and reopens Kumiko
- **THEN** A's pane shows *Saved, not running* with the draft in its composer, and nothing is sent until the user chooses Continue and then Send

#### Scenario: New session after resume unavailable
- **WHEN** a restored pane of session A shows *resume unavailable* with a draft, and the user chooses New session
- **THEN** the new session's composer is empty, and A's draft stays stored for A

#### Scenario: New session with a draft that cannot be stored
- **WHEN** the composer of ended session A holds text whose save fails, is refused or does not finish within 2 s, and the user chooses New session
- **THEN** a confirmation names the reason and says the text will be lost; Cancel keeps A's pane and its text and starts nothing, and confirming starts the new session with an empty composer

#### Scenario: Stored draft cannot be read
- **WHEN** a restored pane asks for its draft and the host refuses or fails the read
- **THEN** the composer is empty, the pane shows *Draft not loaded* with the reason, and the stored draft is not overwritten until the user types

#### Scenario: Typing after a failed load
- **WHEN** session A's stored draft has revision 500, its load fails, and the user types new text Q and waits for it to be saved
- **THEN** Q is stored as A's draft, and after a reopen A's composer shows Q

#### Scenario: Send right after a failed load
- **WHEN** session A's stored draft P has revision 500, its load fails, the user types Q and sends it at once, the host acknowledges the prompt, and the desktop is then killed
- **THEN** after a reopen A's composer shows neither P nor Q, and neither text appears in any file under the profile directory

#### Scenario: Send before a slow load returns
- **WHEN** a restored pane of session A is slow to load its stored draft P, the user types Q and sends it before the load returns, the host acknowledges the prompt, and the desktop is then killed
- **THEN** after a reopen A's composer shows neither P nor Q

#### Scenario: Load arrives after the user typed
- **WHEN** a restored pane of session A is slow to load its stored draft P, and the user types Q before the load returns
- **THEN** the composer keeps Q, and after the save Q is stored as A's draft

### Requirement: A sent or cleared draft cannot be recovered
Before dispatching a composer send to the adapter, the host SHALL remove the stored draft if it is the sent text or an earlier edit of it; newer or unrelated text stays. An empty composer removes the draft. Once a removal is committed, its text SHALL be unrecoverable from every file under the profile directory. A failed removal SHALL refuse the send before dispatch. Source: D7, D29.

#### Scenario: Send removes the draft
- **WHEN** the user types a prompt containing `kumiko-canary-d1f9` into session A's composer, waits for the draft to be saved, sends it, and the host acknowledges the prompt
- **THEN** while the host is still running, that text appears in no file under Kumiko's profile directory, including the stores, their journals and the host logs

#### Scenario: Clearing removes the draft
- **WHEN** the user empties session A's composer after its draft was saved and quits
- **THEN** A has no stored draft and its earlier text appears in no file under the profile directory

#### Scenario: Retry with a different draft
- **WHEN** session A's prompt P failed, the user types and saves draft Q, and then chooses Retry, which resends P and is accepted
- **THEN** Q stays stored as A's draft and stays in the composer

#### Scenario: Stale save while a prompt is being sent
- **WHEN** session A's composer holds P with its save still pending, the user sends P, the host removes the draft, the pending save of P is refused as stale before the desktop receives the acknowledgement, the prompt is accepted, and the desktop is then killed
- **THEN** after the acknowledgement P's text appears in no file under the profile directory, and after a reopen A's composer does not show P

#### Scenario: Edits while a prompt is being sent
- **WHEN** the user sends prompt P from A's composer and types new text R before the host acknowledges P
- **THEN** after the acknowledgement R is stored as A's draft, and P's text appears in no file under the profile directory

#### Scenario: Prompt refused by the adapter
- **WHEN** the user sends A's draft, the host removes it, and the adapter then refuses the prompt
- **THEN** the composer still holds the text, it is stored again as A's draft, and the pane shows the refusal

#### Scenario: Removal fails
- **WHEN** the user sends A's draft and the host cannot commit the draft removal because of a store error
- **THEN** the prompt is refused with that error before it reaches the adapter, nothing runs, the draft stays stored and in the composer, and sending again later is safe

#### Scenario: Removal commits after its deadline
- **WHEN** the draft removal for A's send commits only after the draft deadline, the prompt was refused, the desktop's first attempt to store the composer text again was refused because the store was not responding, and the user types nothing more
- **THEN** once the store answers again A's composer text is stored as A's draft, and the prompt never ran

#### Scenario: Send while draft storage is unavailable
- **WHEN** session A has stored draft P, the draft store fails to open at the next launch, the user continues A, types Q and sends it
- **THEN** the prompt is refused *draft storage unavailable* before it reaches the adapter, nothing runs, the composer keeps Q, and after a launch with working storage A's draft is P and nothing was sent

#### Scenario: Reset draft storage
- **WHEN** drafts are unavailable because the draft store cannot be opened, and the user chooses **Reset draft storage** and confirms that stored drafts will be lost
- **THEN** every stored draft is gone, composer sends work again, and each open composer's text is stored as its session's draft

#### Scenario: Draft storage not responding at send
- **WHEN** the draft store is held inside a commit and the user sends A's draft
- **THEN** within the draft deadline the prompt is refused *draft storage not responding* before it reaches the adapter, nothing runs, and once the store answers again the composer text is stored as A's draft without the user typing

## MODIFIED Requirements

### Requirement: Each session keeps a saved record; transcripts stay in the runtime
The host SHALL store one record per session with its Kumiko session id, runtime kind, adapter name and version, native session id, role `coding` and target, written when the adapter returns the native session id. Prompts, replies and tool output SHALL NOT be written to Kumiko's store or logs; the conversation SHALL remain in the runtime's own history. The one exception is a session's unsent draft, stored until it is sent or cleared. Source: ADR 0004 decision 3, D29, D46.

#### Scenario: Record survives restart
- **WHEN** a session is started in workspace A and the host is restarted
- **THEN** the store holds its record with the same Kumiko id, native session id, adapter version and A's path and identity

#### Scenario: Start fails before a native id
- **WHEN** the adapter fails `session/new`
- **THEN** no session record is stored, and the pane shows the failure with Retry

#### Scenario: No transcript in Kumiko's files
- **WHEN** a session exchanges a prompt containing the text `kumiko-canary-7f3a` and the host is stopped
- **THEN** that text appears in no file under Kumiko's profile directory, including the store and host logs

#### Scenario: An unsent draft is the only stored text
- **WHEN** the user leaves `kumiko-canary-5b2e` unsent in a session's composer and quits
- **THEN** that text appears in the store only as that session's draft, and in no log or other file under the profile directory

### Requirement: Closing a running agent asks for confirmation
Closing a pane or tab holding a session whose turn is running SHALL first ask "Are you sure you want to stop the running agent?", in one confirmation with any busy terminals. Cancel SHALL keep it running. Confirm SHALL cancel the turn, answer pending requests as cancelled and terminate the process tree. Other sessions SHALL close without a prompt. Moving SHALL NOT warn. Source: direction "Agent tab close depends on running work", D7.

#### Scenario: Close an idle session
- **WHEN** the user closes the pane of an idle session
- **THEN** no confirmation is shown, the adapter's process tree is terminated, the pane closes, and the session's saved record remains

#### Scenario: Cancel closing a running session
- **WHEN** the user closes the pane of a running session and chooses Cancel
- **THEN** the pane, its place in the split, and the turn keep running, and no cancel was sent to the adapter

#### Scenario: Confirm closing a running session
- **WHEN** the user closes a running session's pane and confirms
- **THEN** the turn is cancelled, the process tree is terminated, the pane closes, the saved record remains, and files the agent changed are left as they are

#### Scenario: Tab with a running agent and a live terminal
- **WHEN** the user closes a tab holding a running session and a terminal running a program
- **THEN** one confirmation names both, and confirming ends both and closes the tab

#### Scenario: Turn ends while the confirmation is open
- **WHEN** the confirmation is open and the turn ends on its own, and the user then confirms
- **THEN** the session is closed as an idle session, with no cancel sent
