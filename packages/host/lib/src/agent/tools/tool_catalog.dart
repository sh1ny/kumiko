/// The role a tool grant was issued for. M1 has only [coding].
enum ToolRole {
  coding('coding');

  const ToolRole(this.wire);

  /// The name used in tool results.
  final String wire;
}

/// One tool in the catalog: its MCP definition and argument schema.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.properties,
    this.readOnly = false,
  });

  final String name;
  final String description;

  /// Property names the tool accepts. M1's only tool accepts none.
  final Set<String> properties;
  final bool readOnly;

  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': <String, Object?>{
      for (final p in properties) p: <String, Object?>{},
    },
    'additionalProperties': false,
  };

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': {'readOnlyHint': readOnly},
  };

  /// Validates MCP `arguments` against the schema. Returns an error message,
  /// or null when valid. An absent value counts as an empty object.
  String? validate(Object? arguments) {
    if (arguments == null) return null;
    if (arguments is! Map) return 'arguments must be an object';
    for (final key in arguments.keys) {
      if (!properties.contains(key)) {
        return 'unexpected argument "$key"';
      }
    }
    return null;
  }
}

/// Maps a role to the tools it may list and call. Checked on every call.
abstract final class ToolCatalog {
  static const sessionInfoName = 'kumiko_session_info';

  static const sessionInfo = ToolDefinition(
    name: sessionInfoName,
    description:
        'Returns this Kumiko session\'s id, role, runtime, adapter name and '
        'version, and the target workspace path. Read-only; takes no '
        'arguments.',
    properties: {},
    readOnly: true,
  );

  static const _byRole = <ToolRole, List<ToolDefinition>>{
    ToolRole.coding: [sessionInfo],
  };

  static List<ToolDefinition> toolsFor(ToolRole role) =>
      _byRole[role] ?? const [];

  static ToolDefinition? find(ToolRole role, String name) {
    for (final t in toolsFor(role)) {
      if (t.name == name) return t;
    }
    return null;
  }
}
