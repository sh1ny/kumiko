import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_test.dart' show agentHost;
import 'support/workbench_support.dart';

Future<void> editor(WidgetTester tester) async {
  await tester.tap(key('add-tab'));
  await tester.pumpAndSettle();
  await tester.tap(key('runtime-profiles'));
  await flush(tester);
}

void main() {
  uiTest('runtime editor validates argv profiles adds edits sets default and removes', (tester) async {
    final host = agentHost();
    await pumpRig(tester, host);
    await editor(tester);
    await tester.tap(key('add-runtime-profile'));
    await tester.pump();
    expect(find.textContaining('@agentclientprotocol/claude-agent-acp@<version>'), findsOneWidget);
    await tester.tap(key('runtime-profile-save'));
    await tester.pump();
    expect(find.text('The executable is required.'), findsOneWidget);
    await tester.enterText(key('runtime-profile-name'), 'My runtime');
    await tester.enterText(key('runtime-profile-executable'), 'node');
    await tester.enterText(key('runtime-profile-args'), '/path with spaces/adapter.js\n--setting="a b"');
    await tester.enterText(key('runtime-profile-env'), 'LOCAL_ONLY=value');
    await tester.tap(key('runtime-profile-save'));
    await flush(tester);
    final profile = host.runtimes.profiles.last;
    expect(profile.args, ['/path with spaces/adapter.js', '--setting="a b"']);
    expect(profile.env, {'LOCAL_ONLY': 'value'});
    expect(profile.runtimeKind, 'claude-code');
    await tester.tap(key('runtime-set-default-${profile.id}'));
    await flush(tester);
    expect(host.runtimes.defaultId, profile.id);
    await tester.tap(key('runtime-edit-${profile.id}'));
    await tester.pump();
    await tester.enterText(key('runtime-profile-name'), 'Edited runtime');
    await tester.tap(key('runtime-profile-save'));
    await flush(tester);
    expect(host.runtimes.profiles.last.name, 'Edited runtime');
    await tester.tap(key('runtime-remove-${profile.id}'));
    await flush(tester);
    expect(host.runtimes.profiles.any((p) => p.id == profile.id), isFalse);
  });

  uiTest('built-ins are read only; copy preserves unrepresentable exact argv and env', (tester) async {
    final host = agentHost();
    host.runtimes = const RuntimeListResult(profiles: [RuntimeProfile(
      id: 'builtin:claude', name: 'Claude Code', runtimeKind: 'claude-code', executable: '/node',
      args: ['', 'line\nbreak'], env: {'VALUE': 'one\ntwo'},
    )], defaultAvailable: true, defaultId: 'builtin:claude');
    await pumpRig(tester, host);
    await editor(tester);
    expect(key('runtime-edit-builtin:claude'), findsNothing);
    expect(key('runtime-remove-builtin:claude'), findsNothing);
    await tester.tap(key('runtime-copy-builtin:claude'));
    await tester.pump();
    expect(tester.widget<TextField>(key('runtime-profile-args')).readOnly, isTrue);
    expect(tester.widget<TextField>(key('runtime-profile-env')).readOnly, isTrue);
    await tester.tap(key('runtime-profile-save'));
    await flush(tester);
    final copy = host.runtimes.profiles.last;
    expect(copy.isBuiltin, isFalse);
    expect(copy.args, ['', 'line\nbreak']);
    expect(copy.env, {'VALUE': 'one\ntwo'});
    expect(copy.name, 'Claude Code copy');
  });
}
