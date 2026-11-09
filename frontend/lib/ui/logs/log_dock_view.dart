import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/log_dock.dart';
import '../alerts/alerts_nav_badge.dart';
import '../alerts/alerts_view.dart';
import '../portforward/forwards_badge.dart';
import '../portforward/portforward_view.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../terminal/terminal_session.dart';
import '../terminal/open_terminal.dart';
import '../terminal/terminal_tab.dart';
import 'log_stream_view.dart';
import '../keys.dart';
import '../widgets/dialogs.dart';
import '../widgets/context_menu.dart';

/// Height of the dock's tab strip (also the whole dock when collapsed).
const double kLogDockStripHeight = 30;

/// The bottom dock: a permanent bar with the Alerts pane and one tab per log
/// stream or terminal, expanding to a resizable area.
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
                    child: dock.pane == DockPane.alerts
                        ? const AlertsView(docked: true)
                        : dock.pane == DockPane.forwards
                        ? const PortForwardView(docked: true)
                        : active == null
                        ? ColoredBox(
                            color: theme.colorScheme.surface,
                            child: Center(
                              child: Text(
                                'No logs or terminals open. Open one with “Logs” or “Terminal” in a pod’s inspector or a container card.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                              ),
                            ),
                          )
                        : switch (active) {
                            LogSession s => LogStreamView(key: ObjectKey(s), stream: s),
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
    return Container(
      height: kLogDockStripHeight,
      color: colors.inspector,
      child: LayoutBuilder(
        builder: (context, box) {
          // Narrow main column: drop the title and status; tabs keep the room.
          final narrow = box.maxWidth < 560;
          return Row(
            children: [
              const SizedBox(width: 4),
              _PaneTab(compact: narrow, dock: dock, pane: DockPane.alerts, icon: Icons.notifications_none, label: 'Alerts', badge: const AlertsNavBadge(leading: 6)),
              const SizedBox(width: 2),
              _PaneTab(
                compact: narrow,
                dock: dock,
                pane: DockPane.forwards,
                icon: Icons.swap_horiz,
                label: 'Forwards',
                badge: const ForwardsDockBadge(leading: 6),
                pulse: dock.forwardsPulse,
              ),
              const SizedBox(width: 4),
              Container(width: 1, height: 16, color: colors.separator),
              Expanded(
                child: tabs.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Text(narrow ? '' : 'No logs or terminals', style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
                      )
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        children: [for (final t in tabs) _DockTab(tab: t, active: t == active && !dock.collapsed)],
                      ),
              ),
              IconButton(
                key: const ValueKey('dock-new-local-shell'),
                tooltip: localShellSupported ? 'New local shell (kubectl uses the current context)' : 'Local shells are coming to Windows soon',
                icon: const Icon(Icons.add, size: 17),
                onPressed: localShellSupported ? () => openLocalShell(context) : null,
              ),
              if (active is LogSession && !narrow) _ActiveStatus(stream: active),
              IconButton(
                tooltip: '${dock.collapsed ? 'Expand' : 'Collapse'} panel (${shortcutLabel('J')})',
                icon: Icon(dock.collapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18),
                onPressed: dock.toggle,
              ),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }
}

/// A fixed pane's tab in the dock strip (Alerts, Forwards): click to open
/// the pane, again to collapse. [pulse] makes it flash once (a forward just
/// started) without switching the panel.
class _PaneTab extends StatefulWidget {
  final LogDock dock;
  final DockPane pane;
  final IconData icon;
  final String label;
  final Widget badge;
  final ValueListenable<int>? pulse;

  /// Icon only (the label goes in the tooltip): narrow main column.
  final bool compact;
  const _PaneTab({this.compact = false, required this.dock, required this.pane, required this.icon, required this.label, required this.badge, this.pulse});

  @override
  State<_PaneTab> createState() => _PaneTabState();
}

class _PaneTabState extends State<_PaneTab> with SingleTickerProviderStateMixin {
  late final _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    widget.pulse?.addListener(_onPulse);
  }

  @override
  void didUpdateWidget(_PaneTab old) {
    super.didUpdateWidget(old);
    if (old.pulse != widget.pulse) {
      old.pulse?.removeListener(_onPulse);
      widget.pulse?.addListener(_onPulse);
    }
  }

  void _onPulse() => _flash.forward(from: 0);

  @override
  void dispose() {
    widget.pulse?.removeListener(_onPulse);
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dock = widget.dock;
    final active = dock.pane == widget.pane && !dock.collapsed;
    final fg = active ? theme.colorScheme.onSurface : theme.hintColor;
    return Hoverable(
      key: ValueKey('dock-${widget.pane.name}-tab'),
      cursor: SystemMouseCursors.basic,
      onTap: () => dock.togglePane(widget.pane),
      builder: (h) => AnimatedBuilder(
        animation: _flash,
        builder: (context, child) {
          // Two soft blinks, fading out.
          final t = _flash.value;
          final glow = _flash.isAnimating ? (0.5 - 0.5 * math.cos(t * 4 * math.pi)) * (1 - t) : 0.0;
          final base = active ? theme.colorScheme.surface : (h ? colors.hover : Colors.transparent);
          return Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Color.lerp(base, theme.colorScheme.primary.withValues(alpha: 0.35), glow),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: active ? colors.separator : Colors.transparent, width: 0.8),
            ),
            child: child,
          );
        },
        child: Tooltip(
          message: widget.compact ? widget.label : '',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: fg),
            if (!widget.compact) ...[
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: active ? FontWeight.w600 : FontWeight.w500),
              ),
            ],
            widget.badge,
          ]),
        ),
      ),
    );
  }
}

class _ActiveStatus extends StatelessWidget {
  final LogSession stream;
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
  return showConfirm(
    context,
    title: n == 1 ? 'End the terminal session?' : 'End $n terminal sessions?',
    message: 'The shell and anything running in it will be stopped.',
    confirmLabel: 'Close',
    confirmKey: const ValueKey('confirm-close-terminal'),
  );
}

class _DockTab extends StatelessWidget {
  final DockTab tab;
  final bool active;
  const _DockTab({required this.tab, required this.active});

  Future<void> _menu(BuildContext context, Offset global) async {
    final dock = context.read<LogDock>();
    PopupMenuItem<String> item(String v, String label, {bool enabled = true}) => PopupMenuItem(value: v, height: 28, enabled: enabled, child: Text(label));
    final v = await showContextMenuAt<String>(context, global, [
      item('close', 'Close'),
      item('others', 'Close others', enabled: dock.tabs.length > 1),
      item('all', 'Close all'),
      const PopupMenuDivider(height: 9),
      item('copy', 'Copy pod name', enabled: tab is! AggregateLogStream),
    ]);
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
    final stream = tab is LogSession ? tab : null;
    final agg = tab is AggregateLogStream ? tab : null;
    final term = tab is TerminalTab ? tab : null;
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) => GestureDetector(
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        onTertiaryTapUp: (_) => closeDockTab(context, dock, tab),
        child: Tooltip(
          message: stream != null
              ? '${stream.namespace}/${stream.label} · ${logPhaseLabel(stream)}${stream.previous ? ' · previous' : ''}'
              : term != null && term.isLocal
                  ? 'Local shell · ${term.commandLabel}${(term.container ?? '').isNotEmpty ? ' · kubectl → ${term.container}' : ''} · ${terminalPhaseLabel(term)}'
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
                    Icon(term?.isLocal ?? false ? Icons.laptop_mac : Icons.terminal, size: 13, color: severityColor(context, term == null ? Severity.neutral : terminalSeverity(term))),
                  if (agg != null) ...[const SizedBox(width: 5), Icon(Icons.layers_outlined, size: 13, color: theme.hintColor)],
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (agg != null)
                            TextSpan(text: agg.label)
                          else if (term != null && term.isLocal) ...[
                            const TextSpan(text: 'local'),
                            if ((term.container ?? '').isNotEmpty) TextSpan(text: ' · ${term.container}', style: TextStyle(color: theme.hintColor)),
                          ] else ...[
                            TextSpan(text: tab.pod),
                            TextSpan(
                              text: '/${(stream is LogStream ? stream.container : null) ?? term?.container ?? ''}',
                              style: TextStyle(color: theme.hintColor),
                            ),
                          ],
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
