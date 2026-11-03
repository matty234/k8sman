import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../terminal/terminal_session.dart';
import '../terminal/terminal_tab.dart';
import 'log_stream_view.dart';

/// Height of the dock's tab strip (also the whole dock when collapsed).
const double kLogDockStripHeight = 30;

/// The bottom dock: a resizable area with one tab per log stream or terminal.
/// [maxHeight] is the most the dock may take (the shell keeps room for the
/// main content above it).
class LogDockView extends StatelessWidget {
  final double maxHeight;
  const LogDockView({super.key, required this.maxHeight});

  /// The height the dock occupies for the current state.
  static double heightFor(LogDock dock, double maxHeight) {
    if (dock.collapsed) return kLogDockStripHeight + 1;
    final hi = maxHeight < LogDock.minHeight ? LogDock.minHeight : maxHeight;
    return dock.height.clamp(LogDock.minHeight, hi);
  }

  @override
  Widget build(BuildContext context) {
    final dock = context.watch<LogDock>();
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final h = heightFor(dock, maxHeight);
    final active = dock.activeTab;
    return SizedBox(
      height: h,
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(height: 1, color: colors.separator),
                _TabStrip(dock: dock),
                if (!dock.collapsed) ...[
                  Container(height: 1, color: colors.separator),
                  Expanded(
                    child: active == null
                        ? ColoredBox(
                            color: theme.colorScheme.surface,
                            child: Center(
                              child: Text(
                                'No log streams or terminals. Open one with “Logs” or “Terminal” in a pod’s inspector or a container card.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                              ),
                            ),
                          )
                        : switch (active) {
                            LogStream s => LogStreamView(key: ObjectKey(s), stream: s),
                            TerminalTab t => TerminalSession(key: ObjectKey(t), session: t),
                            _ => const SizedBox.shrink(),
                          },
                  ),
                ],
              ],
            ),
          ),
          if (!dock.collapsed)
            // Resize handle: a wider grab area over the top hairline.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 5,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  key: const ValueKey('log-dock-resize'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) =>
                      dock.setHeight((h - d.delta.dy).clamp(LogDock.minHeight, maxHeight < LogDock.minHeight ? LogDock.minHeight : maxHeight)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  final LogDock dock;
  const _TabStrip({required this.dock});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final tabs = dock.tabs;
    final active = dock.activeTab;
    final terminals = tabs.whereType<TerminalTab>().length;
    final (titleIcon, title) = tabs.isEmpty || terminals == 0
        ? (Icons.notes, 'Logs')
        : terminals == tabs.length
            ? (Icons.terminal, 'Terminal')
            : (Icons.view_agenda_outlined, 'Console');
    return Container(
      height: kLogDockStripHeight,
      color: colors.inspector,
      child: LayoutBuilder(
        builder: (context, box) {
          // Narrow main column: drop the title and status; tabs keep the room.
          final narrow = box.maxWidth < 560;
          return Row(
            children: [
              const SizedBox(width: 10),
              Icon(titleIcon, size: 14, color: theme.hintColor),
              if (!narrow) ...[const SizedBox(width: 5), Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor))],
              const SizedBox(width: 8),
              Container(width: 1, height: 16, color: colors.separator),
              Expanded(
                child: tabs.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Text('No streams', style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
                      )
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        children: [for (final t in tabs) _DockTab(tab: t, active: t == active && !dock.collapsed)],
                      ),
              ),
              if (active is LogStream && !narrow) _ActiveStatus(stream: active),
              IconButton(
                tooltip: dock.collapsed ? 'Expand panel (⌘J)' : 'Collapse panel (⌘J)',
                icon: Icon(dock.collapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18),
                onPressed: () => dock.tabs.isEmpty ? dock.toggle() : dock.setCollapsed(!dock.collapsed),
              ),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }
}

class _ActiveStatus extends StatelessWidget {
  final LogStream stream;
  const _ActiveStatus({required this.stream});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: stream,
      builder: (context, _) {
        final small = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11);
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${logPhaseLabel(stream)} · ${logStreamSummary(stream)}',
              key: const ValueKey('log-dock-status'),
              style: small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}

/// Closes [tab], asking first if it is a running terminal session.
Future<void> closeDockTab(BuildContext context, LogDock dock, DockTab tab) async {
  if (tab.confirmClose && !await _confirmEndSessions(context, 1)) return;
  dock.close(tab);
}

Future<bool> _confirmEndSessions(BuildContext context, int n) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(n == 1 ? 'End the terminal session?' : 'End $n terminal sessions?'),
      content: const Text('The shell and anything running in it will be stopped.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('confirm-close-terminal'), onPressed: () => Navigator.pop(context, true), child: const Text('Close')),
      ],
    ),
  );
  return ok == true;
}

class _DockTab extends StatelessWidget {
  final DockTab tab;
  final bool active;
  const _DockTab({required this.tab, required this.active});

  Future<void> _menu(BuildContext context, Offset global) async {
    final dock = context.read<LogDock>();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final p = overlay.globalToLocal(global);
    PopupMenuItem<String> item(String v, String label, {bool enabled = true}) => PopupMenuItem(value: v, height: 28, enabled: enabled, child: Text(label));
    final v = await showMenu<String>(
      popUpAnimationStyle: AnimationStyle.noAnimation,
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy),
      items: [
        item('close', 'Close'),
        item('others', 'Close others', enabled: dock.tabs.length > 1),
        item('all', 'Close all'),
        const PopupMenuDivider(height: 9),
        item('copy', 'Copy pod name'),
      ],
    );
    if (!context.mounted) return;
    switch (v) {
      case 'close':
        await closeDockTab(context, dock, tab);
      case 'others':
        final n = dock.tabs.where((t) => t != tab && t.confirmClose).length;
        if (n == 0 || await _confirmEndSessions(context, n)) dock.closeOthers(tab);
      case 'all':
        final n = dock.tabs.where((t) => t.confirmClose).length;
        if (n == 0 || await _confirmEndSessions(context, n)) dock.closeAll();
      case 'copy':
        copyToClipboard(context, tab.pod);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dock = context.read<LogDock>();
    final tab = this.tab;
    final stream = tab is LogStream ? tab : null;
    final term = tab is TerminalTab ? tab : null;
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) => GestureDetector(
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        onTertiaryTapUp: (_) => closeDockTab(context, dock, tab),
        child: Tooltip(
          message: stream != null
              ? '${stream.namespace}/${stream.label} · ${logPhaseLabel(stream)}${stream.previous ? ' · previous' : ''}'
              : '${tab.namespace}/${tab.label} · ${term == null ? '' : '${term.commandLabel} · ${terminalPhaseLabel(term)}'}',
          waitDuration: const Duration(milliseconds: 800),
          child: Hoverable(
            key: ValueKey('${stream != null ? 'log' : 'dock'}-tab-${tab.id}'),
            cursor: SystemMouseCursors.basic,
            onTap: () => dock.activate(tab),
            builder: (h) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 3),
              padding: const EdgeInsets.only(left: 8, right: 3),
              constraints: const BoxConstraints(maxWidth: 300),
              decoration: BoxDecoration(
                color: active ? theme.colorScheme.surface : (h ? colors.hover : null),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: active ? colors.separator : Colors.transparent, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (stream != null)
                    _Dot(color: severityColor(context, logPhaseSeverity(stream)), pulse: stream.phase == LogPhase.streaming && stream.follow)
                  else
                    Icon(Icons.terminal, size: 13, color: severityColor(context, term == null ? Severity.neutral : terminalSeverity(term))),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: tab.pod),
                          TextSpan(
                            text: '/${stream?.container ?? term?.container ?? ''}',
                            style: TextStyle(color: theme.hintColor),
                          ),
                          if (stream?.previous ?? false)
                            TextSpan(
                              text: ' (prev)',
                              style: TextStyle(color: theme.hintColor),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: active ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Opacity(
                    opacity: active || h ? 1 : 0,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: IconButton(
                        key: ValueKey('${stream != null ? 'log' : 'dock'}-tab-close-${tab.id}'),
                        tooltip: 'Close',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        style: IconButton.styleFrom(minimumSize: const Size(18, 18), padding: EdgeInsets.zero),
                        icon: const Icon(Icons.close, size: 12),
                        onPressed: () => closeDockTab(context, dock, tab),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final bool pulse;
  const _Dot({required this.color, required this.pulse});

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: pulse ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4)] : null,
    ),
  );
}
