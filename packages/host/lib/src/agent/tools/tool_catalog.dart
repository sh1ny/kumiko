import 'package:host_protocol/host_protocol.dart';

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

  String? _validate(Object? arguments, {required bool describeInput}) {
    if (arguments == null) return null;
    if (arguments is! Map) return 'arguments must be an object';
    for (final key in arguments.keys) {
      if (!properties.contains(key)) {
        return describeInput
            ? 'unexpected argument "$key"'
            : 'unexpected argument';
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

  /// Uses the same role and schema checks for authenticated MCP requests and
  /// private OMP callbacks. OMP does not need echoed native input in errors.
  static String? refusal(
    ToolRole role,
    Object? name,
    Object? arguments, {
    bool describeInput = true,
  }) {
    if (name is! String) return 'invalid params: missing tool name';
    final tool = find(role, name);
    if (tool == null) {
      return describeInput
          ? 'tool $name is not available'
          : 'tool is not available';
    }
    final invalid = tool._validate(arguments, describeInput: describeInput);
    return invalid == null ? null : 'invalid arguments: $invalid';
  }
}

/// Facts captured by the host, never by a tool caller. Both tool transports
/// use the same read-only operation and bind it to their own run.
final class ToolRunFacts {
  const ToolRunFacts({
    required this.sessionId,
    required this.role,
    required this.runtime,
    required this.adapter,
    required this.version,
    required this.target,
  });

  final String sessionId, runtime, adapter, version, target;
  final ToolRole role;

  Json sessionInfo() => {
    'sessionId': sessionId,
    'role': role.wire,
    'runtime': runtime,
    'adapter': {'name': adapter, 'version': version},
    'target': {'path': target},
  };
}
