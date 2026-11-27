import 'dart:convert';
import 'dart:io';

import 'package:desktop/src/folder_picker.dart';
import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:flutter/material.dart';

import 'agent_harness.dart';
import 'windows_close_records.dart';
import 'windows_test_window.dart';

Future<void> main(List<String> args) async {
  final openPicker = args.length == 3 && args.last == '--open-picker';
  if (!Platform.isWindows || (args.length != 2 && !openPicker)) {
    throw ArgumentError(
      'Expected a listener port, scratch root and optional --open-picker',
    );
  }
  await _runFixture(int.parse(args[0]), Directory(args[1]), openPicker);
}

Future<void> _runFixture(int port, Directory root, bool openPicker) async {
  WidgetsFlutterBinding.ensureInitialized();
  final channel = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final harness = AgentHarness(root);
  final start = channel
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  Future<void> report(String event) async {
    channel.writeln(event);
    await channel.flush();
  }

  try {
    await AlacrittySurface.init();
    final windows = ownedTopLevelWindows(pid);
    final window = windows.entries
        .singleWhere((entry) => entry.value == runnerWindowClass)
        .key;
    runApp(
      harness.app(
        afterHostQuit: () async {
          _check(
            windowExists(window),
            'Window must still exist after host quit',
          );
          _check(
            readCloseRecords(root).exitKind == 'quit',
            'Host did not record its coordinated quit',
          );
          await report('host quit before window destruction');
        },
      ),
    );
    final workbench = await _afterFrame(() {
      final page = _find<WorkbenchPage>();
      return page?.controller.layout == null ? null : page!.controller;
    });
    if (openPicker) {
      final picking = const FileSelectorFolderPicker().pickFolder();
      final picker = await _afterFrame(() => nativeFolderPicker(window));
      cancelNativeFolderPicker(picker);
      _check(
        await picking == null,
        'Expected to cancel the fixture folder picker',
      );
      // Windows shells can differ. Ensure the same competing-window condition
      // on machines whose shell does not retain a WorkerW after the dialog.
      if (ownedTopLevelWindows(pid).length < 2) createAuxiliaryWindow();
      _check(
        ownedTopLevelWindows(pid).length >= 2,
        'Expected an auxiliary top-level window',
      );
    }
    await harness.configureWorkbench(workbench);
    _check(
      (await workbench.launchAgent()).kind.name == 'opened',
      'Scripted agent did not open',
    );
    final pane = workbench.layout!.focusedPane!;
    final agents = workbench.agents;
    final link = await _afterFrame(() {
      final link = agents.linkOf(pane);
      return link?.statusLabel == 'Idle' ? link : null;
    });
    link.promptFocus.requestFocus();
    await _afterFrame(() => link.promptFocus.hasFocus ? true : null);
    await agents.send(pane, 'make the fixture change');
    await _afterFrame(
      () => link.statusLabel == 'Waiting for approval' ? true : null,
    );
    final originalUnits = harness.agentUnits();
    _check(originalUnits.length == 1, 'Expected one pending agent unit');
    await report(
      'ready ${jsonEncode({'window': window, 'classes': ownedTopLevelWindows(pid).values.join(', ')})}',
    );
    _check(await start == 'close', 'Missing parent ready acknowledgement');

    postTitleBarClose(window);
    final warning = await _afterFrame(_warning);
    _check(
      _find<Text>(value: const Key('exit-host-lost')) == null,
      'Host was lost',
    );
    _check(
      _element(Key('exit-item-$pane')) != null,
      'Warning omitted the agent',
    );
    _check(
      link.statusLabel == 'Waiting for approval',
      'Permission was no longer pending',
    );
    await report('affected work shown');

    final cancel = _find<TextButton>(value: const Key('exit-cancel'))!;
    final focus = cancel.focusNode!;
    await _afterFrame(() => focus.hasFocus ? true : null);
    focus.unfocus();
    await _afterFrame(() => !focus.hasFocus ? true : null);
    postWindowClose(window);
    await _afterFrame(() => focus.hasFocus ? true : null);
    _check(
      identical(_warning(), warning),
      'Repeated Close replaced the warning',
    );
    _check(windowExists(window), 'Repeated Close destroyed the window');
    _check(
      link.statusLabel == 'Waiting for approval',
      'Repeated Close ended the pending turn',
    );
    await report('repeat focused the same warning');

    cancel.onPressed!();
    await _afterFrame(() => _warning() == null ? true : null);
    final remainingUnits = harness.agentUnits();
    _check(
      remainingUnits.length == 1 &&
          remainingUnits.single == originalUnits.single,
      'Cancel did not preserve the agent unit',
    );
    _check(
      link.statusLabel == 'Waiting for approval',
      'Cancel ended the pending turn',
    );
    await report('cancel preserved the unit');
    postTitleBarClose(window);
    final reopenedWarning = await _afterFrame(_warning);
    _check(
      !identical(reopenedWarning, warning),
      'New Close did not open a fresh warning',
    );
    _check(
      _element(Key('exit-item-$pane')) != null,
      'Fresh warning omitted the agent',
    );
    await report('new warning shown');
    _find<FilledButton>(value: const Key('exit-stop-all'))!.onPressed!();
    // The native runner, not the fixture, must destroy the window and exit.
  } catch (error, stack) {
    await report('fixture error: $error');
    debugPrintStack(stackTrace: stack);
    try {
      await harness.link?.quit();
    } on Object catch (cleanupError) {
      await report('fixture cleanup error: $cleanupError');
    }
    await channel.close();
    exit(1);
  }
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Element? _warning() {
  final dialog = _element(const Key('exit-dialog'));
  return (dialog?.widget as AlertDialog?)?.title is Text &&
          ((dialog!.widget as AlertDialog).title! as Text).data ==
              'Quit Kumiko?'
      ? dialog
      : null;
}

T? _find<T extends Widget>({Key? value}) =>
    _walk(
          WidgetsBinding.instance.rootElement,
          (w) => w is T && (value == null || w.key == value),
        )?.widget
        as T?;

Element? _element(Key key) =>
    _walk(WidgetsBinding.instance.rootElement, (w) => w.key == key);

Element? _walk(Element? root, bool Function(Widget) matches) {
  if (root == null) return null;
  if (matches(root.widget)) return root;
  Element? found;
  root.visitChildren((child) => found ??= _walk(child, matches));
  return found;
}

Future<T> _afterFrame<T extends Object>(T? Function() value) async {
  while (true) {
    await WidgetsBinding.instance.endOfFrame;
    final result = value();
    if (result != null) return result;
  }
}
