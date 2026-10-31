/// Interactive real-adapter qualification. Fixtures are never evidence.
/// Run from the repository root; see --help. No provider action precedes consent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Root-only tooling intentionally consumes the workspace's public protocol API
// without adding a production dependency to the workspace root.
// ignore: depend_on_referenced_packages
import 'package:host_protocol/host_protocol.dart';

import '../packages/host/test/it/support/host_build.dart' as host_build;
import 'qualification_support.dart';

const _help = '''Usage (repository root):
  mise exec -- dart tool/qualify_claude_acp.dart --dry-run
  mise exec -- dart tool/qualify_claude_acp.dart --workspace <directory>
      [--profile-dir <existing Kumiko profile>] [--profile <runtime profile id>]
      [--evidence <existing evidence document>]

Requires FLUTTER_ROOT and the repository's Dart/native build prerequisites.
Builds the test-host bundle using the integration tests' locked builder.
Never uses the release host. No --yes or noninteractive real mode.
Default profile: disposable Kumiko profile; detects the installed adapter.
An explicit --profile-dir uses its profiles/settings without replacing them.
Dry-run refuses all real workspace/profile/evidence options; all its files are
owned temporary files, and its results are NOT qualification evidence.
Real mode may spend tokens and change workspace files. Separate approvals gate
provider actions, each prompt, permission choice, Stop, close, isolated
authentication startup, its separate minimal prompt and final evidence write.
Authentication isolation never signs out or copies the user's login files.
No production qualified-adapter list or authentication classifier is changed.
''';

Future<void> main(List<String> args) async {
  _Console? console;
  Directory? owned;
  try {
    final options = QualificationOptions.parse(args);
    if (options.help) {
      stdout.write(_help);
      return;
    }
    if (!options.dryRun && !stdin.hasTerminal) {
      throw StateError(
        'Real qualification requires an interactive terminal; no provider action was taken',
      );
    }
    console = _Console();
    owned = await Directory.systemTemp.createTemp('kumiko_acp_qualification_');
    final profile = options.profileDir == null
        ? Directory('${owned.path}/profile')
        : Directory(options.profileDir!).absolute;
    if (options.profileDir != null && !profile.existsSync()) {
      throw StateError('Explicit profile directory does not exist');
    }
    final workspace = options.dryRun
        ? await Directory('${owned.path}/workspace').create()
        : Directory(options.workspace!).absolute;
    if (!workspace.existsSync()) {
      throw StateError('Workspace directory does not exist');
    }
    final evidence = File(options.evidence).absolute;
    stdout.writeln(
      'Workspace: ${workspace.path}\nKumiko profile: ${profile.path}\n'
      'Evidence: ${options.dryRun ? 'NONE (fixture dry-run)' : evidence.path}',
    );
    if (!options.dryRun) {
      stdout.writeln(
        'This starts the real adapter through the TEST host. Prompts and tools may\n'
        'contact a provider, spend tokens, read private workspace files and change files.\n'
        'The selected profile and inherited login/configuration are used normally.\n'
        'Permission choices are yours; no automatic approvals. Transcript is displayed\n'
        'in bounded form, not saved in evidence. Authentication isolation asks again.',
      );
      if (!await console.approve(
        'Approve building the test host and these real provider/safety checks?',
      )) {
        throw StateError('Approval declined; no host/provider was started');
      }
    }
    final executable = await _buildTestHost();
    if (options.dryRun) {
      await _dryRun(executable, profile, workspace);
    } else {
      await _realRun(
        executable,
        profile,
        workspace,
        evidence,
        owned,
        options,
        console,
      );
    }
  } on Object catch (error) {
    stderr.writeln('FAILED: ${_failure(error)}');
    exitCode = 1;
  } finally {
    await console?.close();
    if (owned != null) await owned.delete(recursive: true);
  }
}

Future<String> _buildTestHost() async {
  final root = Directory.current;
  try {
    Directory.current = '${root.path}/packages/host';
    await host_build.buildTestHost();
    return host_build.testHostExecutable();
  } finally {
    Directory.current = root;
  }
}

class _Console {
  final _lines = StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  Future<String?> ask(String prompt) async {
    stdout.write('$prompt ');
    return await _lines.moveNext() ? _lines.current : null;
  }

  Future<bool> approve(String prompt) async => approvedAction(
    interactive: stdin.hasTerminal,
    answer: await ask('$prompt Type yes to approve:'),
  );
  Future<void> close() => _lines.cancel();
}

/// Fixed-size summaries, not a transcript or unbounded notification history.
class _SessionView {
  AgentState? state;
  int seq = -1;
  AgentStopResultParams? stop;
  AgentTurnEndedParams? turn;
  AgentExitedParams? exited;
  AgentCloseFailedParams? closeFailed;
  AgentPermissionResolvedParams? resolved;
  final permissions = <String, AgentPermissionRequestedParams>{};
  final kinds = <AgentEventKind>{};
  bool replayStarted = false;
  bool replayEnded = false;
  bool resumeNotice = false;
  Object? eventError;
  int displayed = 0;
}

class _Host {
  _Host(this.session) {
    _notifications = session.notifications.listen(_notification);
  }
  final HostSession session;
  final _views = <String, _SessionView>{};
  final _subscriptions = <StreamSubscription<List<int>>>[];
  final _closedSessions = <String>{};
  final _ready = Completer<void>();
  Completer<void> _changed = Completer<void>();
  late final StreamSubscription<HostNotification> _notifications;
  _SessionView view(String id) => _views.putIfAbsent(id, _SessionView.new);
  void changed() {
    final old = _changed;
    _changed = Completer<void>();
    old.complete();
  }

  void _notification(HostNotification n) {
    if (n.method == Method.cleanupState) {
      final cleanup = CleanupState.fromJson(n.params);
      if (!_ready.isCompleted && !cleanup.reconciling) {
        if (cleanup.unresolvedUnits == 0 && cleanup.unresolvedWorkspaces == 0) {
          _ready.complete();
        } else {
          _ready.completeError(
            StateError(
              'Cleanup has unresolved units/workspaces; qualification cannot bypass it',
            ),
          );
        }
      }
    }
    final id = n.params['sessionId'];
    if (id is! String || !n.method.startsWith('agent/')) return;
    final v = view(id);
    switch (n.method) {
      case Method.agentState:
        final state = AgentStateParams.fromJson(n.params);
        if (state.seq > v.seq) {
          v.seq = state.seq;
          v.state = state.state;
        }
      case Method.agentPermissionRequested:
        final permission = AgentPermissionRequestedParams.fromJson(n.params);
        v.permissions[permission.requestId] = permission;
        stdout.writeln(
          'Permission offered: ${_display(permission.title)}; use permission command to choose.',
        );
      case Method.agentPermissionResolved:
        v.resolved = AgentPermissionResolvedParams.fromJson(n.params);
        v.permissions.remove(v.resolved!.requestId);
      case Method.agentStopResult:
        v.stop = AgentStopResultParams.fromJson(n.params);
        stdout.writeln(
          'Stop outcome: ${v.stop!.outcome.name}; late=${v.stop!.late}; '
          'stopReason=${_display(v.stop!.stopReason ?? 'unspecified')}; '
          'message=${_display(v.stop!.message ?? '')}',
        );
      case Method.agentTurnEnded:
        v.turn = AgentTurnEndedParams.fromJson(n.params);
        stdout.writeln(
          'Turn ended: ${v.turn!.error ?? v.turn!.stopReason ?? 'unspecified'}'
          '${v.turn!.message == null ? '' : ': ${_display(v.turn!.message!)}'}',
        );
      case Method.agentExited:
        v.exited = AgentExitedParams.fromJson(n.params);
        stdout.writeln(
          'Agent exited: ${v.exited!.reason.name}; status=${v.exited!.status}; '
          'error=${v.exited!.error}; resumeReason=${v.exited!.resumeReason}; '
          'message=${_display(v.exited!.message ?? '')}',
        );
      case Method.agentCloseFailed:
        v.closeFailed = AgentCloseFailedParams.fromJson(n.params);
        stdout.writeln(
          'Agent close failed: reason=${_display(v.closeFailed!.reason)}; '
          'message=${_display(v.closeFailed!.message ?? '')}',
        );
    }
    changed();
  }

  static Future<_Host> start(
    String executable,
    Directory profile, {
    (String, String)? candidate,
    List<String> extras = const [],
    bool fixture = false,
  }) async {
    final host = _Host(
      await HostLauncher(
        executable: executable,
        profileDir: profile.path,
        capabilities: {Capability.workbench, Capability.agent},
        environment: {
          // Always override an inherited test override, including discovery and
          // the unqualified run. No environment value can change production data.
          'KUMIKO_TEST_QUALIFIED_ADAPTERS': jsonEncode(
            candidate == null
                ? []
                : [
                    [candidate.$1, candidate.$2, extras],
                  ],
          ),
          if (fixture) 'KUMIKO_TEST_RUNTIME_PATH': '',
          if (fixture) 'KUMIKO_TEST_SHELL_PATH': '',
        },
      ).start(),
    );
    try {
      await host._ready.future.timeout(const Duration(seconds: 60));
      return host;
    } on Object {
      await host.dispose();
      rethrow;
    }
  }

  Future<Json> call(String method, [Json params = const {}]) async =>
      (await session.connection.request(method, params)) as Json;
  Future<void> wait(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 75),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final v in _views.values) {
        if (v.eventError != null) {
          throw StateError('Event decode failed: ${v.eventError}');
        }
      }
      if (predicate()) return;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Expected host observation did not arrive',
          timeout,
        );
      }
      await Future.any([
        _changed.future,
        session.lost.then<void>((loss) => throw StateError('Host lost: $loss')),
      ]).timeout(remaining);
    }
  }

  Future<String> workspace(Directory workspace) async =>
      WorkspaceOpenResult.fromJson(
        await call(
          Method.workspaceOpen,
          WorkspaceOpenParams(workspace.path).toJson(),
        ),
      ).workspace.id;
  Future<AgentStartResult> startAgent(String workspace, String profile) async =>
      AgentStartResult.fromJson(
        await call(
          Method.agentStart,
          AgentStartParams(
            workspaceId: workspace,
            runtimeProfileId: profile,
          ).toJson(),
        ),
      );
  Future<void> attach(String id, int channel) async {
    final decoder = AgentEventDecoder();
    final v = view(id);
    final stream = session.connection.attachInbound(
      channel,
      grantInitial: false,
    );
    _subscriptions.add(
      stream.listen(
        (bytes) {
          try {
            for (final event in decoder.add(bytes)) {
              v.kinds.add(event.kind);
              if (event.kind == AgentEventKind.replay) {
                if (event.phase == AgentReplayPhase.start) {
                  v.replayStarted = true;
                }
                if (event.phase == AgentReplayPhase.end) v.replayEnded = true;
              }
              if (event.kind == AgentEventKind.notice &&
                  event.text!.toLowerCase().contains(
                    'earlier messages not shown',
                  )) {
                v.resumeNotice = true;
              }
              if (v.displayed < 16384) {
                final text =
                    '${event.kind.name}: ${_display(event.text ?? event.title ?? event.stopReason ?? event.phase?.name ?? '')}';
                v.displayed += text.length;
                stdout.writeln(text);
              }
            }
          } on Object catch (error) {
            v.eventError = error;
          }
          changed();
        },
        onError: (Object error) {
          v.eventError = error;
          changed();
        },
        onDone: () {
          try {
            decoder.close();
          } on Object catch (error) {
            v.eventError = error;
          }
          changed();
        },
      ),
    );
    await call(Method.agentAttach, AgentSessionParams(id).toJson());
    session.connection.grantInitial(channel);
  }

  Future<void> prompt(String id, String text) async {
    final v = view(id);
    v.stop = null;
    v.turn = null;
    await call(
      Method.agentPrompt,
      AgentPromptParams(sessionId: id, text: text).toJson(),
    );
  }

  Future<void> permission(
    String id,
    AgentPermissionRequestedParams request,
    String optionId,
  ) async {
    if (!request.options.any((o) => o.optionId == optionId)) {
      throw StateError('Option was not offered');
    }
    await call(
      Method.agentPermissionReply,
      AgentPermissionReplyParams(
        sessionId: id,
        requestId: request.requestId,
        optionId: optionId,
      ).toJson(),
    );
    await wait(() => view(id).resolved?.requestId == request.requestId);
  }

  Future<AgentStopResultParams> stop(String id) async {
    view(id).stop = null;
    await call(Method.agentStop, AgentSessionParams(id).toJson());
    await wait(
      () => view(id).stop != null,
      timeout: const Duration(seconds: 20),
    );
    return view(id).stop!;
  }

  Future<void> closeAgent(String id) async {
    if (_closedSessions.contains(id)) return;
    view(id).closeFailed = null;
    await call(Method.agentClose, AgentSessionParams(id).toJson());
    await wait(() => view(id).exited != null || view(id).closeFailed != null);
    final failure = view(id).closeFailed;
    if (failure != null) {
      throw RpcException(failure.reason, failure.message ?? '');
    }
    if (view(id).exited!.reason != AgentExitReason.closed) {
      throw StateError(
        'Agent did not report closed: ${view(id).exited!.reason}',
      );
    }
    _closedSessions.add(id);
  }

  Future<void> dispose() async {
    // HostSession.quit is the ordinary desktop-disconnect cleanup path, also
    // when the user declines an individual close. It never asserts consent.
    try {
      final result = await session.quit();
      if (result.timedOut || result.exitCode != 0) {
        throw StateError(
          'Test host cleanup failed: exit=${result.exitCode}, timeout=${result.timedOut}',
        );
      }
    } finally {
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      await _notifications.cancel();
    }
  }
}

String _display(String value) => qualificationDisplay(value);
String _failure(Object error) => switch (error) {
  RpcException() => qualificationRpcDiagnostic(error),
  HostStartException() =>
    'host start kind=${error.kind.name}; '
        'hostExitCode=${error.hostExitCode}; ${qualificationRpcDiagnostic(RpcException(error.reason ?? error.kind.name, error.message, error.data))}',
  _ => '$error',
};
void _require(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

(String, String) _identity(AgentAdapter adapter) {
  final pair = (adapter.name, adapter.version);
  validateQualificationIdentity(pair);
  return pair;
}

Future<void> _dryRun(
  String executable,
  Directory profile,
  Directory workspace,
) async {
  stdout.writeln(
    'FIXTURE ONLY: no provider calls, no qualification evidence, no auth classifier.',
  );
  final script = File('${workspace.path}/agent.script.json');
  await script.writeAsString(
    jsonEncode({
      'agentInfo': {'name': 'qualification-fixture', 'version': 'test-only'},
      'agentCapabilities': {
        'loadSession': true,
        'sessionCapabilities': {'resume': <String, Object?>{}},
      },
      'prompt': [
        {
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'Fixture stream'},
          },
        },
        {
          'update': {
            'sessionUpdate': 'tool_call',
            'toolCallId': 'fixture-tool',
            'title': 'Fixture action',
            'kind': 'edit',
            'status': 'pending',
          },
        },
        {
          'permission': {
            'toolCall': {
              'toolCallId': 'fixture-tool',
              'title': 'Fixture permission',
            },
            'options': [
              {
                'optionId': 'fixture-allow-once',
                'name': 'Fixture allow',
                'kind': 'allow_once',
              },
            ],
          },
        },
        {
          'update': {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'fixture-tool',
            'status': 'completed',
          },
        },
        {'waitCancel': true},
      ],
      'load': [
        {
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': 'Fixture replay user'},
          },
        },
        {
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'Fixture replay agent'},
          },
        },
      ],
    }),
  );
  const runtime = 'qualification-fixture';
  const candidate = ('qualification-fixture', 'test-only');
  late String id;
  var host = await _Host.start(executable, profile, fixture: true);
  try {
    final workspaceId = await host.workspace(workspace);
    await host.call(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: runtime,
          name: 'Qualification fixture (not evidence)',
          runtimeKind: 'claude-code',
          executable: executable,
          args: ['--test-fixture', 'acp-agent', '--script', script.path],
        ),
      ).toJson(),
    );
    final started = await host.startAgent(workspaceId, runtime);
    _require(
      _identity(started.adapter) == candidate,
      'Fixture identity changed',
    );
    _require(
      !started.capabilities.contains('load') &&
          !started.capabilities.contains('resume'),
      'Unlisted fixture claimed extras',
    );
    id = started.sessionId;
    await host.attach(id, started.eventChannel);
    await host.prompt(id, 'Fixture prompt only');
    final v = host.view(id);
    await host.wait(
      () =>
          v.permissions.isNotEmpty &&
          v.kinds.contains(AgentEventKind.tool) &&
          v.kinds.contains(AgentEventKind.agentText),
    );
    final request = v.permissions.values.single;
    await host.permission(id, request, request.options.single.optionId);
    _require(
      v.resolved!.outcome == AgentPermissionOutcome.selected,
      'Fixture permission was not selected',
    );
    await host.wait(() => v.kinds.contains(AgentEventKind.toolUpdate));
    _require(
      (await host.stop(id)).outcome == AgentStopOutcome.stopped,
      'Fixture cancel not observed as stopped',
    );
    await host.wait(() => v.state == AgentState.idle);
    // A second live turn proves close while waiting for an actual permission,
    // rather than treating an idle close after Stop as that safety observation.
    await host.prompt(id, 'Second fixture turn for active close only');
    await host.wait(
      () => v.state == AgentState.waitingApproval && v.permissions.isNotEmpty,
    );
    await host.closeAgent(id);
    final records = AgentRecordsResult.fromJson(
      await host.call(Method.agentRecords, AgentRecordsParams([id]).toJson()),
    );
    _require(
      records.records[id]?.known == true,
      'Closed fixture record missing',
    );
  } finally {
    await host.dispose();
  }
  for (final extras in [
    const ['load', 'resume'],
    const ['resume'],
    const <String>[],
  ]) {
    host = await _Host.start(
      executable,
      profile,
      candidate: extras.isEmpty ? null : candidate,
      extras: extras,
      fixture: true,
    );
    try {
      if (extras.isEmpty) {
        try {
          await host.call(
            Method.agentContinue,
            AgentSessionParams(id).toJson(),
          );
          throw StateError('Unqualified continuation was not refused');
        } on RpcException catch (error) {
          _require(
            error.reason == ErrorCode.resumeUnavailable &&
                error.data['resumeReason'] == 'not-qualified',
            'Wrong no-override refusal: ${qualificationRpcDiagnostic(error)}',
          );
        }
        stdout.writeln(
          'FIXTURE no override -> resume-unavailable/not-qualified observed',
        );
        continue;
      }
      final result = AgentContinueResult.fromJson(
        await host.call(Method.agentContinue, AgentSessionParams(id).toJson()),
      );
      final expected = extras.contains('load')
          ? AgentContinueMode.load
          : AgentContinueMode.resume;
      _require(
        _identity(result.adapter) == candidate && result.mode == expected,
        'Wrong continuation identity/mode',
      );
      await host.attach(id, result.eventChannel);
      final v = host.view(id);
      await host.wait(
        () =>
            v.state == AgentState.idle &&
            (expected == AgentContinueMode.load
                ? v.replayEnded
                : v.resumeNotice),
      );
      _require(
        expected != AgentContinueMode.load ||
            (v.replayStarted && v.kinds.contains(AgentEventKind.user)),
        'Load did not replay actual history',
      );
      await host.closeAgent(id);
      stdout.writeln(
        'FIXTURE ${extras.join('+')} -> ordinary ${expected.name} observed',
      );
    } finally {
      await host.dispose();
    }
  }
  await _dryRunAuth(executable, profile, workspace);
  stdout.writeln('DRY-RUN PASSED (fixture only; no evidence written)');
}

Future<AgentTurnEndedParams> _waitAuthTurn(_Host host, String id) async {
  final v = host.view(id);
  await host.wait(
    () => v.turn != null || v.exited != null || v.permissions.isNotEmpty,
    timeout: const Duration(seconds: 75),
  );
  if (v.turn == null) {
    throw StateError(
      v.permissions.isNotEmpty
          ? 'Permission requested; no automatic option is selected'
          : 'Agent exited before a turn outcome arrived',
    );
  }
  return v.turn!;
}

/// Scripted approvals apply only to owned fixture profiles, never real mode.
Future<void> _dryRunAuth(
  String executable,
  Directory profile,
  Directory workspace,
) async {
  const nativeMessage = 'Fixture native refusal (NOT real auth evidence)';
  for (final scenario in ['new-error', 'prompt-error', 'success', 'decline']) {
    final script = File('${workspace.path}/auth-$scenario.script.json');
    await script.writeAsString(
      jsonEncode({
        'agentInfo': {'name': 'qualification-fixture', 'version': 'test-only'},
        if (scenario == 'new-error' || scenario == 'prompt-error')
          'errors': {
            (scenario == 'new-error' ? 'session/new' : 'session/prompt'): {
              'code': -32123,
              'message': nativeMessage,
            },
          },
        'prompt': [
          {
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': 'OK'},
            },
          },
        ],
      }),
    );
    final runtime = 'qualification-auth-fixture-$scenario';
    final host = await _Host.start(executable, profile, fixture: true);
    var saved = false;
    AgentStartResult? started;
    var prompted = false;
    var waited = false;
    final reports = <String>[];
    try {
      final workspaceId = await host.workspace(workspace);
      await host.call(
        Method.runtimeSave,
        RuntimeSaveParams(
          RuntimeProfile(
            id: runtime,
            name: 'Fixture auth path (not evidence)',
            runtimeKind: 'claude-code',
            executable: executable,
            args: ['--test-fixture', 'acp-agent', '--script', script.path],
          ),
        ).toJson(),
      );
      saved = true;
      final observation = await runQualificationAuthProbe(
        fixture: true,
        start: () async {
          started = await host.startAgent(workspaceId, runtime);
        },
        attach: () => host.attach(started!.sessionId, started!.eventChannel),
        approve: (_) async => scenario != 'decline',
        prompt: (text) async {
          _require(text == qualificationAuthPrompt, 'Fixture prompt changed');
          prompted = true;
          await host.prompt(started!.sessionId, text);
        },
        waitForTurn: () {
          waited = true;
          return _waitAuthTurn(host, started!.sessionId);
        },
        report: (message) {
          reports.add(message);
          stdout.writeln('FIXTURE $scenario: $message');
        },
      );
      _require(observation == null, 'Fixture auth row must never be evidence');
      final expectPrompt = scenario == 'prompt-error' || scenario == 'success';
      _require(
        prompted == expectPrompt && waited == expectPrompt,
        'Fixture $scenario did not use the expected ordinary prompt/turn path',
      );
      if (scenario == 'new-error' || scenario == 'prompt-error') {
        _require(
          reports.any((message) => message.contains(nativeMessage)) &&
              reports.any((message) => message.contains('FIXTURE ONLY')),
          'Fixture $scenario lost native diagnostics or evidence exclusion',
        );
      }
      if (scenario == 'prompt-error') {
        final turn = host.view(started!.sessionId).turn!;
        _require(
          turn.nativeCode == -32123 &&
              turn.nativeMessage == nativeMessage &&
              !turn.nativeMessageTruncated,
          'Fixture prompt failure did not arrive as an exact native turn result',
        );
      }
      if (scenario == 'success') {
        _require(
          reports.any((message) => message.contains('completed successfully')),
          'Fixture success was not reported honestly',
        );
      }
      if (started != null) await host.closeAgent(started!.sessionId);
      stdout.writeln(
        'FIXTURE isolated $scenario observed; no evidence recorded',
      );
    } finally {
      try {
        if (saved) {
          await host.call(
            Method.runtimeRemove,
            RuntimeRemoveParams(runtime).toJson(),
          );
        }
      } finally {
        await host.dispose();
      }
    }
  }
}

Future<void> _confirm(
  _Console console,
  Map<String, QualificationObservation> rows,
  String item,
  bool passed,
  String detail, {
  String authCode = '',
  String authMessage = '',
}) async {
  stdout.writeln('$item: proposed ${passed ? 'pass' : 'fail'}; $detail');
  if (await console.approve(
    'Did you personally verify this exact result for $item?',
  )) {
    rows[item] = QualificationObservation.confirmed(
      passed: passed,
      confirmed: true,
      authCode: authCode,
      authMessage: authMessage,
    );
  } else {
    stdout.writeln(
      '$item remains unrecorded (not a pass or an invented failure).',
    );
  }
}

Future<bool> _closeConfirmed(_Host host, String id, _Console console) async {
  if (!await console.approve(
    'Close this agent session now (ends any running work)?',
  )) {
    return false;
  }
  await host.closeAgent(id);
  return true;
}

Future<void> _realRun(
  String executable,
  Directory profile,
  Directory workspace,
  File evidence,
  Directory owned,
  QualificationOptions options,
  _Console console,
) async {
  final os = Platform.operatingSystem;
  qualificationItems(os);
  final original = await evidence.readAsString();
  final rows = <String, QualificationObservation>{};
  var host = await _Host.start(executable, profile);
  late RuntimeProfile selected;
  late String id;
  late (String, String) candidate;
  var closedConfirmed = false;
  try {
    final list = RuntimeListResult.fromJson(
      await host.call(Method.runtimeList),
    );
    stdout.writeln(
      'Available runtime profiles (no environment values displayed):',
    );
    for (final p in list.profiles) {
      stdout.writeln(
        '  ${p.id}: ${_display(p.name)}${p.id == list.defaultId ? ' (default)' : ''}',
      );
    }
    final chosen =
        options.profile ??
        await console.ask(
          'Runtime profile id (blank = configured default; no fallback):',
        );
    selected = selectQualificationProfile(
      list,
      chosen == null || chosen.isEmpty ? null : chosen,
    );
    stdout.writeln(
      'Selected runtime profile: ${selected.id} (${_display(selected.name)})',
    );
    if (!await console.approve(
      'Approve real provider execution with this selected runtime profile?',
    )) {
      throw StateError('Runtime execution declined');
    }
    final workspaceId = await host.workspace(workspace);
    final started = await host.startAgent(workspaceId, selected.id);
    id = started.sessionId;
    candidate = _identity(started.adapter);
    stdout.writeln(
      'Actual initialized identity: ${candidate.$1} ${candidate.$2}',
    );
    await host.attach(id, started.eventChannel);
    await _confirm(
      console,
      rows,
      'launch',
      true,
      'ordinary start and attach succeeded',
    );
    final v = host.view(id);
    var prompted = false;
    var stopTried = false;
    var permissionTried = false;
    stdout.writeln(
      'Commands: prompt, permission, stop, close.\n'
      'Use a prompt that actually produces streaming, tool activity and a permission.\n'
      'Native settings may omit permissions. Those cannot be recorded as passing.\n'
      'For close-with-confirmation, close during a second running/waiting turn after Stop.',
    );
    while (!closedConfirmed) {
      final command = (await console.ask('qualification>'))?.trim();
      if (command == null) {
        throw StateError(
          'Input ended; unfinished observations were not written',
        );
      }
      switch (command) {
        case 'prompt':
          final text = await console.ask(
            'Prompt (sent to real provider, not saved by this tool):',
          );
          if (text == null || text.isEmpty) break;
          if (!await console.approve(
            'Send this prompt to the real provider (tokens and workspace changes possible)?',
          )) {
            break;
          }
          await host.prompt(id, text);
          prompted = true;
        case 'permission':
          if (v.permissions.isEmpty) {
            stdout.writeln('No pending permission was offered.');
            break;
          }
          final request = v.permissions.values.first;
          stdout.writeln(
            '${_display(request.title)}\n${_display(request.preview ?? '')}',
          );
          for (var i = 0; i < request.options.length; i++) {
            stdout.writeln(
              '${i + 1}: ${_display(request.options[i].name)} (${_display(request.options[i].kind)})',
            );
          }
          final choice = int.tryParse(
            await console.ask(
                  'Choose offered option number (blank = do not answer):',
                ) ??
                '',
          );
          if (choice == null || choice < 1 || choice > request.options.length) {
            break;
          }
          final option = request.options[choice - 1];
          if (!await console.approve(
            'Send the offered choice ${_display(option.name)} (${_display(option.kind)})?',
          )) {
            break;
          }
          await host.permission(id, request, option.optionId);
          permissionTried = true;
          await _confirm(
            console,
            rows,
            'permission request',
            v.resolved?.outcome == AgentPermissionOutcome.selected,
            'actual offered opaque option answered; outcome=${v.resolved?.outcome.name}',
          );
        case 'stop':
          if (!await console.approve(
            'Send Stop to this agent now (pending permissions will be cancelled)?',
          )) {
            break;
          }
          final result = await host.stop(id);
          stopTried = true;
          await _confirm(
            console,
            rows,
            'Stop',
            result.outcome == AgentStopOutcome.stopped,
            'actual host outcome=${result.outcome.name}; late=${result.late} (not relabelled)',
          );
        case 'close':
          final active =
              v.state == AgentState.running ||
              v.state == AgentState.waitingApproval ||
              v.state == AgentState.stopping;
          closedConfirmed = await _closeConfirmed(host, id, console);
          if (closedConfirmed) {
            await _confirm(
              console,
              rows,
              'close with confirmation',
              active,
              'explicit close approved; agent exited closed; active-at-close=$active',
            );
          }
        default:
          stdout.writeln('Use prompt, permission, stop or close.');
      }
    }
    if (prompted) {
      await _confirm(
        console,
        rows,
        'streaming',
        v.kinds.contains(AgentEventKind.agentText),
        'agentText events observed=${v.kinds.contains(AgentEventKind.agentText)}',
      );
      await _confirm(
        console,
        rows,
        'tool activity',
        v.kinds.contains(AgentEventKind.tool),
        'tool events observed=${v.kinds.contains(AgentEventKind.tool)}',
      );
      if (!permissionTried) {
        await _confirm(
          console,
          rows,
          'permission request',
          false,
          'prompt tried, no permission was answered',
        );
      }
    }
    if (!stopTried) {
      stdout.writeln('Stop was untried; no result will be invented.');
    }
    final records = AgentRecordsResult.fromJson(
      await host.call(Method.agentRecords, AgentRecordsParams([id]).toJson()),
    );
    _require(records.records[id]?.known == true, 'Saved record is missing');
  } finally {
    await host.dispose();
  }

  for (final extras in [
    const ['load', 'resume'],
    const ['resume'],
  ]) {
    final item = extras.contains('load') ? 'load' : 'resume';
    host = await _Host.start(
      executable,
      profile,
      candidate: candidate,
      extras: extras,
    );
    try {
      stdout.writeln(
        'Candidate test-host override: ${candidate.$1} ${candidate.$2}: $extras',
      );
      if (!await console.approve(
        'Run ordinary Continue for $item (may contact provider)?',
      )) {
        continue;
      }
      try {
        final result = AgentContinueResult.fromJson(
          await host.call(
            Method.agentContinue,
            AgentSessionParams(id).toJson(),
          ),
        );
        _require(
          _identity(result.adapter) == candidate,
          'Initialized identity changed; candidate evidence cannot be combined',
        );
        final expected = item == 'load'
            ? AgentContinueMode.load
            : AgentContinueMode.resume;
        _require(
          result.mode == expected,
          'Host selected ${result.mode.name}, expected $item',
        );
        await host.attach(id, result.eventChannel);
        final v = host.view(id);
        await host.wait(
          () =>
              (v.state == AgentState.idle &&
                  (item == 'load' ? v.replayEnded : v.resumeNotice)) ||
              v.exited != null,
        );
        final passed =
            v.exited == null &&
            (item == 'load'
                ? v.replayStarted && v.replayEnded
                : v.resumeNotice);
        await _confirm(
          console,
          rows,
          item,
          passed,
          'ordinary Continue=${result.mode.name}; replay=${v.replayStarted}/${v.replayEnded}; resume notice=${v.resumeNotice}; exit=${v.exited?.reason.name}',
        );
        if (v.exited == null && !await _closeConfirmed(host, id, console)) {
          throw StateError(
            'Close declined; host-disconnect cleanup will run; remaining observations not written',
          );
        }
      } on RpcException catch (error) {
        stdout.writeln('Continue error: ${qualificationRpcDiagnostic(error)}');
        await _confirm(
          console,
          rows,
          item,
          false,
          'ordinary Continue failed: ${error.reason}',
        );
      }
    } finally {
      await host.dispose();
    }
  }
  await _authObservation(
    executable,
    profile,
    workspace,
    owned,
    selected,
    console,
    rows,
  );
  if (os == 'macos') {
    stdout.writeln(
      'Launch Kumiko yourself from Finder or the Dock; detect the built-in profile and launch it.',
    );
    final result = await console.ask(
      'Finder/Dock result (pass/fail/blank if untried):',
    );
    if (result == 'pass' || result == 'fail') {
      await _confirm(
        console,
        rows,
        finderQualificationItem,
        result == 'pass',
        'your actual Finder/Dock run',
      );
    }
  }
  if (os != 'windows') {
    for (final item in qualificationItems(os)) {
      rows.putIfAbsent(item, () => const QualificationObservation.unproven());
    }
  }
  final missing = qualificationItems(os)
      .where((item) => !rows.containsKey(item))
      .toList();
  if (missing.isNotEmpty) {
    throw StateError(
      'No evidence written: unrecorded $os observations: ${missing.join(', ')}. '
      'Real authentication and user confirmations cannot be fabricated.',
    );
  }
  final updated = mergeQualificationEvidence(
    original,
    adapter: candidate,
    os: os,
    observations: rows,
    fixture: false,
    date: DateTime.now(),
  );
  stdout.writeln(
    'Proposed evidence for exact ${candidate.$1} ${candidate.$2}, OS=$os, path=${evidence.path}:',
  );
  for (final entry in rows.entries) {
    stdout.writeln('  ${entry.key}: user/${entry.value.result}');
  }
  stdout.writeln(
    'Other recorded OS results are retained. No qualified list or classifier is updated.',
  );
  final answer = await console.ask(
    'Write these exact confirmed results to that evidence path? Type yes:',
  );
  if (!mayWriteEvidence(
    fixture: false,
    interactive: stdin.hasTerminal,
    answer: answer,
  )) {
    stdout.writeln('Evidence write declined; nothing written.');
    return;
  }
  // Refuse concurrent edits rather than overwrite another OS's observations.
  if (await evidence.readAsString() != original) {
    throw StateError(
      'Evidence changed during qualification; no write performed',
    );
  }
  await evidence.writeAsString(updated, flush: true);
  stdout.writeln(
    'Evidence written. Task10.2 classifier and10.3 claims remain separate user/parent work.',
  );
}

Future<void> _authObservation(
  String executable,
  Directory profile,
  Directory workspace,
  Directory owned,
  RuntimeProfile selected,
  _Console console,
  Map<String, QualificationObservation> rows,
) async {
  final config = await Directory('${owned.path}/isolated-claude-config')
      .create();
  final env = isolatedAuthEnvironment(
    selected.env,
    Platform.environment,
    config.path,
  );
  stdout.writeln(
    'SEPARATE AUTHENTICATION OBSERVATION:\n'
    'A temporary clone of runtime profile ${selected.id} will use:\n'
    'CLAUDE_CONFIG_DIR=${config.path}\n'
    'Present ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN\n'
    'values are blanked only in this clone. ANTHROPIC_BASE_URL is unchanged.\n'
    'No credentials/config files are copied; no sign-out/global env changes.\n'
    'Other provider or OS credentials may still authenticate; success is NOT an\n'
    'auth-required pass. This attempt may contact a provider and spend tokens.\n'
    'If startup succeeds, a separate approval offers exactly:\n'
    '$qualificationAuthPrompt\n'
    'No permission option will be selected automatically; the turn deadline is 75 seconds.',
  );
  if (!await console.approve(
    'Approve this exact isolated session environment and provider/auth check?',
  )) {
    stdout.writeln(
      'Auth isolation declined; auth-required remains unrecorded.',
    );
    return;
  }
  final host = await _Host.start(executable, profile);
  final cloneId = 'qualification-auth-${DateTime.now().microsecondsSinceEpoch}';
  var saved = false;
  try {
    final list = RuntimeListResult.fromJson(
      await host.call(Method.runtimeList),
    );
    _require(
      !list.profiles.any((p) => p.id == cloneId),
      'Temporary profile identity collision',
    );
    await host.call(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: cloneId,
          name: 'Temporary isolated qualification auth observation',
          runtimeKind: selected.runtimeKind,
          executable: selected.executable,
          args: selected.args,
          env: env,
        ),
      ).toJson(),
    );
    saved = true;
    final workspaceId = await host.workspace(workspace);
    AgentStartResult? started;
    final observation = await runQualificationAuthProbe(
      fixture: false,
      start: () async {
        started = await host.startAgent(workspaceId, cloneId);
      },
      attach: () => host.attach(started!.sessionId, started!.eventChannel),
      approve: console.approve,
      prompt: (text) => host.prompt(started!.sessionId, text),
      waitForTurn: () => _waitAuthTurn(host, started!.sessionId),
      report: stdout.writeln,
    );
    if (observation != null) rows['auth-required observed'] = observation;
    if (started != null &&
        !await _closeConfirmed(host, started!.sessionId, console)) {
      stdout.writeln(
        'Close declined; ordinary host-disconnect cleanup follows.',
      );
    }
  } finally {
    try {
      if (saved) {
        await host.call(
          Method.runtimeRemove,
          RuntimeRemoveParams(cloneId).toJson(),
        );
      }
    } finally {
      await host.dispose();
    }
  }
}
