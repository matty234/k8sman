import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

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
import 'keyboard_help.dart';
import 'keys.dart';

const _navWidth = 232.0;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  double _sidebarWidth = 560;

  void _palette() => showCommandPalette(context);

  /// `:` opens command mode (k9s-style) and `?` the key help, unless the user is typing
  /// somewhere. Not a shortcut binding: a matched shortcut always consumes
  /// the key, which would swallow ':' in text fields and terminals.
  KeyEventResult _commandMode(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || textEntryFocused) return KeyEventResult.ignored;
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
    // The macOS View menu's "Command Palette…" item.
    WindowChrome.onCommandPalette = _palette;
    // "Alerts" and "Port Forwards" (palette, links) open their dock panes.
    _app = context.read<AppState>()..showInDock = _showInDock;
  }

  @override
  void dispose() {
    if (WindowChrome.onCommandPalette == _palette) WindowChrome.onCommandPalette = null;
    if (_app.showInDock == _showInDock) _app.showInDock = null;
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
    return CallbackShortcuts(
      bindings: {
        primaryShortcut(LogicalKeyboardKey.keyJ): dock.toggle,
        primaryShortcut(LogicalKeyboardKey.keyI): app.toggleInspector,
        // Editors and the log search handle ⌘F themselves when focused.
        primaryShortcut(LogicalKeyboardKey.keyF): () => visibleTable(context)?.filterFocus.requestFocus(),
        for (final a in commandPaletteShortcuts) a: _palette,
      },
      child: Focus(
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
