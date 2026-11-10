import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/context_menu.dart';

/// The quiet line under the inspector's title, for every kind: the
/// namespace (opens it; none for cluster-scoped objects), the age (ticking,
/// the creation time in its tooltip) and the labels as faint `key=value`
/// chips, as many as fit on two lines, then "+N", which shows the rest
/// inline. Bookkeeping labels ([isNoisyLabel]) sort last and stay under +N
/// unless there are no others. Right-click a label: filter the table by it,
/// or copy it. The full metadata stays in the Overview's Metadata section.
///
/// Key it by the object's uid: "+N" open is per object.
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
  bool _all = false;

  static const _gap = 6.0;
  static const _chipPad = 10.0;
  static const _iconW = 16.0; // 12px icon + 4px gap

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final mono = monoStyle(context, size: 11);
    final meta = asMap(dig(widget.object, ['metadata']));
    final ns = widget.namespace ?? meta['namespace'] as String?;
    final created = parseTime(meta['creationTimestamp']);
    final labels = [for (final e in asMap(meta['labels']).entries) (k: e.key, v: '${e.value}')];
    final quiet = [for (final l in labels) if (!isNoisyLabel(l.k)) l];
    final noisy = [for (final l in labels) if (isNoisyLabel(l.k)) l];
    final ordered = [...quiet, ...noisy];
    if (ns == null && created == null && labels.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
      child: LayoutBuilder(builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context);
        double textW(String s, TextStyle? style) =>
            (TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, textScaler: scale)..layout()).width;
        final maxW = box.maxWidth - 2;
        final lead = [
          if (ns != null) _iconW + textW(ns, hint),
          if (created != null) _iconW + textW(formatAge(created), hint),
        ];
        double chipW(({String k, String v}) l) => textW(shortLabel(l.k, l.v), mono) + _chipPad;

        // Collapsed: the quiet labels (or, with none, the rest) that fit on
        // two lines with "+N" after them.
        var shown = ordered;
        if (!_all) {
          final candidates = quiet.isNotEmpty ? quiet : noisy;
          var n = candidates.length;
          while (n > 0) {
            final hidden = labels.length - n;
            final widths = [...lead, for (final l in candidates.take(n)) chipW(l), if (hidden > 0) textW('+$hidden', hint) + 8];
            if (_lines(widths, maxW) <= 2) break;
            n--;
          }
          shown = candidates.take(n).toList();
        }
        final hidden = labels.length - shown.length;

        final strip = Wrap(spacing: _gap, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (ns != null)
            _Lead(
              key: const ValueKey('identity-namespace'),
              icon: Icons.folder_outlined,
              tooltip: 'Open namespace $ns',
              onTap: () => context.read<AppState>().openRef(ObjectRef(kind: 'Namespace', name: ns)),
              child: Text(ns, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
            ),
          if (created != null)
            _Lead(
              key: const ValueKey('identity-age'),
              icon: Icons.schedule,
              child: AgeText(meta['creationTimestamp'], style: hint),
            ),
          for (final l in shown) _LabelChip(type: widget.type, k: l.k, v: l.v, dim: isNoisyLabel(l.k), maxWidth: maxW, max: _all ? 72 : 36),
          if (hidden > 0 || _all)
            Hoverable(
              key: const ValueKey('identity-more'),
              onTap: () => setState(() => _all = !_all),
              builder: (h) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(_all ? 'less' : '+$hidden', style: hint?.copyWith(color: h ? theme.colorScheme.primary : colors.faint)),
              ),
            ),
        ]);
        // Open, a long list scrolls rather than push the tabs off screen.
        return !_all ? strip : ConstrainedBox(constraints: const BoxConstraints(maxHeight: 132), child: SingleChildScrollView(child: strip));
      }),
    );
  }

  /// How many lines [widths] take in a Wrap of [maxW] with [_gap] spacing.
  static int _lines(List<double> widths, double maxW) {
    var lines = 1;
    var x = 0.0;
    for (final raw in widths) {
      final w = raw > maxW ? maxW : raw;
      if (x == 0) {
        x = w;
      } else if (x + _gap + w <= maxW) {
        x += _gap + w;
      } else {
        lines++;
        x = w;
      }
    }
    return lines;
  }
}

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

/// One label as a borderless, softly filled chip; click copies it,
/// right-click offers "Filter by this label" and "Copy".
class _LabelChip extends StatelessWidget {
  final ResourceType type;
  final String k;
  final String v;
  final bool dim;
  final double maxWidth;
  final int max;
  const _LabelChip({required this.type, required this.k, required this.v, required this.dim, required this.maxWidth, required this.max});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final full = '$k=$v';
    final text = shortLabel(k, v, max: max);
    final eq = text.indexOf('=');
    final chip = Hoverable(
      onTap: () => copyToClipboard(context, full),
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition, full),
      builder: (h) => Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: chipFill(context, hovered: h), borderRadius: BorderRadius.circular(4)),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: text.substring(0, eq + 1), style: TextStyle(color: colors.faint)),
            TextSpan(text: text.substring(eq + 1), style: TextStyle(color: dim ? colors.faint : theme.hintColor)),
          ]),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: monoStyle(context, size: 11),
        ),
      ),
    );
    return Tooltip(message: full, waitDuration: const Duration(milliseconds: 600), child: chip);
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
