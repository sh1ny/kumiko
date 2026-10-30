import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import '../host_link.dart';
import '../terminal/terminal_surface.dart';

/// The terminal engine spike (change `host-terminals`, tasks 6.x): one real
/// host terminal (open, attach, channels) rendered through a
/// [TerminalSurface]. Debug builds only; the release app never reaches this
/// file (audit rule D10).
class TerminalSpikeApp extends StatelessWidget {
  const TerminalSpikeApp({
    super.key,
    required this.connector,
    required this.surfaceFactory,
  });

  final HostConnector connector;
  final TerminalSurfaceFactory surfaceFactory;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kumiko terminal spike',
    home: Scaffold(
      body: TerminalSpikeView(
        connector: connector,
        surfaceFactory: surfaceFactory,
      ),
    ),
  );
}

/// Starts a host, opens its default profile once the surface has a size,
/// and relays bytes both ways.
class TerminalSpikeView extends StatefulWidget {
  const TerminalSpikeView({
    super.key,
    required this.connector,
    required this.surfaceFactory,
  });

  final HostConnector connector;
  final TerminalSurfaceFactory surfaceFactory;

  @override
  State<TerminalSpikeView> createState() => _TerminalSpikeViewState();
}

class _TerminalSpikeViewState extends State<TerminalSpikeView> {
  late final TerminalSurface _surface = widget.surfaceFactory(
    scrollbackLimit: defaultScrollbackLimit,
  );
  final List<StreamSubscription<Object?>> _subscriptions = [];
  HostLink? _link;
  TerminalChannels? _terminal;
  String _status = 'starting the host';

  @override
  void initState() {
    super.initState();
    _subscriptions.add(_surface.size.listen(_onSize));
  }

  Future<void> _onSize((int, int) size) async {
    final (cols, rows) = size;
    final terminal = _terminal;
    if (terminal != null) {
      await _link?.resizeTerminal(terminal.terminalId, cols, rows);
      return;
    }
    if (_link != null) return; // opening
    try {
      final link = _link = await widget.connector();
      final profiles = await link.profileList();
      final profileId = profiles.defaultId;
      if (profileId == null || !profiles.defaultAvailable) {
        _setStatus('no default shell profile');
        return;
      }
      final opened = _terminal = await link.openTerminal(
        TerminalOpenParams(profileId: profileId, cols: cols, rows: rows),
      );
      _subscriptions
        ..add(opened.output.listen(_surface.feed))
        ..add(_surface.input.listen((Uint8List bytes) => opened.write(bytes)))
        ..add(
          link.terminalExits
              .where((e) => e.terminalId == opened.terminalId)
              .listen((e) => _setStatus('ended: ${e.reason.wire}')),
        );
      _setStatus(
        'live: ${profiles.profiles.firstWhere((p) => p.id == profileId).name}',
      );
    } on Object catch (e) {
      _setStatus('failed: $e');
    }
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _surface.dispose();
    unawaited(_link?.quit());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(4),
        child: Text(_status, key: const Key('spike-status')),
      ),
      Expanded(child: _surface.view),
    ],
  );
}
