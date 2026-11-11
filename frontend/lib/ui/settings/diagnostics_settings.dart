/// Settings ▸ Diagnostics: the errors k8sman ran into, grouped, newest
/// first, with a redacted report to copy or file as a GitHub issue. Kept on
/// this machine; nothing is sent unless the user does it here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/diagnostics/diagnostics_log.dart';
import '../../util/format.dart' show formatAgo;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show tabularFigures;
import 'settings_widgets.dart';

List<SettingItem> diagnosticsSettings() => [
      SettingItem(
        key: const ValueKey('settings-diagnostics-actions'),
        label: 'Report',
        description: 'Copy a redacted report, or open a GitHub issue with it filled in.',
        keywords: const ['diagnostics', 'errors', 'crash', 'bug', 'report', 'issue', 'github', 'overflow', 'exception'],
        builder: (context) => const _Actions(),
      ),
      SettingItem(
        key: const ValueKey('settings-diagnostics-groups'),
        group: 'Errors',
        label: 'Errors',
        keywords: const ['diagnostics', 'errors', 'exceptions', 'overflow', 'duplicate key'],
        builder: (context) => const _Groups(),
      ),
    ];

class _Actions extends StatelessWidget {
  const _Actions();

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: diagnostics.report()));
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  Future<void> _issue(BuildContext context) async {
    final (:url, :full) = diagnostics.issueUrl();
    // Too long for a URL: the full report goes on the clipboard instead.
    if (!full) await Clipboard.setData(ClipboardData(text: diagnostics.report()));
    await launchUrl(url);
    if (!full && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('The report is on the clipboard: paste it into the issue')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: diagnostics,
        builder: (context, _) {
          final empty = diagnostics.isEmpty;
          return SettingRow(
            label: 'Report',
            description: 'Errors stay on this computer. Names, namespaces, addresses and hosts are replaced by placeholders; '
                'nothing is sent unless you copy the report or open an issue.',
            trailing: Wrap(spacing: 4, children: [
              TextButton(key: const ValueKey('diagnostics-copy'), onPressed: empty ? null : () => _copy(context), child: const Text('Copy report')),
              TextButton(key: const ValueKey('diagnostics-issue'), onPressed: empty ? null : () => _issue(context), child: const Text('Open GitHub issue')),
              TextButton(key: const ValueKey('diagnostics-clear'), onPressed: empty ? null : diagnostics.clear, child: const Text('Clear')),
            ]),
          );
        },
      );
}

class _Groups extends StatefulWidget {
  const _Groups();

  @override
  State<_Groups> createState() => _GroupsState();
}

class _GroupsState extends State<_Groups> {
  final _open = <String>{};

  @override
  void initState() {
    super.initState();
    diagnostics.addListener(_seen);
    _seen();
  }

  /// Everything listed here has been seen.
  void _seen() {
    if (diagnostics.unseen > 0) WidgetsBinding.instance.addPostFrameCallback((_) => diagnostics.markViewed());
  }

  @override
  void dispose() {
    diagnostics.removeListener(_seen);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: diagnostics,
        builder: (context, _) {
          final groups = diagnostics.groups;
          if (groups.isEmpty) return const SettingsEmpty('No errors recorded.');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, g) in groups.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.of(context).separator.withValues(alpha: 0.6)),
              _GroupRow(
                key: ValueKey('diagnostics-group-${g.signature}'),
                group: g,
                open: _open.contains(g.signature),
                onTap: () => setState(() => _open.contains(g.signature) ? _open.remove(g.signature) : _open.add(g.signature)),
              ),
            ],
          ]);
        },
      );
}

IconData _icon(String kind) => switch (kind) {
      'overflow' => Icons.width_full_outlined,
      'duplicate-key' => Icons.key_outlined,
      'layout' => Icons.dashboard_outlined,
      'paint' => Icons.brush_outlined,
      'async' => Icons.sync_problem_outlined,
      _ => Icons.error_outline,
    };

class _GroupRow extends StatelessWidget {
  final DiagnosticGroup group;
  final bool open;
  final VoidCallback onTap;
  const _GroupRow({super.key, required this.group, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final g = group;
    final sub = [if (g.context.isNotEmpty) g.context, if (g.location.isNotEmpty) g.location].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Hoverable(
        onTap: onTap,
        builder: (h) => Container(
          color: h ? AppColors.of(context).hover : null,
          padding: const EdgeInsets.fromLTRB(2, 9, 2, 9),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 15, color: theme.hintColor),
            const SizedBox(width: 4),
            Icon(_icon(g.kind), size: 15, color: theme.colorScheme.error.withValues(alpha: 0.85)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
              ]),
            ),
            const SizedBox(width: 12),
            Text('×${g.count}', style: hint?.copyWith(fontFeatures: tabularFigures)),
            const SizedBox(width: 12),
            SizedBox(width: 64, child: Text(formatAgo(g.lastSeen), textAlign: TextAlign.right, style: hint)),
          ]),
        ),
      ),
      if (open) _Sample(g),
    ]);
  }
}

/// The sample message and stack, monospaced, selectable and scrolling.
class _Sample extends StatelessWidget {
  final DiagnosticGroup g;
  const _Sample(this.g);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monoStyle(context, size: 11.5).copyWith(height: 1.4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(31, 0, 2, 12),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 280),
        decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(6)),
        child: Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: SelectionArea(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('First seen ${formatAgo(g.firstSeen)} · k8sman ${g.appVersion}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 6),
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: Text(g.message.trim(), style: mono)),
                if (g.stack.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(scrollDirection: Axis.horizontal, child: Text(g.stack.trim(), style: mono.copyWith(color: theme.hintColor))),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Debug builds: a small count of error groups new since Diagnostics was
/// last viewed; tapping opens it. Nothing in release builds.
class DiagnosticsBadge extends StatelessWidget {
  final VoidCallback onTap;
  const DiagnosticsBadge({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: diagnostics,
      builder: (context, _) {
        final n = diagnostics.unseen;
        if (n == 0) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Tooltip(
          message: n == 1 ? '1 new error (debug build): open Diagnostics' : '$n new errors (debug build): open Diagnostics',
          child: Hoverable(
            key: const ValueKey('diagnostics-badge'),
            onTap: onTap,
            builder: (h) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: theme.colorScheme.error.withValues(alpha: h ? 1 : 0.85), borderRadius: BorderRadius.circular(8)),
              child: Text('$n', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onError, fontWeight: FontWeight.w600, fontSize: 10)),
            ),
          ),
        );
      },
    );
  }
}
