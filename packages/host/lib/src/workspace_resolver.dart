import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:process_containment/process_containment.dart';

import 'host_faults.dart';
import 'host_options.dart';

/// How one folder resolution ended (design D5).
sealed class ResolveResult {
  const ResolveResult();
}

/// The path is a directory: its canonical path and identity.
final class ResolveFound extends ResolveResult {
  const ResolveFound(this.directory);
  final ResolvedDirectory directory;
}

/// The path is not a directory, or cannot be opened.
final class ResolveMissing extends ResolveResult {
  const ResolveMissing(this.detail);
  final String detail;
}

/// The call did not return within the timeout.
final class ResolveTimedOut extends ResolveResult {
  const ResolveTimedOut();
}

/// Every slot is held and the call was not allowed to wait.
final class ResolveBusy extends ResolveResult {
  const ResolveBusy();
}

/// A queued call that could never get a slot: every slot is held by a call
/// that timed out and has not returned.
final class ResolveStarved extends ResolveResult {
  const ResolveStarved();
}

typedef _Wire = (String? realPath, String? id, String? detail);

class _Queued {
  _Queued(this.path);
  final String path;
  final Completer<ResolveResult> done = Completer();
}

/// Runs `directoryIdentity` in isolates (design D5): at most
/// [HostOptions.resolveSlots] at once, each with a timeout. A call that times
/// out is abandoned, not killed, and keeps its slot until it returns, so the
/// host isolate never blocks on a folder that does not answer.
class WorkspaceResolver {
  WorkspaceResolver({
    required this.faults,
    this.slots = HostOptions.resolveSlots,
    this.timeout = HostOptions.defaultResolveTimeout,
  });

  final HostFaults faults;
  final int slots;
  final Duration timeout;

  /// Slots in use, including those held by timed-out calls.
  int _held = 0;

  /// Slots held by calls that timed out and have not returned.
  int _hung = 0;

  final Queue<_Queued> _queue = Queue();

  /// Resolves [path]. With [queue] a call waits for a slot; without it a call
  /// that finds every slot held gets [ResolveBusy] at once. The slot is taken
  /// before this returns, so the order of calls is the order of slots.
  Future<ResolveResult> resolve(String path, {required bool queue}) {
    if (_held < slots) return _run(path);
    if (!queue) return Future.value(const ResolveBusy());
    if (_hung >= slots) return Future.value(const ResolveStarved());
    final waiting = _Queued(path);
    _queue.add(waiting);
    return waiting.done.future;
  }

  Future<ResolveResult> _run(String path) {
    _held++;
    final fault = faults.takeResolveFault(path);
    ReceivePort? hangPort;
    if (fault != null && fault.hang) {
      hangPort = ReceivePort()
        ..listen((Object? m) {
          if (m is SendPort) faults.registerHung(path, m);
        });
    }
    final call = _spawn(
      path,
      fault?.delay.inMilliseconds ?? 0,
      hangPort?.sendPort,
    );

    final done = Completer<ResolveResult>();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      _hung++;
      done.complete(const ResolveTimedOut());
      _starveQueue();
    });

    void finished(ResolveResult result) {
      timer.cancel();
      hangPort?.close();
      if (timedOut) {
        // Late: it only gives its slot back.
        _hung--;
      } else {
        done.complete(result);
      }
      _held--;
      _pump();
    }

    call.then(
      (wire) => finished(
        wire.$1 != null
            ? ResolveFound(ResolvedDirectory(realPath: wire.$1!, id: wire.$2!))
            : ResolveMissing(wire.$3 ?? 'unavailable'),
      ),
      onError: (Object e) => finished(ResolveMissing('resolution failed: $e')),
    );
    return done.future;
  }

  void _pump() {
    while (_queue.isNotEmpty && _held < slots) {
      final next = _queue.removeFirst();
      _run(next.path).then(next.done.complete);
    }
  }

  /// When every slot is held by a timed-out call, nothing queued can run in
  /// time: finish all of it now.
  void _starveQueue() {
    if (_hung < slots) return;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().done.complete(const ResolveStarved());
    }
  }

  /// The closure captures only its three arguments, so nothing of the host
  /// goes to the isolate. The delay and the hang come after the call, so a
  /// slow result is the state of the folder when the call started.
  static Future<_Wire> _spawn(String path, int delayMs, SendPort? hang) =>
      Isolate.run<_Wire>(() async {
        _Wire wire;
        try {
          final r = directoryIdentity(path);
          wire = switch (r) {
            ResolvedDirectory() => (r.realPath, r.id, null),
            TargetUnavailable() => (null, null, r.detail),
          };
        } on Object catch (e) {
          wire = (null, null, 'resolution failed: $e');
        }
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        if (hang != null) {
          final release = ReceivePort();
          hang.send(release.sendPort);
          await release.first;
          release.close();
        }
        return wire;
      });
}
