# ADR 0005: One host-owned Kumiko tool service with per-session authorization

- **Status:** accepted (2026-10-28)
- **Date:** 2026-10-28
- **Source:** document-kumiko-direction D6, D8, D14, D15, D54

## Context

Agents reach Kumiko operations (project/task context, workspace tools, later shared records) through tools. D15 settles a single host-owned MCP service. Its connection is delivered per adapter: session injection where qualified, additive native registration otherwise. Authority comes from the host's per-operation checks, never from project ids, working directories or text claiming approval. ACP sessions accept `mcpServers` entries, including stdio commands. Delivery is adapter- and version-dependent; ACP issue #883 reports failures.

## Decision

1. The host runs one **tool service** for its lifetime. Each agent session gets its own MCP connection to it, which the host creates when it launches the session.
2. **Delivery:** for ACP sessions the host supplies a stdio MCP entry in `session/new` / `session/resume`. Its command is the bundled host executable in a thin `mcp-bridge` mode. The bridge connects back to the running host over a **per-user local endpoint**: a named pipe on Windows, a Unix domain socket in a user-only directory on POSIX. The endpoint is ACL- or permission-restricted to the current OS user. Additive native registration (D15) is a fallback added only where a change qualifies it.
3. **Credential:** each bridge presents a per-session secret. The host passes it through the MCP entry's environment and never writes it to repository files. The host maps that secret to exactly one session record (ADR 0004).
4. **Authorization:** every tool call is checked in the host against that session's role, owner, execution target and, later, current team grants. Tools that the role forbids (for example any write for the read-only chat role, D54) are absent from the session's tool list and rejected if called anyway.
5. **Honesty:** a session reports `kumiko-tools: connected` only after an authenticated tool call succeeds in that session. Advertised-but-unusable delivery shows as unavailable for that adapter version.
6. Kumiko tools never replace or rewrite the runtime's own MCP configuration (D14).

## Rejected alternatives

- **Localhost HTTP MCP endpoint.** Other local processes can reach it, and it needs a port and token handling anyway. A per-user pipe/socket narrows exposure to the user's own processes.
- **A full MCP server process per repository or session.** Duplicates state and authority and complicates lifetime.
- **Universal `.mcp.json` discovery as the delivery path** (rejected in D15).

## Consequences

- The per-user endpoint is the one listening surface Kumiko adds on the machine. It is created per host instance, removed on exit, and its access control is tested on each OS.
- Restricting Kumiko tools does not restrict runtime built-ins (D6). Enforcing the read-only role across built-ins is a separate qualification, not covered by this ADR.

## Reversal cost

High for the authorization model and the public tool contract. Medium for the bridge/endpoint mechanics.

## Qualification in M1

One read-only tool (for example session/workspace info) is called successfully by a Claude Code ACP session on each OS, or reported unavailable with the observed failure. A call with a wrong or absent session secret is rejected.
