import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// A titled, collapsible block in the detail sidebar. Every panel section
/// should be one of these.
class DetailSection extends StatefulWidget {
  final String title;
  final IconData? icon;
  final Widget child;

  /// Shown right of the title (e.g. a count badge or action button).
  final Widget? trailing;
  final bool initiallyExpanded;

  const DetailSection({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.initiallyExpanded = true,
  });

  @override
  State<DetailSection> createState() => _DetailSectionState();
}

class _DetailSectionState extends State<DetailSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(children: [
                Icon(_expanded ? Icons.expand_more : Icons.chevron_right, size: 18, color: theme.hintColor),
                const SizedBox(width: 4),
                if (widget.icon != null) ...[Icon(widget.icon, size: 16, color: theme.colorScheme.primary), const SizedBox(width: 6)],
                Expanded(child: Text(widget.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
                if (widget.trailing != null) widget.trailing!,
              ]),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// A two-column key/value grid. Values may be Strings or Widgets; null and
/// empty-string values are skipped so callers can pass optional fields freely.
class KeyValueTable extends StatelessWidget {
  final List<(String, Object?)> entries;
  final double keyWidth;
  const KeyValueTable(this.entries, {super.key, this.keyWidth = 140});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = entries.where((e) => e.$2 != null && !(e.$2 is String && (e.$2 as String).isEmpty)).toList();
    if (visible.isEmpty) return Text('—', style: TextStyle(color: theme.hintColor));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in visible)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: keyWidth, child: Text(k, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
              Expanded(
                child: v is Widget ? v : SelectableText('$v', style: theme.textTheme.bodySmall),
              ),
            ]),
          ),
      ],
    );
  }
}

/// Coloured pill for a status string; colour is inferred via [severityOf].
class StatusBadge extends StatelessWidget {
  final String text;
  final Severity? severity;
  final bool dense;
  const StatusBadge(this.text, {super.key, this.severity, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, severity ?? severityOf(text));
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(color: c, fontSize: dense ? 11 : 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Wrap of `key=value` chips. Long values are truncated with a tooltip.
class LabelChips extends StatelessWidget {
  final Map<String, dynamic>? labels;
  final String emptyText;
  const LabelChips(this.labels, {super.key, this.emptyText = 'none'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = labels ?? const {};
    if (l.isEmpty) return Text(emptyText, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final e in l.entries) Chipish(text: '${e.key}=${e.value}', copyValue: '${e.key}=${e.value}'),
    ]);
  }
}

/// Small monospace chip; click copies [copyValue] if given.
class Chipish extends StatelessWidget {
  final String text;
  final String? copyValue;
  final Color? color;
  const Chipish({super.key, required this.text, this.copyValue, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = text.length > 80 ? '${text.substring(0, 77)}…' : text;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? theme.colorScheme.secondaryContainer).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(display, style: monoStyle(context, size: 11)),
    );
    final withTip = text.length > 80 ? Tooltip(message: text, child: chip) : chip;
    if (copyValue == null) return withTip;
    return InkWell(onTap: () => copyToClipboard(context, copyValue!), child: withTip);
  }
}

/// Table of status.conditions with badges and relative times.
class ConditionsTable extends StatelessWidget {
  final List<dynamic>? conditions;
  const ConditionsTable(this.conditions, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conds = asMapList(conditions);
    if (conds.isEmpty) return Text('No conditions', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in conds)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${c['type']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                StatusBadge('${c['status']}', dense: true, severity: _condSeverity(c)),
                if (c['reason'] != null) ...[const SizedBox(width: 8), Flexible(child: Text('${c['reason']}', style: theme.textTheme.bodySmall))],
                const Spacer(),
                AgeText(c['lastTransitionTime'] ?? c['lastUpdateTime'] ?? c['lastHeartbeatTime'], suffix: ' ago'),
              ]),
              if ((c['message'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SelectableText('${c['message']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                ),
            ]),
          ),
      ],
    );
  }

  /// Some condition types are "bad when True" (node pressure, Failed, etc.).
  static Severity _condSeverity(Json c) {
    final type = '${c['type']}';
    final status = '${c['status']}';
    const negative = {'MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable', 'Failed', 'ReplicaFailure', 'Stalled', 'Degraded'};
    final bad = negative.contains(type) || type.endsWith('Failed') || type.endsWith('Error');
    if (status == 'Unknown') return Severity.warn;
    final good = (status == 'True') != bad;
    return good ? Severity.ok : (bad ? Severity.error : Severity.warn);
  }
}

/// Relative age that ticks; tooltip shows the absolute time.
class AgeText extends StatefulWidget {
  final dynamic timestamp;
  final String suffix;
  final TextStyle? style;
  const AgeText(this.timestamp, {super.key, this.suffix = '', this.style});

  @override
  State<AgeText> createState() => _AgeTextState();
}

class _AgeTextState extends State<AgeText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = parseTime(widget.timestamp);
    if (t == null) return const SizedBox.shrink();
    final style = widget.style ?? Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
    return Tooltip(message: t.toLocal().toString(), child: Text('${formatAge(t)}${widget.suffix}', style: style));
  }
}

/// Selectable monospace block with a copy button.
class CodeBlock extends StatelessWidget {
  final String text;
  final int? maxLines;
  final bool wrap;
  const CodeBlock(this.text, {super.key, this.maxLines, this.wrap = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = SelectableText(text, style: monoStyle(context), maxLines: maxLines);
    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
      child: Stack(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 34, 8),
          child: wrap ? content : SingleChildScrollView(scrollDirection: Axis.horizontal, child: content),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: IconButton(
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () => copyToClipboard(context, text),
          ),
        ),
      ]),
    );
  }
}

/// Clickable reference to another object; opens it in the sidebar (with
/// back navigation). Renders as plain text if the kind isn't served.
class ResourceLink extends StatelessWidget {
  final ObjectRef ref;
  final String? label;
  const ResourceLink(this.ref, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final text = label ?? '${ref.kind}/${ref.name}';
    final known = app.typeFor(ref.group, ref.kind) != null;
    if (!known) return SelectableText(text, style: theme.textTheme.bodySmall);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => app.openRef(ref),
        child: Text(text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary.withValues(alpha: 0.4),
            )),
      ),
    );
  }
}

/// Collapsible tree for arbitrary JSON values (spec/status of CRs, etc.).
class JsonTree extends StatelessWidget {
  final dynamic value;
  final int initiallyExpandedDepth;
  const JsonTree(this.value, {super.key, this.initiallyExpandedDepth = 1});

  @override
  Widget build(BuildContext context) => _JsonNode(name: null, value: value, depth: 0, expandDepth: initiallyExpandedDepth);
}

class _JsonNode extends StatefulWidget {
  final String? name;
  final dynamic value;
  final int depth;
  final int expandDepth;
  const _JsonNode({required this.name, required this.value, required this.depth, required this.expandDepth});

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool _open = widget.depth < widget.expandDepth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.value;
    final keyStyle = monoStyle(context, color: theme.colorScheme.primary);
    final isContainer = v is Map || v is List;
    if (!isContainer) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.name != null) Text('${widget.name}: ', style: keyStyle),
          Expanded(child: SelectableText(_scalar(v), style: monoStyle(context, color: _scalarColor(context, v)))),
        ]),
      );
    }
    final entries = v is Map ? v.entries.map((e) => (e.key.toString(), e.value)).toList() : [for (var i = 0; i < (v as List).length; i++) ('[$i]', v[i])];
    if (widget.depth == 0 && widget.name == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (k, child) in entries) _JsonNode(name: k, value: child, depth: 1, expandDepth: widget.expandDepth),
        if (entries.isEmpty) Text(v is Map ? '{}' : '[]', style: monoStyle(context)),
      ]);
    }
    final summary = v is Map ? '{${entries.length}}' : '[${entries.length}]';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Row(children: [
          Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 16, color: theme.hintColor),
          Text('${widget.name}', style: keyStyle),
          const SizedBox(width: 6),
          Text(summary, style: monoStyle(context, color: theme.hintColor)),
        ]),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (k, child) in entries) _JsonNode(name: k, value: child, depth: widget.depth + 1, expandDepth: widget.expandDepth),
          ]),
        ),
    ]);
  }

  static String _scalar(dynamic v) => v is String ? v : jsonEncode(v);

  static Color? _scalarColor(BuildContext context, dynamic v) {
    if (v is num) return Colors.orange.shade300;
    if (v is bool) return Colors.purple.shade200;
    if (v == null) return Theme.of(context).hintColor;
    return null;
  }
}

/// Placeholder / empty / error states for async sections.
class InlineMessage extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool isError;
  const InlineMessage(this.text, {super.key, this.icon = Icons.info_outline, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = isError ? theme.colorScheme.error : theme.hintColor;
    return Row(children: [
      Icon(isError ? Icons.error_outline : icon, size: 16, color: c),
      const SizedBox(width: 6),
      Expanded(child: SelectableText(text, style: theme.textTheme.bodySmall?.copyWith(color: c))),
    ]);
  }
}

/// Runs [future] and renders loading / error / data states.
class AsyncSection<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const AsyncSection({super.key, required this.future, required this.builder});

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

void copyToClipboard(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('Copied ${text.length > 40 ? '${text.substring(0, 40)}…' : text}'), duration: const Duration(seconds: 1)));
}
