import 'package:flutter/gestures.dart' show kBackMouseButton, kForwardMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/links.dart';
import '../app/window_chrome.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import '../state/cluster_error.dart';
import '../state/log_dock.dart';
import '../state/startup_gate.dart';
import 'cluster_error_view.dart';
import 'connecting_view.dart';
import 'detail/detail_sidebar.dart';
import 'logs/log_dock_view.dart';
import 'palette/command_palette.dart';
import 'palette/palette_sources.dart' show visibleTable;
import 'resource_nav.dart';
import 'resource_table.dart';
import 'theme.dart';
import 'widgets/common.dart';
import '../actions/actions.dart' show showActionError;
import 'keyboard_help.dart';
import 'settings/settings_page.dart';
import 'views/saved_views_ui.dart' show showSaveViewDialog;
import 'keys.dart';
import 'links_ui.dart';

const _navWidth = 232.0;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  double _sidebarWidth = 560;

  void _palette() => showCommandPalette(context);

  void _settings() => openSettings(context);

  /// ⌘S: with a table showing and no view open, the Save View dialog; with
  /// a modified view open, Update View. Text fields and the editors own ⌘S
  /// while they have focus (the editors bind it themselves; the check here
  /// covers plain text fields).
  void _saveView() {
    if (textEntryFocused || _app.view != MainView.resources) return;
    final session = _app.viewSession;
    if (session != null) {
      if (!session.modified) return;
      _app.updateActiveView().catchError((Object e) {
        if (mounted) showActionError(context, 'Could not update the view: $e');
      });
      return;
    }
    final table = visibleTable(context);
    if (table != null) showSaveViewDialog(context, table);
  }

  /// `:` opens command mode (k9s-style) and `?` the key help, unless the user is typing
  /// somewhere. Not a shortcut binding: a matched shortcut always consumes
  /// the key, which would swallow ':' in text fields and terminals.
  KeyEventResult _commandMode(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || textEntryFocused) return KeyEventResult.ignored;
    // Esc leaves Settings even when focus didn't land on the page (e.g.
    // after the palette closed); the page handles it first when it has focus.
    if (e.logicalKey == LogicalKeyboardKey.escape && _app.view == MainView.settings) {
      leaveSettings(_app);
      return KeyEventResult.handled;
    }
    // Esc closes the inspector when nothing above handled it. Handled here
    // so AppKit never sees an unhandled Esc (it would leave full screen).
    if (e.logicalKey == LogicalKeyboardKey.escape && _app.detail != null && !_app.inspectorCollapsed) {
      _app.closeDetail();
      return KeyEventResult.handled;
    }
    switch (e.character) {
      case ':':
        showCommandPalette(context, command: true);
      case '?':
        showKeyboardHelp(context);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
  late final AppState _app;
  bool _showInDock(MainView v) {
    final pane = switch (v) {
      MainView.alerts => DockPane.alerts,
      MainView.portForwards => DockPane.forwards,
      _ => null,
    };
    if (pane == null) return false;
    context.read<LogDock>().showPane(pane);
    return true;
  }

  @override
  void initState() {
    super.initState();
    // The macOS View menu's "Command Palette…" item and the app menu's
    // "Settings…".
    WindowChrome.onCommandPalette = _palette;
    WindowChrome.onSettings = _settings;
    // "Alerts" and "Port Forwards" (palette, links) open their dock panes.
    _app = context.read<AppState>()
      ..showInDock = _showInDock
      // Pages that are a kind's home (the Nodes page for Node).
      ..kindHomes ??= kindHomes;
    HardwareKeyboard.instance.addHandler(_strayKey);
    // k8sman:// links (queued until now if they launched the app).
    LinkInbox.handler = _openLink;
  }

  void _openLink(String url) {
    if (mounted) openIncomingLink(context, _app, url);
  }

  final _focus = FocusNode(debugLabel: 'shell');

  /// Keys pressed while keyboard focus sits outside the shell (it can end up
  /// on the window's scope, e.g. after the focused widget goes away) never
  /// reach the shell's handlers. Pull focus back and handle `:` and `?`.
  bool _strayKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && (primary == _focus || primary.ancestors.contains(_focus))) return false;
    if (ModalRoute.of(context)?.isCurrent == false || textEntryFocused) return false;
    _focus.requestFocus();
    return _commandMode(_focus, e) == KeyEventResult.handled;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_strayKey);
    _focus.dispose();
    if (WindowChrome.onCommandPalette == _palette) WindowChrome.onCommandPalette = null;
    if (WindowChrome.onSettings == _settings) WindowChrome.onSettings = null;
    if (_app.showInDock == _showInDock) _app.showInDock = null;
    if (LinkInbox.handler == _openLink) LinkInbox.handler = null;
    StartupGate.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    if (app.loading && app.types.isEmpty) {
      return const Scaffold(body: WindowDragArea(child: ConnectingView()));
    }
    if (app.error != null && app.types.isEmpty) {
      return Scaffold(
        body: WindowDragArea(
          child: ClusterErrorView(error: ClusterError.fromException(app.errorCause ?? app.error!), onRetry: app.init),
        ),
      );
    }
    final type = app.selectedType;
    // Startup: icons and the alerts badge wait for the first table to paint;
    // with no table on screen there is nothing to wait for.
    StartupGate.hold();
    if (app.view != MainView.resources || type == null) StartupGate.firstContentShown();
    final dock = context.watch<LogDock>();
    final detail = app.detail;
    final collapsed = app.inspectorCollapsed;
    final shell = CallbackShortcuts(
      bindings: {
        primaryShortcut(LogicalKeyboardKey.keyJ): dock.toggle,
        primaryShortcut(LogicalKeyboardKey.keyI): app.toggleInspector,
        // Editors and the log search handle ⌘F themselves when focused.
        primaryShortcut(LogicalKeyboardKey.keyF): () => visibleTable(context)?.filterFocus.requestFocus(),
        primaryShortcut(LogicalKeyboardKey.keyS): _saveView,
        primaryShortcut(LogicalKeyboardKey.comma): _settings,
        // ⌘[ is outdent in the editors, so text entry keeps it.
        primaryShortcut(LogicalKeyboardKey.bracketLeft): () => textEntryFocused ? null : app.navBack(),
        primaryShortcut(LogicalKeyboardKey.bracketRight): () => textEntryFocused ? null : app.navForward(),
        for (final a in commandPaletteShortcuts) a: _palette,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _commandMode,
        child: Scaffold(
          // On macOS the nav shows the window's sidebar vibrancy through.
          backgroundColor: nativeMacChrome ? Colors.transparent : null,
          body: LayoutBuilder(builder: (context, box) {
            final maxSidebar = (box.maxWidth - _navWidth - 360).clamp(320.0, 1400.0);
            final sidebar = _sidebarWidth.clamp(320.0, maxSidebar);
            // The dock spans the main column only: the inspector stays a
            // full-height column, like Xcode's inspector beside its debug area.
            // Keep the titlebar band plus a few table rows above it.
            final dockMax = box.maxHeight - titlebarHeight - 140;
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(width: _navWidth, child: ResourceNav()),
              Container(width: 1, color: colors.separator),
              Expanded(
                child: ColoredBox(
                  color: theme.colorScheme.surface,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      // A page (core or a module's), else the selected kind's table.
                      child: switch (pageEnabled(app, app.view) ? pageFor(app.view) : null) {
                        final page? => page.builder(context),
                        null => type == null
                            ? WindowDragArea(child: Center(child: Text('Select a resource kind', style: TextStyle(color: theme.hintColor))))
                            : ResourceTableView(type: type),
                      },
                    ),
                    LogDockView(maxHeight: dockMax),
                  ]),
                ),
              ),
              if (detail != null) ...[
                // Collapsed: kept alive offstage so expanding restores the
                // same tab and scroll position.
                Offstage(
                  offstage: collapsed,
                  // Hairline splitter with a wider grab area.
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (d) => setState(() => _sidebarWidth = (sidebar - d.delta.dx).clamp(320.0, maxSidebar)),
                      child: SizedBox(
                        width: 5,
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Container(width: 1, color: colors.separator),
                          Expanded(child: ColoredBox(color: colors.inspector)),
                        ]),
                      ),
                    ),
                  ),
                ),
                Offstage(
                  offstage: collapsed,
                  child: TickerMode(
                    enabled: !collapsed,
                    child: SizedBox(width: sidebar - 4, child: ColoredBox(color: colors.inspector, child: const DetailSidebar())),
                  ),
                ),
                if (collapsed) _CollapsedInspector(target: detail),
              ],
            ]);
          }),
        ),
      ),
    );
    return Listener(
      // The mouse's side buttons: back / forward, wherever the pointer is.
      onPointerDown: (e) {
        if (e.buttons & kBackMouseButton != 0) app.navBack();
        if (e.buttons & kForwardMouseButton != 0) app.navForward();
      },
      child: shell,
    );
  }
}

/// The inspector collapsed to a slim vertical tab on the right edge. The
/// whole tab re-expands it to the same object.
class _CollapsedInspector extends StatelessWidget {
  final DetailTarget target;
  const _CollapsedInspector({required this.target});

  static const width = 28.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final app = context.read<AppState>();
    return Tooltip(
      message: 'Show inspector: ${target.type.kind} ${target.name} (${shortcutLabel('I')})',
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        key: const ValueKey('inspector-collapsed-tab'),
        cursor: SystemMouseCursors.basic,
        onTap: app.expandInspector,
        builder: (h) => Container(
          width: width + 1,
          decoration: BoxDecoration(
            color: h ? Color.alphaBlend(colors.hover, colors.inspector) : colors.inspector,
            border: Border(left: BorderSide(color: colors.separator)),
          ),
          child: Column(children: [
            // Align the first control with the toolbar row in the titlebar band.
            SizedBox(height: (toolbarRowHeight(context) - 18) / 2),
            Icon(Icons.first_page_rounded, size: 17, color: h ? theme.colorScheme.onSurface : theme.hintColor),
            const SizedBox(height: 14),
            kindIconWidget(target.type, size: 14, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Flexible(
              child: RotatedBox(
                quarterTurns: 1,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: target.type.kind, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                    const TextSpan(text: '   '),
                    TextSpan(text: target.name),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }
}
