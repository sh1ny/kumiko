/// Exact adapter name, version and qualified extra capabilities (load/resume).
///
/// Add entries only from real observations in
/// docs/qualification/claude-agent-acp.md. The offline CI checker parses this
/// literal list; keep it as tuples of single-quoted strings and `<String>` lists.
/// Runtime claim logic must also require the adapter to advertise each feature.
/// An empty list makes no adapter qualification claim.
const qualifiedAdapters = <(String, String, List<String>)>[];
