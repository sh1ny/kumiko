import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import '../workbench_controller.dart';

String runtimeProfileExample(TargetPlatform platform) =>
    platform == TargetPlatform.windows
    ? r'node.exe <nodejs dir>\node_modules\npm\bin\npx-cli.js -y @agentclientprotocol/claude-agent-acp@<version>'
    : 'npx -y @agentclientprotocol/claude-agent-acp@<version>';
const runtimeInstallMessage =
    'Install Node ≥ 22 and @agentclientprotocol/claude-agent-acp, or add an argv runtime profile for your installed adapter.';
const _addProfile = '#add-runtime-profile';

Future<String?> showRuntimePicker(BuildContext context, AgentLaunch launch) =>
    showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('runtime-profile-picker'),
        title: const Text('Choose a runtime profile'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (launch.message != null) Text(launch.message!),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final profile in launch.profiles)
                      ListTile(
                        key: Key('pick-runtime-${profile.id}'),
                        title: Text(profile.name),
                        subtitle: Text(profile.executable),
                        onTap: () => Navigator.of(context).pop(profile.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_addProfile),
            child: const Text('Add profile'),
          ),
        ],
      ),
    );

Future<void> _configureMissingRuntime(
  BuildContext context,
  WorkbenchController controller,
  String? message, {
  String runtimeKind = 'claude-code',
}) async {
  final add = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('no-runtime-profile-prompt'),
      title: const Text('No runtime profile'),
      content: Text(
        '${runtimeKind == 'codex' ? 'Install Codex CLI or add an argv profile for your installed Codex executable.' : runtimeInstallMessage}${message == null ? '' : '\n$message'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Add profile'),
        ),
      ],
    ),
  );
  if (add == true && context.mounted) {
    await showRuntimeProfilesDialog(context, controller, startWithNew: true);
  }
}

/// Recovery stays in the original pane; configuration never launches another
/// chat or replaces the saved record before an explicit profile is selected.
Future<String?> chooseRecoveryRuntime(
  BuildContext context,
  WorkbenchController controller,
  RuntimeListResult list, {
  String runtimeKind = 'claude-code',
}) async {
  if (!context.mounted) return null;
  if (list.profiles.isEmpty) {
    await _configureMissingRuntime(
      context,
      controller,
      list.defaultReason,
      runtimeKind: runtimeKind,
    );
    return null;
  }
  final id = await showRuntimePicker(
    context,
    AgentLaunch(
      AgentLaunchKind.chooseProfile,
      profiles: list.profiles,
      message: list.defaultReason ?? 'The default runtime profile is unavailable. Choose or add a profile.',
    ),
  );
  if (!context.mounted) return null;
  if (id == _addProfile) {
    await showRuntimeProfilesDialog(context, controller, startWithNew: true);
    return null;
  }
  return id;
}

Future<void> launchAgentFlow(
  BuildContext context,
  WorkbenchController controller, {
  bool choose = false,
  String? profileId,
  String? workspaceId,
  String runtimeKind = 'claude-code',
}) async {
  final result = await controller.launchAgent(
    choose: choose,
    profileId: profileId,
    workspaceId: workspaceId,
    runtimeKind: runtimeKind,
  );
  if (!context.mounted) return;
  switch (result.kind) {
    case AgentLaunchKind.opened:
      return;
    case AgentLaunchKind.chooseProfile:
      final id = await showRuntimePicker(context, result);
      if (!context.mounted) return;
      if (id == _addProfile) {
        await showRuntimeProfilesDialog(
          context,
          controller,
          startWithNew: true,
        );
      } else if (id != null) {
        await launchAgentFlow(
          context,
          controller,
          profileId: id,
          workspaceId: result.workspaceId,
          runtimeKind: runtimeKind,
        );
      }
    case AgentLaunchKind.noProfile:
      await _configureMissingRuntime(
        context,
        controller,
        result.message,
        runtimeKind: runtimeKind,
      );
    case AgentLaunchKind.noWorkspace:
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            '${runtimeKind == 'codex' ? 'Codex' : 'Claude Code'} needs a workspace',
          ),
          content: const Text(
            'Open or select a folder first. No agent has been started.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Open folder'),
            ),
          ],
        ),
      );
      if (open == true) await controller.openFolder();
    case AgentLaunchKind.unavailable || AgentLaunchKind.failed:
      if (result.message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.message!)));
      }
  }
}

Future<void> showRuntimeProfilesDialog(
  BuildContext context,
  WorkbenchController controller, {
  bool startWithNew = false,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      RuntimeProfilesDialog(controller: controller, startWithNew: startWithNew),
);

class RuntimeProfilesDialog extends StatefulWidget {
  const RuntimeProfilesDialog({
    super.key,
    required this.controller,
    this.startWithNew = false,
  });
  final WorkbenchController controller;
  final bool startWithNew;
  @override
  State<RuntimeProfilesDialog> createState() => _RuntimeProfilesDialogState();
}

class _RuntimeProfilesDialogState extends State<RuntimeProfilesDialog> {
  final _name = TextEditingController();
  final _executable = TextEditingController();
  final _args = TextEditingController();
  final _env = TextEditingController();
  String? _editing;
  String _runtimeKind = 'claude-code';
  bool get _supportedKind =>
      _runtimeKind == 'claude-code' || _runtimeKind == 'codex';
  List<String>? _keptArgs;
  Map<String, String>? _keptEnv;
  List<String> _issues = const [];
  String? _error;
  bool _busy = false;
  WorkbenchController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    if (widget.startWithNew) _edit(null);
    controller.refreshRuntimes();
  }

  @override
  void dispose() {
    for (final field in [_name, _executable, _args, _env]) {
      field.dispose();
    }
    super.dispose();
  }

  bool _breaksLine(String value) =>
      value.contains('\n') || value.contains('\r');
  void _edit(RuntimeProfile? profile, {bool copy = false}) {
    _editing = profile == null || copy ? controller.newProfileId() : profile.id;
    _name.text = profile == null
        ? ''
        : copy
        ? '${profile.name} copy'
        : profile.name;
    _runtimeKind = profile?.runtimeKind ?? 'claude-code';
    _executable.text = profile?.executable ?? '';
    final args = profile?.args ?? const <String>[];
    final env = profile?.env ?? const <String, String>{};
    _keptArgs = args.any((a) => a.isEmpty || _breaksLine(a)) ? args : null;
    _keptEnv =
        env.entries.any((e) => _breaksLine(e.key) || _breaksLine(e.value))
        ? env
        : null;
    _args.text = args.join('\n');
    _env.text = env.entries.map((e) => '${e.key}=${e.value}').join('\n');
    _error = null;
    _issues = const [];
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on RpcException catch (e) {
      if (mounted) setState(() => _error = '${e.reason}: ${e.message}');
    } on ConnectionClosedException {
      if (mounted) setState(() => _error = 'The host is gone.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final issues = <String>[];
    final env = <String, String>{...?_keptEnv};
    if (_keptEnv == null) {
      for (final line in _env.text.split('\n')) {
        if (line.trim().isEmpty) continue;
        final separator = line.indexOf('=');
        if (separator < 0) {
          issues.add('The environment line "$line" is not NAME=value.');
        } else {
          env[line.substring(0, separator)] = line.substring(separator + 1);
        }
      }
    }
    final definition = RuntimeProfileDefinition(
      id: _editing!,
      name: _name.text.trim(),
      runtimeKind: _runtimeKind,
      executable: _executable.text.trim(),
      args:
          _keptArgs ??
          [
            for (final line in _args.text.split('\n'))
              if (line.isNotEmpty) line,
          ],
      env: env,
    );
    issues.addAll(definition.validate().map((issue) => issue.message));
    if (issues.isNotEmpty) {
      setState(() => _issues = issues);
      return;
    }
    await _run(() async {
      await controller.saveRuntimeProfile(
        RuntimeProfile.fromJson(definition.toJson()),
      );
      if (mounted) {
        setState(() {
          _editing = null;
          _issues = const [];
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('runtime-profiles-dialog'),
    child: SizedBox(
      width: 680,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _editing == null ? 'Runtime profiles' : 'Runtime profile',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_editing == null) ...[
                if (controller.runtimes == null) const Text('Loading...'),
                if (controller.runtimes?.profiles.isEmpty == true)
                  const Text(runtimeInstallMessage),
                for (final profile
                    in controller.runtimes?.profiles ??
                        const <RuntimeProfile>[])
                  ListTile(
                    title: Text(
                      '${profile.name}${controller.runtimes!.defaultId == profile.id ? ' (default)' : ''}',
                    ),
                    subtitle: Text(profile.executable),
                    trailing: Wrap(
                      children: [
                        if (controller.runtimes!.defaultId != profile.id)
                          TextButton(
                            key: Key('runtime-set-default-${profile.id}'),
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => controller.setDefaultRuntimeProfile(
                                      profile.id,
                                    ),
                                  ),
                            child: const Text('Set default'),
                          ),
                        if (profile.isBuiltin)
                          TextButton(
                            key: Key('runtime-copy-${profile.id}'),
                            onPressed: _busy
                                ? null
                                : () => setState(
                                    () => _edit(profile, copy: true),
                                  ),
                            child: const Text('Copy as new profile'),
                          )
                        else ...[
                          TextButton(
                            key: Key('runtime-edit-${profile.id}'),
                            onPressed: _busy
                                ? null
                                : () => setState(() => _edit(profile)),
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            key: Key('runtime-remove-${profile.id}'),
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => controller.removeRuntimeProfile(
                                      profile.id,
                                    ),
                                  ),
                            child: const Text('Remove'),
                          ),
                        ],
                      ],
                    ),
                  ),
                Row(
                  children: [
                    OutlinedButton(
                      key: const Key('add-runtime-profile'),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _edit(null)),
                      child: const Text('Add profile'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ] else ...[
                DropdownButtonFormField<String>(
                  key: const Key('runtime-kind'),
                  isExpanded: true,
                  initialValue: _runtimeKind,
                  decoration: const InputDecoration(labelText: 'Runtime kind'),
                  items: [
                    if (!_supportedKind)
                      DropdownMenuItem(
                        value: _runtimeKind,
                        child: Text('Unsupported runtime kind: $_runtimeKind'),
                      ),
                    const DropdownMenuItem(
                      value: 'claude-code',
                      child: Text('Claude Code · ACP adapter'),
                    ),
                    const DropdownMenuItem(
                      value: 'codex',
                      child: Text('Codex native App Server'),
                    ),
                  ],
                  onChanged: _busy || !_supportedKind
                      ? null
                      : (value) => setState(() => _runtimeKind = value!),
                ),
                SelectableText(
                  !_supportedKind
                      ? 'This runtime kind is not supported by this desktop. The stored profile is preserved read-only.'
                      : _runtimeKind == 'codex'
                      ? 'Codex 0.166.0 or newer. Use an absolute native executable and app-server as an argument. Sign in through Codex in a terminal.'
                      : 'Example: ${runtimeProfileExample(defaultTargetPlatform)}',
                ),
                _field('name', 'Name', _name),
                _field('executable', 'Executable', _executable),
                _field(
                  'args',
                  'Arguments, one per line',
                  _args,
                  multiline: true,
                  kept: _keptArgs != null,
                ),
                _field(
                  'env',
                  'Environment, NAME=value per line',
                  _env,
                  multiline: true,
                  kept: _keptEnv != null,
                ),
                for (final issue in _issues)
                  Text(
                    issue,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _editing = null),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('runtime-profile-save'),
                      onPressed: _busy || !_supportedKind ? null : _save,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _field(
    String id,
    String label,
    TextEditingController value, {
    bool multiline = false,
    bool kept = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      key: Key('runtime-profile-$id'),
      controller: value,
      enabled: _supportedKind,
      minLines: multiline ? 2 : 1,
      maxLines: multiline ? null : 1,
      readOnly: kept || _busy,
      decoration: InputDecoration(
        labelText: label,
        helperText: kept
            ? 'Holds an empty entry or a line break; kept unchanged.'
            : null,
      ),
    ),
  );
}
