/// The pure shell-profile model and its validation (design D6). The host
/// validates every save again with the same code.
library;

import 'dart:convert';

/// Profiles a user may keep.
const int maxUserProfiles = 64;

/// Arguments in one profile.
const int maxProfileArgs = 256;

/// UTF-8 size of one argument.
const int maxProfileArgBytes = 4096;

/// Environment overrides in one profile.
const int maxProfileEnv = 128;

/// UTF-8 size of one encoded profile (12 KiB): [maxUserProfiles] of them and
/// the detected shells fit in one `profile/list` result, which as a control
/// message is at most 1 MiB.
const int maxProfileBytes = 12 * 1024;

/// Id prefix of detected, in-memory profiles.
const String builtinProfilePrefix = 'builtin:';

bool isBuiltinProfileId(String id) => id.startsWith(builtinProfilePrefix);

/// One reason a profile is invalid: the [field] it concerns and a message
/// fit to show the user.
class ProfileIssue {
  const ProfileIssue(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => '$field: $message';
}

/// An argv launch description: separate arguments, never a command string.
class ProfileDefinition {
  const ProfileDefinition({
    required this.id,
    required this.name,
    required this.executable,
    this.args = const [],
    this.cwd,
    this.env = const {},
  });

  factory ProfileDefinition.fromJson(Map<String, Object?> json) {
    final args = json['args'];
    final env = json['env'];
    return ProfileDefinition(
      id: json['id']! as String,
      name: json['name']! as String,
      executable: json['executable']! as String,
      args: args == null
          ? const []
          : [for (final a in args as List) a as String],
      cwd: json['cwd'] as String?,
      env: env == null
          ? const {}
          : {
              for (final e in (env as Map).entries)
                e.key as String: e.value as String,
            },
    );
  }

  final String id;
  final String name;
  final String executable;
  final List<String> args;
  final String? cwd;
  final Map<String, String> env;

  bool get isBuiltin => isBuiltinProfileId(id);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'executable': executable,
    'args': args,
    if (cwd != null) 'cwd': cwd,
    'env': env,
  };

  /// Every reason this profile cannot be saved; empty when it is valid.
  List<ProfileIssue> validate() {
    final issues = <ProfileIssue>[];
    if (id.isEmpty) issues.add(const ProfileIssue('id', 'The id is required.'));
    if (name.trim().isEmpty) {
      issues.add(const ProfileIssue('name', 'The name is required.'));
    }
    if (executable.trim().isEmpty) {
      issues.add(
        const ProfileIssue('executable', 'The executable is required.'),
      );
    }
    if (args.length > maxProfileArgs) {
      issues.add(
        const ProfileIssue(
          'args',
          'At most $maxProfileArgs arguments are allowed.',
        ),
      );
    }
    for (var i = 0; i < args.length; i++) {
      if (utf8.encode(args[i]).length > maxProfileArgBytes) {
        issues.add(
          ProfileIssue(
            'args',
            'Argument ${i + 1} is longer than $maxProfileArgBytes bytes.',
          ),
        );
        break;
      }
    }
    if (env.length > maxProfileEnv) {
      issues.add(
        const ProfileIssue(
          'env',
          'At most $maxProfileEnv environment entries are allowed.',
        ),
      );
    }
    for (final name in env.keys) {
      if (name.isEmpty || name.contains('=')) {
        issues.add(
          ProfileIssue(
            'env',
            'The environment variable name "$name" is invalid: it must not '
                'be empty or contain "=".',
          ),
        );
      }
    }
    if (issues.isEmpty &&
        utf8.encode(jsonEncode(toJson())).length > maxProfileBytes) {
      issues.add(
        const ProfileIssue('profile', 'A profile may be at most 12 KiB.'),
      );
    }
    return issues;
  }
}

/// The stored form of an argument list: a JSON array of strings.
String encodeProfileArgs(List<String> args) => jsonEncode(args);

List<String> decodeProfileArgs(String stored) => [
  for (final a in jsonDecode(stored) as List) a as String,
];
