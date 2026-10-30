import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import '../workbench_controller.dart';

/// Asks which profile to start; the id, or null when dismissed. [missingDefault]
/// names a default profile that is no longer available.
Future<String?> showProfilePicker(
  BuildContext context,
  List<ShellProfile> profiles, {
  String? missingDefault,
}) => showDialog<String>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('profile-picker'),
    title: const Text('Choose a shell profile'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (missingDefault != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'The default profile "$missingDefault" is no longer available.',
                key: const Key('choose-profile-prompt'),
              ),
            ),
          // Up to 64 user profiles plus the detected shells: the list
          // scrolls when it is taller than the dialog may grow.
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in profiles)
                  ListTile(
                    key: Key('pick-${p.id}'),
                    dense: true,
                    title: Text(p.name),
                    subtitle: Text(p.executable),
                    onTap: () => Navigator.of(context).pop(p.id),
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
    ],
  ),
);

/// Says there is no profile at all; true when the user chose **Add profile**.
Future<bool> showNoProfilePrompt(BuildContext context) async {
  final add = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('no-profile-prompt'),
      title: const Text('No shell profile'),
      content: const Text(
        'No shell profile is available. Add one to start a terminal.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-profile'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Add profile'),
        ),
      ],
    ),
  );
  return add ?? false;
}

/// Names every terminal a close would end; true to go on.
Future<bool> showCloseWarning(
  BuildContext context,
  List<CloseWarning> warnings,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('close-warning'),
      title: const Text('Close running terminals?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Closing ends their shells:'),
          // Closing the workbench can name every terminal: the list scrolls.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final w in warnings)
                    Text(
                      '${w.title}: ${w.reason}',
                      key: Key('close-warning-item-${w.paneId}'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('close-warning-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('close-warning-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The shell profiles: list, add, edit, remove, copy a built-in, set default.
/// [startWithNew] opens the editor on a blank profile at once.
Future<void> showProfilesDialog(
  BuildContext context,
  WorkbenchController controller, {
  bool startWithNew = false,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      ProfilesDialog(controller: controller, startWithNew: startWithNew),
);

class ProfilesDialog extends StatefulWidget {
  const ProfilesDialog({
    super.key,
    required this.controller,
    this.startWithNew = false,
  });

  final WorkbenchController controller;
  final bool startWithNew;

  @override
  State<ProfilesDialog> createState() => _ProfilesDialogState();
}

class _ProfilesDialogState extends State<ProfilesDialog> {
  final _name = TextEditingController();
  final _executable = TextEditingController();
  final _args = TextEditingController();
  final _cwd = TextEditingController();
  final _env = TextEditingController();

  /// The id of the profile being edited, or null while listing.
  String? _editing;

  /// Arguments or environment of the edited profile that one entry per line
  /// cannot show (an empty argument, a line break): kept unchanged on save,
  /// and their fields are read-only.
  List<String>? _keptArgs;
  Map<String, String>? _keptEnv;
  List<String> _issues = const [];
  String? _error;

  WorkbenchController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.startWithNew) _edit(null, newId: true);
    _controller.refreshProfiles();
  }

  @override
  void dispose() {
    for (final c in [_name, _executable, _args, _cwd, _env]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Shows the form: for [profile], for a copy of it ([newId]) or blank.
  void _edit(ShellProfile? profile, {bool newId = false}) {
    _name.text = profile == null
        ? ''
        : newId
        ? '${profile.name} copy'
        : profile.name;
    _executable.text = profile?.executable ?? '';
    final args = profile?.args ?? const <String>[];
    final env = profile?.env ?? const <String, String>{};
    _keptArgs = args.any((a) => a.isEmpty || _breaksLine(a)) ? args : null;
    _keptEnv =
        env.entries.any((e) => _breaksLine(e.key) || _breaksLine(e.value))
        ? env
        : null;
    _args.text = args.join('\n');
    _cwd.text = profile?.cwd ?? '';
    _env.text = [for (final e in env.entries) '${e.key}=${e.value}'].join('\n');
    _editing = newId || profile == null
        ? _controller.newProfileId()
        : profile.id;
    _issues = const [];
    _error = null;
  }

  static bool _breaksLine(String s) => s.contains('\n') || s.contains('\r');

  Future<void> _save() async {
    final id = _editing!;
    final issues = <String>[];
    final env = <String, String>{...?_keptEnv};
    final lines = _keptEnv == null ? _env.text.split('\n') : const <String>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final at = line.indexOf('=');
      if (at < 0) {
        issues.add('The environment line "$line" is not NAME=value.');
      } else {
        env[line.substring(0, at)] = line.substring(at + 1);
      }
    }
    final profile = ShellProfile(
      id: id,
      name: _name.text.trim(),
      executable: _executable.text.trim(),
      args:
          _keptArgs ??
          [
            for (final a in _args.text.split('\n'))
              if (a.isNotEmpty) a,
          ],
      cwd: _cwd.text.trim().isEmpty ? null : _cwd.text.trim(),
      env: env,
    );
    issues.addAll(
      ProfileDefinition(
        id: profile.id,
        name: profile.name,
        executable: profile.executable,
        args: profile.args,
        cwd: profile.cwd,
        env: profile.env,
      ).validate().map((i) => i.message),
    );
    if (issues.isNotEmpty) {
      setState(() => _issues = issues);
      return;
    }
    await _run(() async {
      await _controller.saveProfile(profile);
      _editing = null;
    });
  }

  /// Runs a host call; what the host refuses with is shown in the dialog.
  Future<void> _run(Future<void> Function() call) async {
    String? error;
    try {
      await call();
    } on RpcException catch (e) {
      error = e.message.isEmpty ? e.reason : '${e.reason}: ${e.message}';
    } on ConnectionClosedException {
      error = 'The host is gone.';
    }
    if (!mounted) return;
    setState(() {
      _error = error;
      if (error == null) _issues = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('profiles-dialog'),
      child: SizedBox(
        width: 560,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: _editing == null ? _list(context) : _form(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final list = _controller.profiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Shell profiles', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (list == null)
          const Text('Loading...')
        else if (list.profiles.isEmpty)
          const Text('No shell profile is available.'),
        for (final p in list?.profiles ?? const <ShellProfile>[])
          _row(p, isDefault: list!.defaultId == p.id),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(
              key: const Key('add-profile'),
              onPressed: () => setState(() => _edit(null)),
              child: const Text('Add profile'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(ShellProfile p, {required bool isDefault}) {
    return ListTile(
      dense: true,
      title: Text(isDefault ? '${p.name} (default)' : p.name),
      subtitle: Text(p.executable),
      trailing: Wrap(
        children: [
          if (!isDefault)
            TextButton(
              key: Key('set-default-${p.id}'),
              onPressed: () => _run(() => _controller.setDefaultProfile(p.id)),
              child: const Text('Set default'),
            ),
          if (p.isBuiltin)
            TextButton(
              key: Key('copy-${p.id}'),
              onPressed: () => setState(() => _edit(p, newId: true)),
              child: const Text('Copy as new profile'),
            )
          else ...[
            TextButton(
              key: Key('edit-${p.id}'),
              onPressed: () => setState(() => _edit(p)),
              child: const Text('Edit'),
            ),
            TextButton(
              key: Key('remove-${p.id}'),
              onPressed: () => _run(() => _controller.removeProfile(p.id)),
              child: const Text('Remove'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _form(BuildContext context) {
    Widget field(
      String key,
      String label,
      TextEditingController c, {
      int? lines,
      String? hint,
      bool kept = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key(key),
        controller: c,
        minLines: lines,
        maxLines: lines == null ? 1 : null,
        readOnly: kept,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: kept
              ? 'Holds an empty entry or a line break, which this editor '
                    'cannot show; kept unchanged.'
              : null,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Shell profile', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        field('profile-name', 'Name', _name),
        field('profile-executable', 'Executable', _executable),
        field(
          'profile-args',
          'Arguments, one per line',
          _args,
          lines: 2,
          kept: _keptArgs != null,
        ),
        field('profile-cwd', 'Working directory (optional)', _cwd),
        field(
          'profile-env',
          'Environment, NAME=value per line',
          _env,
          lines: 2,
          kept: _keptEnv != null,
        ),
        for (final issue in _issues)
          Text(
            issue,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() {
                _editing = null;
                _issues = const [];
                _error = null;
              }),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('profile-save'),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
