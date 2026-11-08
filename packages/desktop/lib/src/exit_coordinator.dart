import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'exit_dialog.dart';
import 'terminal/terminal_controller.dart';
import 'workbench_controller.dart';

/// Where a cancellable quit is (design D1): `idle`, `collecting` the affected
/// items, `deciding` in the exit dialog, `quitting` once the decision is made.
enum ExitPhase { idle, collecting, deciding, quitting }

enum ExitItemKind { agent, terminal }

/// One row of the exit dialog: a pane with work an exit would end or text it
/// would lose.
class ExitItem {
  const ExitItem({
    required this.paneId,
    required this.title,
    required this.kind,
    this.work,
    this.draft,
    this.stopping = false,
    this.failure,
  });

  final String paneId;
  final String title;
  final ExitItemKind kind;

  /// What is running: the agent's state, or the terminal's programs.
  final String? work;

  /// *Draft not saved: `<reason>`* when the composer's text is not stored.
  final String? draft;

  /// **Stop** was chosen and the unit has not ended yet.
  final bool stopping;

  /// Why the Stop failed: the item stays, *cleanup unresolved*, without Stop.
  final String? failure;

  String get kindLabel =>
      kind == ExitItemKind.agent ? 'Agent session' : 'Terminal';

  bool get canStop => work != null && !stopping && failure == null;

  /// The item has processes an exit would end (or could not end).
  bool get hasProcess => work != null || stopping || failure != null;
}

enum _Choice { cancel, quit }

/// The whole-app exit (design D1, app-exit): collects the affected agents,
/// terminals and unsaved drafts, asks in one dialog when there are any,
/// follows their live state, and finally flushes, tells the host it is a quit
/// and lets the window close. The layout is never touched by an exit: **Stop**
/// ends a unit and keeps its pane.
class ExitCoordinator extends ChangeNotifier {
  ExitCoordinator({
    required this.workbench,
    required this.navigatorKey,
    required this.quit,
    this.pollInterval = const Duration(seconds: 1),
  });

  final WorkbenchController workbench;

  /// The navigator the exit dialog is shown on.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Ends the host connection (after `app/quit`); the host ends every unit.
  final Future<void> Function() quit;

  /// How often terminals are asked again while the dialog is open.
  final Duration pollInterval;

  ExitPhase _phase = ExitPhase.idle;
  Map<String, String> _terminalWork = const {};
  final Set<String> _stopping = {};
  final Map<String, String> _failed = {};
  bool _hostWasConnected = false;
  bool _hostLost = false;
  bool _finalChecking = false;

  /// The panes whose unsaved drafts the user's bulk choice named as lost.
  Set<String> _accepted = const {};
  bool _disposed = false;
  Future<void>? _reading;
  Timer? _timer;
  Completer<_Choice>? _choice;
  BuildContext? _dialogContext;

  /// The dialog's Cancel button, which a second quit request focuses.
  final FocusNode dialogFocus = FocusNode(debugLabel: 'exit dialog');

  ExitPhase get phase => _phase;

  /// The host went away while the dialog was open.
  bool get hostLost => _hostLost;

  /// The rows of the dialog, in layout order, derived from live state.
  List<ExitItem> get items {
    final layout = workbench.layout;
    if (layout == null) return const [];
    final out = <ExitItem>[];
    for (final pane in layout.panes) {
      final failure = _failed[pane.id];
      final stopping = _stopping.contains(pane.id);
      final ExitItemKind kind;
      String? work;
      String? draft;
      if (pane.kind == agentChatKind) {
        final link = workbench.agents.linkOf(pane.id);
        if (link == null) continue;
        kind = ExitItemKind.agent;
        work = workbench.agents.exitWork(pane.id);
        if (link.unsavedReason case final reason?) {
          draft = 'Draft not saved: $reason';
        }
      } else if (pane.kind == terminalKind) {
        final link = workbench.terminals.linkOf(pane.id);
        if (link == null) continue;
        kind = ExitItemKind.terminal;
        if (link.status == TerminalStatus.live) work = _terminalWork[pane.id];
      } else {
        continue;
      }
      if (stopping) work = 'stopping';
      if (work == null && draft == null && failure == null) continue;
      out.add(
        ExitItem(
          paneId: pane.id,
          title: workbench.paneTitle(pane),
          kind: kind,
          work: failure == null ? work : null,
          draft: draft,
          stopping: stopping && failure == null,
          failure: failure,
        ),
      );
    }
    return out;
  }

  /// What **Stop processes and close** does, stated in the dialog.
  String get consequences {
    final rows = items;
    final parts = [
      if (rows.any((i) => i.hasProcess)) 'every listed process will be stopped',
      if (rows.any((i) => i.draft != null))
        'the text of every listed unsaved draft will be lost',
    ];
    const kept = 'Saved sessions and stored drafts are kept.';
    if (parts.isEmpty) return 'Closes Kumiko. $kept';
    return 'Stop processes and close: ${parts.join(' and ')}. $kept';
  }

  // --- the request --------------------------------------------------------

  /// A cancellable quit. Answers `exit` once nothing is left to decide, and
  /// `cancel` when the user cancels, or when a quit is already being handled
  /// (the open dialog is focused instead).
  Future<AppExitResponse> requestExit() async {
    if (_phase != ExitPhase.idle) {
      dialogFocus.requestFocus();
      return AppExitResponse.cancel;
    }
    _begin();
    try {
      // The quit flush and the activity query run together.
      await Future.wait([workbench.flushForExit(), _readTerminals()]);
      while (true) {
        if (items.isNotEmpty && await _decide() == _Choice.cancel) {
          return AppExitResponse.cancel;
        }
        // The final flush can fail for text typed after the first one; that
        // draft was not listed, so the user decides again (design D1).
        if (await _quit()) return AppExitResponse.exit;
      }
    } finally {
      if (_phase != ExitPhase.quitting) _end();
    }
  }

  void _begin() {
    _phase = ExitPhase.collecting;
    _terminalWork = const {};
    _stopping.clear();
    _failed.clear();
    _hostLost = false;
    _finalChecking = false;
    _accepted = const {};
    notifyListeners();
  }

  void _end() {
    _timer?.cancel();
    _timer = null;
    if (_choice != null) workbench.removeListener(_onChange);
    _choice = null;
    _stopping.clear();
    _failed.clear();
    _phase = ExitPhase.idle;
    if (!_disposed) notifyListeners();
  }

  Future<_Choice> _decide() async {
    _phase = ExitPhase.deciding;
    _hostWasConnected = workbench.connected;
    final choice = _choice = Completer<_Choice>();
    workbench.addListener(_onChange);
    _timer = Timer.periodic(pollInterval, (_) {
      if (_reading == null) {
        unawaited(_readTerminals().then((_) => _onChange()));
      }
    });
    _finalChecking = false;
    notifyListeners();
    if (_dialogContext == null) _openDialog();
    final decided = await choice.future;
    _timer?.cancel();
    _timer = null;
    workbench.removeListener(_onChange);
    if (decided == _Choice.cancel) _closeDialog();
    return decided;
  }

  /// The decision is made: flush, `app/quit`, close the connection. The
  /// layout is frozen, so nothing the host does to its units reaches it.
  /// Answers false, without quitting, when the flush leaves a draft unsaved
  /// that the user's choice did not name: the dialog asks again.
  Future<bool> _quit() async {
    _phase = ExitPhase.quitting;
    notifyListeners();
    workbench.freezeLayout();
    try {
      await workbench.flushForExit();
      if (items.any((i) => i.draft != null && !_accepted.contains(i.paneId))) {
        workbench.unfreezeLayout();
        return false;
      }
      await workbench.announceQuit();
      await quit();
    } on Object catch (e) {
      debugPrint('The quit did not end cleanly: $e');
    }
    return true;
  }

  // --- the dialog -----------------------------------------------------------

  void _openDialog() {
    final context = navigatorKey.currentContext;
    if (context == null) {
      // Nothing to ask with: the quit is not carried out unasked.
      _choice?.complete(_Choice.cancel);
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) {
          _dialogContext = dialog;
          return ExitDialog(coordinator: this);
        },
      ).whenComplete(() {
        _dialogContext = null;
        // Any other way out of the dialog is a Cancel.
        if (_choice case final c? when !c.isCompleted) {
          c.complete(_Choice.cancel);
        }
      }),
    );
  }

  void _closeDialog() {
    final context = _dialogContext;
    if (context != null && context.mounted) Navigator.of(context).pop();
  }

  /// **Cancel**: the app stays, every unresolved item keeps running.
  void cancel() => _decideAs(_Choice.cancel);

  /// **Stop processes and close**.
  void stopAllAndClose() => _decideAs(_Choice.quit);

  void _decideAs(_Choice choice) {
    final pending = _choice;
    if (_phase == ExitPhase.deciding &&
        pending != null &&
        !pending.isCompleted) {
      if (choice == _Choice.quit) {
        _accepted = {
          for (final i in items)
            if (i.draft != null) i.paneId,
        };
      }
      pending.complete(choice);
    }
  }

  /// **Stop** on one item: its unit ends, its pane stays.
  Future<void> stop(String paneId) async {
    if (_phase != ExitPhase.deciding) return;
    final item = items.where((i) => i.paneId == paneId).firstOrNull;
    if (item == null || !item.canStop) return;
    _stopping.add(paneId);
    notifyListeners();
    final error = item.kind == ExitItemKind.agent
        ? await workbench.agents.stopForExit(paneId)
        : await workbench.terminals.stopForExit(paneId);
    if (_phase != ExitPhase.deciding) return;
    if (error != null && _stopping.remove(paneId)) _failed[paneId] = error;
    _onChange();
  }

  // --- following the live state ---------------------------------------------

  /// One activity read at a time: the host refuses a concurrent request.
  Future<void> _readTerminals() {
    final previous = _reading ?? Future<void>.value();
    final next = previous.then((_) async {
      final ids = [
        for (final id in workbench.terminals.livePaneIds)
          if (workbench.layout?.pane(id) != null) id,
      ];
      final work = ids.isEmpty
          ? const <String, String>{}
          : await workbench.terminals.warningsFor(ids);
      if (!_disposed && _phase != ExitPhase.idle) _terminalWork = work;
    });
    _reading = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_reading, next)) _reading = null;
      }),
    );
    return next;
  }

  void _onChange() {
    if (_disposed || _phase != ExitPhase.deciding) return;
    if (_hostWasConnected && !workbench.connected) _hostLost = true;
    _settleStops();
    notifyListeners();
    _finishWhenEmpty();
  }

  /// A Stop is done when its unit ended; one the host could not confirm moves
  /// to the failed set, which no later state removes.
  void _settleStops() {
    final layout = workbench.layout;
    for (final id in [..._failed.keys]) {
      if (layout?.pane(id) == null) _failed.remove(id);
    }
    for (final id in [..._stopping]) {
      final pane = layout?.pane(id);
      String? failure;
      var done = true;
      if (pane?.kind == agentChatKind) {
        final link = workbench.agents.linkOf(id);
        failure = link?.closeFailure;
        done = link == null || !link.live;
      } else if (pane?.kind == terminalKind) {
        final link = workbench.terminals.linkOf(id);
        failure = link?.closeFailure;
        done = link == null || link.status == TerminalStatus.ended;
      }
      if (failure != null) {
        _stopping.remove(id);
        _failed[id] = failure;
      } else if (done) {
        _stopping.remove(id);
      }
    }
  }

  /// The last item left: one more activity read, and the app quits unless it
  /// finds new work. When the host was lost the user decides.
  void _finishWhenEmpty() {
    final choice = _choice;
    if (choice == null ||
        choice.isCompleted ||
        _hostLost ||
        _finalChecking ||
        items.isNotEmpty) {
      return;
    }
    _finalChecking = true;
    unawaited(() async {
      try {
        await _readTerminals();
      } finally {
        _finalChecking = false;
      }
      if (_disposed || choice.isCompleted || _phase != ExitPhase.deciding) {
        return;
      }
      if (!_hostLost && items.isEmpty) {
        choice.complete(_Choice.quit);
      } else {
        notifyListeners();
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    workbench.removeListener(_onChange);
    dialogFocus.dispose();
    super.dispose();
  }
}
