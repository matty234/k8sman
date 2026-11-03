import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/kubeconfig_picker.dart';
import '../app/window_chrome.dart';
import '../metrics/metrics_page.dart';
import '../state/app_state.dart';
import '../state/log_dock.dart';
import 'alerts/alerts_view.dart';
import 'detail/detail_sidebar.dart';
import 'logs/log_dock_view.dart';
import 'helm/helm_view.dart';
import 'nodes/nodes_view.dart';
import 'overview/overview_view.dart';
import 'portforward/portforward_view.dart';
import 'resource_nav.dart';
import 'resource_table.dart';
import 'security/security_view.dart';
import 'theme.dart';
import 'widgets/common.dart';

const _navWidth = 232.0;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  double _sidebarWidth = 560;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    if (app.loading && app.types.isEmpty) {
      return const Scaffold(body: WindowDragArea(child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator()))));
    }
    if (app.error != null && app.types.isEmpty) {
      return Scaffold(
        body: WindowDragArea(
          child: Center(
            child: SizedBox(
              width: 460,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Cannot connect to the cluster', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                InlineMessage('${app.error}', isError: true),
                const SizedBox(height: 8),
                Text('Check the cluster is reachable and your credentials are valid, or choose another kubeconfig.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(onPressed: app.init, child: const Text('Retry')),
                  const KubeconfigPicker(compact: false),
                ]),
              ]),
            ),
          ),
        ),
      );
    }
    final type = app.selectedType;
    final dock = context.watch<LogDock>();
    final detail = app.detail;
    final collapsed = app.inspectorCollapsed;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): dock.toggle,
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): app.toggleInspector,
      },
      child: Focus(
        autofocus: true,
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
                      child: switch (app.view) {
                        MainView.overview => const OverviewView(),
                        MainView.alerts => const AlertsView(),
                        MainView.nodes => const NodesView(),
                        MainView.security => const SecurityView(),
                        MainView.metrics => const MetricsPage(),
                        MainView.portForwards => const PortForwardView(),
                        MainView.helm => const HelmView(),
                        MainView.resources => type == null
                            ? WindowDragArea(child: Center(child: Text('Select a resource kind', style: TextStyle(color: theme.hintColor))))
                            : ResourceTableView(type: type),
                      },
                    ),
                    if (dock.shown) LogDockView(maxHeight: dockMax),
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
      message: 'Show inspector: ${target.type.kind} ${target.name} (⌘I)',
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
            Icon(kindIcon(target.type), size: 14, color: theme.colorScheme.primary),
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
