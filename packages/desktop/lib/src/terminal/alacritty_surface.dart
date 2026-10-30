import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';

import 'terminal_surface.dart';

/// The `flutter_alacritty` adapter (ADR 0010): the engine is fed the host's
/// bytes and never starts a pseudo-terminal of its own. `RustLib.init()` must
/// have completed before the first [feed] or layout.
final class AlacrittySurface implements TerminalSurface {
  AlacrittySurface({this.scrollbackLimit = defaultScrollbackLimit}) {
    final defaults = TerminalConfig.defaults();
    _engine = TerminalEngine(
      config: defaults.copyWith(
        scrolling: defaults.scrolling.copyWith(history: scrollbackLimit),
      ),
    );
    // The view attaches only a controller it creates itself; selection and
    // search go through this one.
    _controller.attach(_engine);
    _view = _AlacrittyView(
      engine: _engine,
      controller: _controller,
      onPtyResize: (cols, rows) => _size.add(_lastSize = (cols, rows)),
    );
  }

  late final TerminalEngine _engine;

  /// The engine itself, for the engine bar test's grid checks.
  @visibleForTesting
  TerminalEngine get engine => _engine;
  late final Widget _view;
  final TerminalController _controller = TerminalController();
  final StreamController<(int, int)> _size =
      StreamController<(int, int)>.broadcast();
  (int, int)? _lastSize;

  @override
  final int scrollbackLimit;

  @override
  void feed(Uint8List bytes) => _engine.feed(bytes);

  @override
  Stream<Uint8List> get input => _engine.output;

  @override
  Stream<(int cols, int rows)> get size async* {
    if (_lastSize case final last?) yield last;
    yield* _size.stream;
  }

  @override
  Widget get view => _view;

  @override
  void dispose() {
    unawaited(_size.close());
    _controller.dispose();
    _engine.dispose();
  }
}

/// The engine's view with its scrollback search bar. The view leaves the
/// search bar to the host: its Ctrl+Shift+F only invokes
/// [ToggleSearchIntent].
class _AlacrittyView extends StatefulWidget {
  const _AlacrittyView({
    required this.engine,
    required this.controller,
    required this.onPtyResize,
  });

  final TerminalEngine engine;
  final TerminalController controller;
  final void Function(int cols, int rows) onPtyResize;

  @override
  State<_AlacrittyView> createState() => _AlacrittyViewState();
}

class _AlacrittyViewState extends State<_AlacrittyView> {
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey();
  bool _searchOpen = false;
  String _pattern = '';
  TerminalSearchOptions _options = const TerminalSearchOptions();

  void _search(String pattern) {
    _pattern = pattern;
    widget.controller.searchSet(pattern, options: _options);
  }

  void _setOptions(TerminalSearchOptions options) {
    setState(() => _options = options);
    _search(_pattern);
  }

  void _toggleSearch() {
    if (_searchOpen) {
      _closeSearch();
    } else {
      setState(() => _searchOpen = true);
    }
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _pattern = '';
    });
    widget.controller.searchClear();
    _viewKey.currentState?.requestTerminalFocus();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // The view owns the engine's resize hook (it replaces
      // TerminalEngine.onPtyResize), so the size comes from the view.
      TerminalView(
        widget.engine,
        key: _viewKey,
        controller: widget.controller,
        onPtyResize: widget.onPtyResize,
        actions: {
          ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(
            onInvoke: (_) {
              _toggleSearch();
              return null;
            },
          ),
        },
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        // Kept mounted so opening it costs nothing (the bar's own advice).
        child: Offstage(
          offstage: !_searchOpen,
          child: Material(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => TerminalSearchBar(
                visible: _searchOpen,
                invalidPattern: !widget.controller.searchValid,
                caseSensitive: _options.caseSensitive,
                wholeWord: _options.wholeWord,
                regex: _options.regex,
                wrap: _options.wrap,
                onChanged: _search,
                onNext: widget.controller.searchNext,
                onPrev: widget.controller.searchPrev,
                onClose: _closeSearch,
                onCaseSensitiveChanged: (v) => _setOptions(
                  TerminalSearchOptions(
                    caseSensitive: v,
                    wholeWord: _options.wholeWord,
                    regex: _options.regex,
                    wrap: _options.wrap,
                  ),
                ),
                onWholeWordChanged: (v) => _setOptions(
                  TerminalSearchOptions(
                    caseSensitive: _options.caseSensitive,
                    wholeWord: v,
                    regex: _options.regex,
                    wrap: _options.wrap,
                  ),
                ),
                onRegexChanged: (v) => _setOptions(
                  TerminalSearchOptions(
                    caseSensitive: _options.caseSensitive,
                    wholeWord: _options.wholeWord,
                    regex: v,
                    wrap: _options.wrap,
                  ),
                ),
                onWrapChanged: (v) => _setOptions(
                  TerminalSearchOptions(
                    caseSensitive: _options.caseSensitive,
                    wholeWord: _options.wholeWord,
                    regex: _options.regex,
                    wrap: v,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
