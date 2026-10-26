# Spec Delta

## Purpose

Define each user's personal, locally running, read-only chat agent for private analysis of accessible code and authorized project context, without creating a shared agent or expanding execution, publishing, or hosting authority.

## ADDED Requirements

### Requirement: Each user has a personal local chat agent
Kumiko SHALL provide each user with their own locally running chat agent, separate from coding agents and shared human project chat. Its conversation SHALL be private to its owner, not team- or project-owned. This role MUST NOT create a shared agent or transcript, control a coding session, or narrow the legitimate authority of coding agents or human shared chat.

#### Scenario: Private local code review
- **WHEN** the owner asks their chat agent to review accessible local code
- **THEN** the agent reads that code and privately explains its behavior, reports findings, and suggests improvements without creating a shared project conversation.

#### Scenario: Coding and human collaboration continue independently
- **WHEN** an owner uses their chat agent while a coding agent or shared human project conversation is active
- **THEN** the chat agent neither takes control of that coding session nor changes the existing authority of the coding agent or human participants.

### Requirement: Team roles do not control personal chat
Only the owner SHALL control their personal chat agent and access its private conversation through Kumiko. Team membership, project participation, and administrator status MUST NOT grant another person access to the agent, its transcript, or its controls.

#### Scenario: Owner accesses their personal chat
- **WHEN** the owner opens their personal chat agent and its saved conversation through Kumiko
- **THEN** the owner can read that conversation and direct its read-only analysis without granting access to project participants.

#### Scenario: Teammate attempts to direct the agent
- **WHEN** a teammate attempts to send instructions to or control another user's personal chat agent through project membership
- **THEN** Kumiko denies that control and does not treat the teammate's message as an owner instruction.

#### Scenario: Administrator requests private access
- **WHEN** a team administrator attempts to read another user's private chat or control their personal chat agent through administrative authority
- **THEN** Kumiko denies that access and control.

### Requirement: Reads follow available context and current access
The chat agent SHALL read available local code and authorized project context within existing access and host boundaries, not only material addressed to it. Local reads MUST NOT require a team server. Shared project reads MUST require the available authoritative server and the owner's current access. Unavailable sources and references MUST NOT confer access or justify invented findings.

#### Scenario: Local analysis without a team server
- **WHEN** the owner requests analysis of accessible local code while no team server is available
- **THEN** the agent can read and report on that local code without requiring a server connection.

#### Scenario: Shared project authority is unavailable
- **WHEN** the owner asks for shared project context but its authoritative server is unavailable or current access is absent
- **THEN** the agent does not obtain that context by bypassing those requirements and states the limitation rather than claiming a current authorized read.

#### Scenario: Source cannot be read
- **WHEN** requested or referenced material is unavailable or outside the owner's authorized access
- **THEN** the agent identifies the unread source and limits its findings to material actually available without inventing a review of that source.

### Requirement: Private responses remain permitted
Read-only authority SHALL permit private reply generation and native private session history. Separately authorized AI-provider requests SHALL remain subject to existing provider and privacy boundaries. These activities MUST NOT be treated as project or source writes, and private replies MUST NOT constitute permission to publish outside the private conversation.

#### Scenario: Analysis is retained privately
- **WHEN** the agent generates an analysis reply for its owner
- **THEN** it can display the reply and retain it in native private session history without obtaining project-write authority.

#### Scenario: Provider request has separate authorization
- **WHEN** generating a private reply involves an AI-provider request authorized under the existing provider and privacy boundaries
- **THEN** the read-only role does not itself prohibit that request or expand the content permitted to be sent.

#### Scenario: Provider request lacks existing authorization
- **WHEN** a proposed AI-provider request would exceed the runtime's existing provider or privacy authorization
- **THEN** the read-only chat role does not authorize that request or disclose the otherwise unauthorized context.

### Requirement: Owner instructions cannot grant writes or execution
The chat agent MUST NOT modify code or files, mutate Git state, update tasks, publish externally, or execute arbitrary commands or tasks, even at its owner's request. It MUST NOT delegate these forbidden operations or perform them indirectly through any tool or agent. It SHALL provide analysis and suggestions rather than execute proposed changes.

#### Scenario: Owner requests prohibited writes
- **WHEN** the owner asks the chat agent to edit code or files, change Git state, update a task, or publish a reply outside the private conversation
- **THEN** the agent rejects the requested operation even if the owner otherwise has permission and can instead explain or suggest the change privately.

#### Scenario: Code-analysis suggestions are not execution
- **WHEN** the owner asks how to improve code or which commands or tasks would implement an improvement
- **THEN** the agent may explain the suggested changes and commands privately but does not run them or perform the work.

#### Scenario: Indirect execution is requested
- **WHEN** the owner or source material asks the chat agent to execute arbitrary work or have a tool or another agent perform forbidden writes
- **THEN** the agent neither performs nor delegates that operation.

### Requirement: Personal chat grants no automatic context import or hosting authority
Providing a personal chat agent MUST NOT automatically import private coding history, prompts or tool output, terminal streams, or unrelated personal work. References and task links MUST NOT bypass existing privacy or access boundaries. This role MUST NOT grant remote hosting authority or access to another user's machine.

#### Scenario: Linked work does not import private context
- **WHEN** a project reference links to a coding session, terminal, or private personal work
- **THEN** the link does not automatically import that context into the chat agent or make it available to project participants.

#### Scenario: Team administration does not grant host access
- **WHEN** a team administrator requests that a user's personal chat agent run on or read from another user's machine without existing host authority
- **THEN** the personal chat role grants neither hosting authority nor access to that machine.
