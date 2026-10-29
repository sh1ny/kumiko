import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';
import 'host_link.dart';

/// The desktop's host-status machine. Cleaning up is not a phase of its own:
/// it is [CleanupController.reconciling] while connected.
enum HostPhase {
  /// Nothing started yet.
  idle,
  starting,
  connected,
  startError,
  incompatible,
  alreadyRunning,
  storeError,
  hostLost,
}

class HostController extends ChangeNotifier {
  HostController({required this.connector, required this.onExit});

  final HostConnector connector;

  /// Called when the user dismisses *already running*.
  final void Function() onExit;

  HostPhase _phase = HostPhase.idle;
  HostLink? _link;
  CleanupController? _cleanup;
  HostStartException? _error;
  HostLoss? _loss;
  int _generation = 0;
  bool _disposed = false;

  HostPhase get phase => _phase;
  HelloResult? get hello => _link?.hello;

  /// The connected host, or null.
  HostLink? get link => _link;
  CleanupController? get cleanup => _cleanup;

  /// The start failure behind a start-error, incompatible, already-running
  /// or store-error phase.
  HostStartException? get error => _error;
  HostLoss? get loss => _loss;

  /// Starts the host, or starts it again (Restart host). Does nothing while
  /// starting or connected.
  Future<void> start() async {
    if (_phase == HostPhase.starting || _phase == HostPhase.connected) return;
    final generation = ++_generation;
    _release();
    _error = null;
    _loss = null;
    _phase = HostPhase.starting;
    notifyListeners();

    final HostLink link;
    try {
      link = await connector();
    } on HostStartException catch (e) {
      if (_disposed || generation != _generation) return;
      _error = e;
      _phase = _phaseFor(e);
      notifyListeners();
      return;
    }
    if (_disposed || generation != _generation) {
      unawaited(link.quit());
      return;
    }
    if (!link.hello.capabilities.contains(Capability.workbench)) {
      // A host that cannot serve the workbench is as unusable as one with no
      // common protocol version.
      unawaited(link.quit());
      _error = HostStartException(
        HostStartFailure.helloRejected,
        'the host does not offer the ${Capability.workbench} capability',
        reason: ErrorCode.incompatibleVersion,
      );
      _phase = HostPhase.incompatible;
      notifyListeners();
      return;
    }
    _link = link;
    _cleanup = CleanupController(link);
    _phase = HostPhase.connected;
    notifyListeners();
    unawaited(
      link.lost.then((loss) {
        if (_disposed || generation != _generation) return;
        _loss = loss;
        _release();
        _phase = HostPhase.hostLost;
        notifyListeners();
      }),
    );
  }

  /// Dismisses *already running*: the new desktop exits.
  void dismissAlreadyRunning() => onExit();

  /// Ends the host as the desktop quits.
  Future<void> shutdown() async {
    _generation++;
    final link = _link;
    _release();
    await link?.quit();
  }

  void _release() {
    _cleanup?.dispose();
    _cleanup = null;
    _link = null;
  }

  static HostPhase _phaseFor(HostStartException e) {
    if (e.kind != HostStartFailure.helloRejected) return HostPhase.startError;
    return switch (e.reason) {
      ErrorCode.profileLocked => HostPhase.alreadyRunning,
      ErrorCode.incompatibleVersion => HostPhase.incompatible,
      ErrorCode.storeMigrationFailed ||
      ErrorCode.storeNewer ||
      ErrorCode.storeUnreadable ||
      ErrorCode.storeError => HostPhase.storeError,
      _ => HostPhase.startError,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _release();
    super.dispose();
  }
}
