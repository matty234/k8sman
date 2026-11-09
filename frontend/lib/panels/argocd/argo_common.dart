/// Shared Argo CD helpers: status colours/icons, source/destination
/// formatting and small widgets used by the Application, ApplicationSet and
/// AppProject panels.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';

const argoGroup = 'argoproj.io';
const applicationsRef = ResourceRef(group: argoGroup, resource: 'applications');
const inClusterServer = 'https://kubernetes.default.svc';

// ---------------------------------------------------------------------------
// Status styling (Argo CD UI colours and icon vocabulary)
// ---------------------------------------------------------------------------

/// Visual style of one Argo status value.
class ArgoStyle {
  final IconData icon;
  final Color color;
  final Severity severity;
  const ArgoStyle(this.icon, this.color, this.severity);
}

Color _pick(BuildContext context, int dark, int light) => Color(Theme.of(context).brightness == Brightness.dark ? dark : light);

/// Health: Healthy / Progressing / Degraded / Suspended / Missing / Unknown.
ArgoStyle healthStyle(BuildContext context, String? status) {
  switch (status) {
    case 'Healthy':
      return ArgoStyle(Icons.favorite, _pick(context, 0xFF18BE94, 0xFF0E8F6E), Severity.ok);
    case 'Progressing':
      return ArgoStyle(Icons.autorenew, _pick(context, 0xFF0DADEA, 0xFF0A7FB0), Severity.info);
    case 'Degraded':
      return ArgoStyle(Icons.heart_broken, _pick(context, 0xFFE96D76, 0xFFC93A45), Severity.error);
    case 'Suspended':
      return ArgoStyle(Icons.pause_circle, _pick(context, 0xFF9C94C4, 0xFF5E5689), Severity.neutral);
    case 'Missing':
      return ArgoStyle(Icons.visibility_off, _pick(context, 0xFFF4C030, 0xFFA67C00), Severity.warn);
    default:
      return ArgoStyle(Icons.help, _pick(context, 0xFF9AA6AF, 0xFF6B7780), Severity.neutral);
  }
}

/// Sync: Synced / OutOfSync / Unknown.
ArgoStyle syncStyle(BuildContext context, String? status) {
  switch (status) {
    case 'Synced':
      return ArgoStyle(Icons.check_circle, _pick(context, 0xFF18BE94, 0xFF0E8F6E), Severity.ok);
    case 'OutOfSync':
      return ArgoStyle(Icons.arrow_circle_up, _pick(context, 0xFFF4C030, 0xFFA67C00), Severity.warn);
    default:
      return ArgoStyle(Icons.help, _pick(context, 0xFF9AA6AF, 0xFF6B7780), Severity.neutral);
  }
}

/// Operation phase: Running / Terminating / Succeeded / Failed / Error.
ArgoStyle phaseStyle(BuildContext context, String? phase) {
  switch (phase) {
    case 'Succeeded':
      return ArgoStyle(Icons.check_circle, _pick(context, 0xFF18BE94, 0xFF0E8F6E), Severity.ok);
    case 'Running':
      return ArgoStyle(Icons.sync, _pick(context, 0xFF0DADEA, 0xFF0A7FB0), Severity.info);
    case 'Terminating':
      return ArgoStyle(Icons.stop_circle, _pick(context, 0xFFF4C030, 0xFFA67C00), Severity.warn);
    case 'Failed':
    case 'Error':
      return ArgoStyle(Icons.cancel, _pick(context, 0xFFE96D76, 0xFFC93A45), Severity.error);
    default:
      return ArgoStyle(Icons.help, _pick(context, 0xFF9AA6AF, 0xFF6B7780), Severity.neutral);
  }
}

/// Icon + text in the status colour. [large] is the header treatment (a
/// tinted pill); otherwise it is a compact inline badge for lists.
class ArgoBadge extends StatelessWidget {
  final ArgoStyle style;
  final String text;
  final bool large;
  final String? tooltip;

  /// Only the icon (narrow layouts); the text moves to the tooltip.
  final bool iconOnly;
  const ArgoBadge(this.style, this.text, {super.key, this.large = false, this.tooltip, this.iconOnly = false});

  factory ArgoBadge.health(BuildContext context, String? status, {bool large = false, String? tooltip, bool iconOnly = false}) =>
      ArgoBadge(healthStyle(context, status), status == null || status.isEmpty ? 'Unknown' : status, large: large, tooltip: tooltip, iconOnly: iconOnly);
  factory ArgoBadge.sync(BuildContext context, String? status, {bool large = false, String? tooltip, bool iconOnly = false}) =>
      ArgoBadge(syncStyle(context, status), status == null || status.isEmpty ? 'Unknown' : status, large: large, tooltip: tooltip, iconOnly: iconOnly);
  factory ArgoBadge.phase(BuildContext context, String? phase, {bool large = false}) =>
      ArgoBadge(phaseStyle(context, phase), phase == null || phase.isEmpty ? 'Unknown' : phase, large: large);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = style.color;
    Widget body;
    if (iconOnly) {
      return Tooltip(message: tooltip ?? text, child: Icon(style.icon, size: 14, color: c));
    } else if (large) {
      body = Container(
        padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(style.icon, size: 16, color: c),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: c, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
    } else {
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(style.icon, size: 13, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: c, fontWeight: FontWeight.w500)),
        ),
      ]);
    }
    return tooltip == null ? body : Tooltip(message: tooltip!, child: body);
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/// First 7 characters of a git SHA; other revisions (tags, chart versions,
/// `HEAD`) are returned unchanged.
String shortRevision(String? rev) {
  if (rev == null) return '';
  return RegExp(r'^[0-9a-f]{40}$').hasMatch(rev) ? rev.substring(0, 7) : rev;
}

/// `https://github.com/org/repo.git` → `org/repo`.
String shortRepo(String? url) {
  if (url == null || url.isEmpty) return '';
  var s = url.replaceFirst(RegExp(r'\.git$'), '').replaceFirst(RegExp(r'/+$'), '');
  s = s.replaceFirst(RegExp(r'^[a-z+]+://'), '').replaceFirst(RegExp(r'^git@'), '');
  final parts = s.split(RegExp(r'[/:]'));
  return parts.length > 2 ? parts.sublist(parts.length - 2).join('/') : s;
}

/// Cluster for a destination: the name, else the server (in-cluster for the
/// local API server).
String destinationCluster(Json dest) {
  final name = dest['name'] as String?;
  if (name != null && name.isNotEmpty) return name;
  final server = dest['server'] as String? ?? '';
  if (server == inClusterServer) return 'in-cluster';
  return server.isEmpty ? '*' : server;
}

/// The app's sources (single `source` or multi-source `sources`).
List<Json> appSources(Json spec) {
  final multi = asMapList(spec['sources']);
  if (multi.isNotEmpty) return multi;
  final single = asMap(spec['source']);
  return single.isEmpty ? const [] : [single];
}

/// Whether `syncPolicy.automated` is on (Argo CD 3 allows `enabled: false`).
bool autoSyncEnabled(Json spec) {
  final auto = dig(spec, ['syncPolicy', 'automated']);
  if (auto is! Map) return false;
  return auto['enabled'] != false;
}

/// Argo app conditions have no status field: the type says how bad it is.
Severity argoConditionSeverity(String type) {
  if (type.endsWith('Error')) return Severity.error;
  if (type.endsWith('Warning')) return Severity.warn;
  return Severity.info;
}

/// `5m30s`-style duration between two timestamps (or now).
String? elapsed(dynamic start, dynamic end) {
  final s = parseTime(start);
  if (s == null) return null;
  final e = parseTime(end) ?? DateTime.now().toUtc();
  return formatDuration(e.difference(s));
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------

/// Monospace chip that copies [copy] (default [text]) on click.
class CopyChip extends StatelessWidget {
  final String text;
  final String? copy;
  final String? tooltip;
  final bool mono;
  const CopyChip(this.text, {super.key, this.copy, this.tooltip, this.mono = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = copy ?? text;
    // Hug the text even when the parent hands down a tight width.
    return Align(alignment: Alignment.centerLeft, widthFactor: 1, child: _chip(context, theme, value));
  }

  Widget _chip(BuildContext context, ThemeData theme, String value) {
    return Tooltip(
      message: tooltip ?? 'Copy $value',
      child: Hoverable(
        onTap: () => copyToClipboard(context, value),
        builder: (h) => Container(
          padding: const EdgeInsets.fromLTRB(6, 1, 5, 1),
          decoration: BoxDecoration(color: chipFill(context, hovered: h), borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono ? monoStyle(context, size: 11.5) : theme.textTheme.bodySmall),
            ),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, size: 11, color: theme.hintColor),
          ]),
        ),
      ),
    );
  }
}

/// Small on/off flag ("✓ Prune" / "✗ Self-heal").
class FlagChip extends StatelessWidget {
  final String label;
  final bool on;
  final String? tooltip;
  const FlagChip(this.label, this.on, {super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = on ? severityColor(context, Severity.ok) : theme.hintColor;
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(4, 1, 7, 1),
      decoration: BoxDecoration(
        color: on ? c.withValues(alpha: 0.12) : chipFill(context),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(on ? Icons.check : Icons.close, size: 12, color: c),
        const SizedBox(width: 3),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: on ? c : theme.hintColor, fontWeight: on ? FontWeight.w500 : null)),
      ]),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Muted helper text.
class Hint extends StatelessWidget {
  final String text;
  const Hint(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor));
}

/// Wraps children with consistent spacing.
class Chips extends StatelessWidget {
  final List<Widget> children;
  const Chips(this.children, {super.key});
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: children);
}

/// A ResourceLink that ellipsizes instead of wrapping.
class OneLineRef extends StatelessWidget {
  final ObjectRef ref;
  final String? label;
  const OneLineRef(this.ref, {super.key, this.label});

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        child: Tooltip(message: '${ref.kind}/${ref.name}', child: ResourceLink(ref, label: label ?? ref.name)),
      );
}

/// FutureBuilder that keeps showing the last data while refetching.
class KeptFuture<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const KeptFuture({super.key, required this.future, required this.builder});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return builder(context, snap.data as T);
        },
      );
}

/// A row of an Application with its sync and health, for AppSet/Project lists.
class AppRow extends StatelessWidget {
  final Json app;
  const AppRow(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final name = dig<String>(app, ['metadata', 'name']) ?? '';
    final ns = dig<String>(app, ['metadata', 'namespace']);
    final sync = dig<String>(app, ['status', 'sync', 'status']);
    final health = dig<String>(app, ['status', 'health', 'status']);
    final dest = asMap(dig(app, ['spec', 'destination']));
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 400;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
            flex: 5,
            child: OneLineRef(ObjectRef(group: argoGroup, kind: 'Application', name: name, namespace: ns)),
          ),
          if (!narrow) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: Text('${destinationCluster(dest)}/${dest['namespace'] ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
            ),
          ],
          const SizedBox(width: 8),
          SizedBox(width: narrow ? 22 : 92, child: ArgoBadge.sync(context, sync, iconOnly: narrow)),
          SizedBox(width: narrow ? 22 : 92, child: ArgoBadge.health(context, health, iconOnly: narrow)),
        ]),
      );
    });
  }
}

/// Sorts apps worst first (Degraded/Missing/OutOfSync), then by name.
int compareAppsWorstFirst(Json a, Json b) {
  int rank(Json x) {
    final h = dig<String>(x, ['status', 'health', 'status']);
    final s = dig<String>(x, ['status', 'sync', 'status']);
    if (h == 'Degraded') return 0;
    if (h == 'Missing') return 1;
    if (s == 'OutOfSync' || s == 'Unknown') return 2;
    if (h == 'Progressing') return 3;
    return 4;
  }

  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  return '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}');
}
