## MODIFIED Requirements



### Requirement: Each live session run receives a Kumiko MCP entry

When the host creates or continues a session while its tool endpoint is available, it SHALL pass exactly one stdio MCP server entry named `kumiko` through the runtime-specific session configuration: ACP session requests or native Codex per-run App Server configuration. The entry's command SHALL be the bundled host executable in `mcp-bridge` mode. Kumiko SHALL NOT write or change any repository file or runtime configuration to deliver it. Source: ADR 0005 decisions 2 and 6; D14, D15.



#### Scenario: New session gets the entry

- **WHEN** the user starts a Claude Code session in a workspace

- **THEN** `session/new` carries one `mcpServers` entry named `kumiko` whose command is the host executable with the bridge argument, and no file in the workspace is created or changed



#### Scenario: Continue gets a new entry

- **WHEN** the user continues a saved session through load or resume

- **THEN** that request carries a `kumiko` entry whose secret differs from every earlier run of that session



#### Scenario: Endpoint unavailable

- **WHEN** the host's tool endpoint could not be created and the user starts a session

- **THEN** `session/new` carries an empty `mcpServers` list, and the session shows Kumiko tools *unavailable* with the endpoint's reason



#### Scenario: Adapter rejects session creation

- **WHEN** the adapter answers `session/new` with an error

- **THEN** the start fails with the adapter's error as it does today, no session record is stored, the secret minted for that start is revoked, and no second `session/new` is sent





#### Scenario: Codex receives its bridge configuration

- **WHEN** a Codex run starts or continues with the endpoint available

- **THEN** its App Server receives exactly one kumiko MCP entry with the current run secret before the native thread is usable, without changing user or repository configuration files



#### Scenario: Codex configuration cannot be applied

- **WHEN** native per-run MCP configuration is unsupported or invalid

- **THEN** the run reports tools unavailable with the reason, never connected, and any unused grant is revoked



#### Scenario: Child uses inherited Kumiko tools

- **WHEN** a Codex child invokes the inherited kumiko bridge

- **THEN** authorization uses its root Kumiko run's role and immutable target and does not claim a separate child authority



#### Scenario: Unrelated commands cannot read bridge secret

- **WHEN** a fixture model command and an unrelated MCP server inspect their environments

- **THEN** neither sees the root bridge secret while the kumiko bridge receives it through its entry-only environment, and the secret appears in no file the runtime wrote during the run



#### Scenario: User already defines kumiko MCP

- **WHEN** effective user or workspace configuration defines an MCP server named kumiko, or its absence cannot be verified

- **THEN** tool delivery is unavailable with a conflict reason, no user entry is overwritten and the unused grant is revoked


#### Scenario: Child bridge connection cap
- **WHEN** more child bridges than the per-grant bound authenticate
- **THEN** extra connections are refused busy, the root shows child tools unavailable and no other session's tools change

## ADDED Requirements

### Requirement: Native audit coverage is explicit and bounded

Test-only native canary audits SHALL bind content selection before a run, and legacy manifests and defaults SHALL keep legacy coverage. Only an exact owner-approved manifest naming changed-artifacts-v1, v2, v3 or v4 SHALL enable wider coverage, with the selection-specific handling in the scenarios below; each earlier selection keeps its recorded meaning. Byte, file, confinement and no-follow limits SHALL remain unchanged. Source: design D5.

#### Scenario: Explicit changed-artifact coverage

- **WHEN** preparation binds changed-artifacts-v1 and both bounded inventories are complete
- **AND** preparation printed the fixed changed-artifacts-v1 disclosure beside the manifest hash and the helper validated the canonical manifest scope before claim
- **THEN** new/changed regular files, including a model cache and descendants of unclassified directories with unchanged parent metadata, join the existing mutable-artifact selection once, with .sqlite/-wal/-shm files always selected at every depth even when metadata is equal; a fully accounted ordinary directory metadata change alone adds no error
- **AND** scanned content uses one unchanged bounded audit, emits no contents or arbitrary paths/names/hashes, retains matches despite later errors, records the metadata-equality and ASCII/UTF-8 detector limits, and reports incomplete for every unaccounted or unstable entry

#### Scenario: Legacy and invalid coverage selection

- **WHEN** selection is absent/legacy, unknown, malformed, mismatched, overridden at walk/stats time, late or repeated
- **THEN** absent/legacy preserves legacy selection; invalid or late/repeated changes are refused, a prepare echo mismatch aborts before startup/content I/O and a result echo mismatch stays incomplete with prior failures preserved

#### Scenario: Protected entries or inventory bounds prevent completeness

- **WHEN** a protected leaf (auth.json/config.toml plus other known credential/configuration names established before implementation) at any depth changes or is removed, or a link/nonregular/missing/unstable entry (except where the scenarios below account for it) or the selection's metadata bound (4096 entries for changed-artifacts-v1, 65,536 with the retained-string budget for changed-artifacts-v2, v3 and v4) prevents accounting
- **THEN** the audit remains incomplete, protected contents and links are never read, no cap is raised and no legacy fallback or exclusion creates a pass
- **AND** an incomplete changed-artifacts-v1, v2, v3 or v4 baseline aborts before App Server/provider work; the consumed attempt is recorded INCOMPLETE with baseline counters and no-provider/no-content-scan indicators; ordinary directory inventories are checked for concurrent membership changes

#### Scenario: Normal native home coverage

- **WHEN** an exact owner-approved manifest binds changed-artifacts-v2 for a native home with more than 4096 and at most 65,536 entries, including symlinks or junctions in the native-home root
- **THEN** both inventories admit up to 65,536 entries within the retained-string budget, and exhausting that budget or an over-long path or target keeps the audit incomplete; a supported link (a symlink or junction observed without following it) whose kind, own metadata and target text are identical in both inventories is accounted for without being followed or read; an unavailable, failed, unsupported or unstable link observation, and an added, removed, retargeted or otherwise changed link, any other non-regular entry, or a link in the workspace or profile root keeps the audit incomplete
- **AND** link target text is never printed, persisted or emitted; the canonical v2 disclosure states the 65,536-entry bound, the unchanged-link and concurrent-writer detector limits and the pause of other Codex sessions; changed-artifacts-v1 and legacy keep their recorded behaviour, and the scanner's file and byte limits are unchanged

#### Scenario: Native home sockets

- **WHEN** an exact owner-approved manifest binds changed-artifacts-v3 on Windows for a native home that contains Unix-domain sockets
- **THEN** v3 behaves as v2, and a socket observed without opening it, with the reparse-point attribute and the AF_UNIX reparse tag, is accounted for when its own metadata is identical in both inventories; an added, removed or metadata-changed socket is counted as a changed socket and does not make the audit incomplete, and it is never selected for the content scan
- **AND** an unavailable, failed or non-AF_UNIX socket observation, a socket at a protected leaf name that is added, removed or changed, a transition between a socket and another entry kind, a socket on another operating system, and every pipe, device or unknown type keep the audit incomplete; no socket name, path or extension is emitted, and changed-artifacts-v2, v1 and legacy keep their recorded behaviour

#### Scenario: Removed native entries

- **WHEN** an exact owner-approved manifest binds changed-artifacts-v4 and an entry present in the baseline is absent after the run
- **THEN** v4 behaves as v3, and a removed file, directory, link or socket that is not at a protected leaf name is counted in a content-free removed-entries counter without making the audit incomplete
- **AND** a removed protected entry, and every traversal, metadata, storage or admission error that leaves entries out of the after-run inventory, keep the audit incomplete; a new or changed file elsewhere is still selected and scanned; no removed name or path is emitted, and changed-artifacts-v3, v2, v1 and legacy keep their recorded behaviour
