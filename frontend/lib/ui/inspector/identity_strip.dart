import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/context_menu.dart';

/// The quiet line under the inspector's title, for every kind, on one
/// line: the namespace (opens it; none for cluster-scoped objects), the age
/// (ticking, the creation time in its tooltip), then the values of the few
/// labels that name the object (app, component, version…; the key in the
/// tooltip) and "+N" / "N labels", which lists every label (click one to
/// filter the table by it). The full metadata stays in the Overview's
/// Metadata section.
class IdentityStrip extends StatefulWidget {
  final ResourceType type;
  final String? namespace;

  /// The live object, or null while it loads (the namespace still shows).
  final Json? object;
  const IdentityStrip({super.key, required this.type, this.namespace, this.object});

  @override
  State<IdentityStrip> createState() => _IdentityStripState();
}

/// Labels set by controllers and tooling rather than people: hashes,
/// generations, Helm/managed-by bookkeeping and the well-known
/// `kubernetes.io/` node and namespace labels.
bool isNoisyLabel(String key) =>
    _noisyKeys.contains(key) || _noisyPrefixes.any(key.startsWith);

const _noisyKeys = {
  'pod-template-hash',
  'pod-template-generation',
  'controller-revision-hash',
  'controller-uid',
  'job-name',
  'app.kubernetes.io/managed-by',
  'helm.sh/chart',
  'chart',
  'heritage',
  'statefulset.kubernetes.io/pod-name',
  'apps.kubernetes.io/pod-index',
  'batch.kubernetes.io/controller-uid',
  'batch.kubernetes.io/job-name',
};
const _noisyPrefixes = ['kubernetes.io/', 'beta.kubernetes.io/', 'node.kubernetes.io/', 'topology.kubernetes.io/', 'failure-domain.beta.kubernetes.io/'];

/// "key=value" in at most [max] characters: shortened in the middle (both
/// ends tell values apart), the value first, the key kept to most of it.
String shortLabel(String k, String v, {int max = 36}) {
  String mid(String s, int n) => s.length <= n ? s : '${s.substring(0, (n - 1) ~/ 2)}…${s.substring(s.length - (n - 1 - (n - 1) ~/ 2))}';
  if (k.length + 1 + v.length <= max) return '$k=$v';
  final kb = k.length.clamp(0, (max - 1 - v.length).clamp(max * 3 ~/ 5, max));
  return '${mid(k, kb)}=${mid(v, max - 1 - kb)}';
}

class _IdentityStripState extends State<IdentityStrip> {
  static const _sep = 14.0; // " · " between items
  static const _iconW = 16.0; // 12px icon + 4px gap

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final meta = asMap(dig(widget.object, ['metadata']));
    final ns = widget.namespace ?? meta['namespace'] as String?;
    final created = parseTime(meta['creationTimestamp']);
    final labels = [for (final e in asMap(meta['labels']).entries) (k: e.key, v: '${e.value}')];
    final quiet = [for (final l in labels) if (!isNoisyLabel(l.k)) l];
    final noisy = [for (final l in labels) if (isNoisyLabel(l.k)) l];
    if (ns == null && created == null && labels.isEmpty) return const SizedBox.shrink();

    // Up front: the values of the few labels that name the thing (app,
    // component, version…), at most three, deduplicated. The rest are one
    // click away in a list.
    final named = <({String k, String v})>[];
    for (final key in _nameKeys) {
      final l = quiet.where((l) => l.k == key).firstOrNull;
      if (l != null && l.v.isNotEmpty && !named.any((n) => n.v == l.v)) named.add(l);
      if (named.length == 3) break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
      child: LayoutBuilder(builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context);
        double textW(String s) =>
            (TextPainter(text: TextSpan(text: s, style: hint), textDirection: TextDirection.ltr, maxLines: 1, textScaler: scale)..layout()).width;
        String countText(int shown) => shown == 0 ? (labels.length == 1 ? '1 label' : '${labels.length} labels') : '+${labels.length - shown}';
        var used = (ns == null ? 0 : _iconW + textW(ns)) + (created == null ? 0 : _sep + _iconW + textW(formatAge(created)));
        var n = 0;
        if (labels.isNotEmpty) {
          used += _sep + _iconW;
          while (n < named.length) {
            final rest = labels.length - (n + 1);
            final w = textW(named[n].v) + (n > 0 ? _sep : 0) + (rest > 0 ? 6 + textW('+$rest') : 0);
            if (used + w > box.maxWidth) break;
            used += textW(named[n].v) + (n > 0 ? _sep : 0);
            n++;
          }
        }
        final shown = named.take(n).toList();
        final more = labels.length - shown.length;
        Widget dot() => Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: Text('·', style: hint?.copyWith(color: colors.faint)));

        return Row(children: [
          if (ns != null)
            Flexible(
              child: _Lead(
                key: const ValueKey('identity-namespace'),
                icon: Icons.folder_outlined,
                tooltip: 'Open namespace $ns',
                onTap: () => context.read<AppState>().openRef(ObjectRef(kind: 'Namespace', name: ns)),
                // A touch stronger than the rest of the line: it's part of the name.
                child: Text(ns, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint?.copyWith(color: Color.lerp(theme.hintColor, theme.textTheme.bodyMedium?.color, 0.35), fontWeight: FontWeight.w500)),
              ),
            ),
          if (created != null) ...[
            if (ns != null) dot(),
            _Lead(key: const ValueKey('identity-age'), icon: Icons.schedule, child: AgeText(meta['creationTimestamp'], style: hint)),
          ],
          if (labels.isNotEmpty) ...[
            if (ns != null || created != null) dot(),
            Icon(Icons.sell_outlined, size: 12, color: colors.faint),
            const SizedBox(width: 4),
            for (final (i, l) in shown.indexed) ...[
              if (i > 0) dot(),
              Flexible(child: _LabelValue(type: widget.type, k: l.k, v: l.v)),
            ],
            if (more > 0)
              Builder(
                builder: (anchor) => Hoverable(
                  key: const ValueKey('identity-more'),
                  onTap: () => _showAll(anchor, [...quiet, ...noisy]),
                  builder: (h) => Padding(
                    padding: EdgeInsets.only(left: shown.isEmpty ? 0 : 6),
                    child: Text(countText(shown.length), style: hint?.copyWith(color: h ? theme.colorScheme.primary : colors.faint)),
                  ),
                ),
              ),
          ],
        ]);
      }),
    );
  }

  /// Every label in a list under [anchor]: click one to filter the table
  /// by it; the last row copies them all.
  Future<void> _showAll(BuildContext anchor, List<({String k, String v})> all) async {
    final app = context.read<AppState>();
    final box = anchor.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height + 4));
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final mono = monoStyle(context, size: 11.5);
    final chosen = await showContextMenuAt<VoidCallback>(anchor, at, [
      for (final l in all)
        PopupMenuItem<VoidCallback>(
          height: 28,
          value: () => app.filterTable(widget.type, '${l.k}=${l.v}'),
          child: Tooltip(
            message: 'Filter by ${l.k}=${l.v}',
            waitDuration: const Duration(milliseconds: 600),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${l.k}=', style: TextStyle(color: colors.faint)),
                TextSpan(text: l.v, style: TextStyle(color: isNoisyLabel(l.k) ? colors.faint : theme.textTheme.bodyMedium?.color)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono,
            ),
          ),
        ),
      const PopupMenuDivider(height: 8),
      menuItem(() => copyToClipboard(context, [for (final l in all) '${l.k}=${l.v}'].join('\n')), Icons.content_copy, 'Copy all labels'),
    ], constraints: const BoxConstraints(minWidth: 200, maxWidth: 420));
    if (chosen != null && mounted) chosen();
  }
}

/// Label keys whose values name the object, in the order they're shown.
const _nameKeys = [
  'app.kubernetes.io/name',
  'app',
  'k8s-app',
  'app.kubernetes.io/component',
  'component',
  'tier',
  'app.kubernetes.io/version',
  'version',
  'app.kubernetes.io/part-of',
  'team',
];

/// A small hint-coloured icon and its value (namespace, age).
class _Lead extends StatelessWidget {
  final IconData icon;
  final Widget child;
  final String? tooltip;
  final VoidCallback? onTap;
  const _Lead({super.key, required this.icon, required this.child, this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    final faint = AppColors.of(context).faint;
    Widget row(bool h) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: faint),
          const SizedBox(width: 4),
          Flexible(
            child: DefaultTextStyle.merge(
              style: TextStyle(decoration: h ? TextDecoration.underline : null, decorationColor: Theme.of(context).hintColor),
              child: child,
            ),
          ),
        ]);
    final body = onTap == null ? row(false) : Hoverable(onTap: onTap, builder: row);
    return tooltip == null ? body : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: body);
  }
}

/// One label's value, plain hint text; the key is in the tooltip. Click
/// copies `key=value`; right-click offers "Filter by this label" and "Copy".
class _LabelValue extends StatelessWidget {
  final ResourceType type;
  final String k;
  final String v;
  const _LabelValue({required this.type, required this.k, required this.v});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = '$k=$v';
    return Tooltip(
      message: full,
      waitDuration: const Duration(milliseconds: 500),
      child: Hoverable(
        onTap: () => copyToClipboard(context, full),
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition, full),
        builder: (h) => Text(v,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.textTheme.bodyMedium?.color : theme.hintColor)),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset at, String full) async {
    final app = context.read<AppState>();
    final chosen = await showContextMenuAt<VoidCallback>(context, at, [
      menuItem(() => app.filterTable(type, full), Icons.filter_alt_outlined, 'Filter by this label'),
      menuItem(() => copyToClipboard(context, full), Icons.content_copy, 'Copy'),
    ]);
    if (chosen != null && context.mounted) chosen();
  }
}
