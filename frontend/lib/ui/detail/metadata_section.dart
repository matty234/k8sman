import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../panels/panel.dart';
import '../inspector/inspector.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import '../widgets/common.dart';

/// The shared Metadata section, last on every inspector's Overview:
/// collapsed to a one-line summary ("7 labels · 2 annotations"); open, one
/// compact grid of facts (name, namespace, age, owners, API details), then
/// labels and annotations as key/value grids. Values sit on one line and
/// expand on click (JSON pretty-printed); copy on hover. Bookkeeping
/// annotations fold into a closed "N system annotations" row at the end.
/// The open state is remembered for the session.
class MetadataSection extends StatelessWidget {
  final PanelContext ctx;
  const MetadataSection({super.key, required this.ctx});

  /// "7 labels · 2 annotations" (the age is in the identity strip).
  static String summary(Json m) {
    final labels = asMap(m['labels']).length;
    final annotations = asMap(m['annotations']).length;
    final finalizers = (m['finalizers'] as List?)?.length ?? 0;
    return [
      labels == 0 ? 'no labels' : plural(labels, 'label'),
      if (annotations > 0) plural(annotations, 'annotation'),
      if (finalizers > 0) plural(finalizers, 'finalizer'),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final m = ctx.metadata;
    return InspectorSection(
      key: const ValueKey('metadata-section'),
      id: 'metadata',
      title: 'Metadata',
      initiallyExpanded: false,
      trailing: SectionSummary(summary(m)),
      child: _MetadataBody(ctx),
    );
  }
}

/// Annotations written by kubectl, controllers and tooling rather than
/// people; listed after the rest, folded.
bool isSystemAnnotation(String key) => _systemAnnotations.contains(key) || _systemAnnotationPrefixes.any(key.startsWith);

const _systemAnnotations = {
  'kubectl.kubernetes.io/last-applied-configuration',
  'kubectl.kubernetes.io/restartedAt',
  'deployment.kubernetes.io/revision',
  'deployment.kubernetes.io/desired-replicas',
  'deployment.kubernetes.io/max-replicas',
  'deprecated.daemonset.template.generation',
  'rollout.argoproj.io/revision',
  'argocd.argoproj.io/tracking-id',
  'meta.helm.sh/release-name',
  'meta.helm.sh/release-namespace',
  'endpoints.kubernetes.io/last-change-trigger-time',
  'control-plane.alpha.kubernetes.io/leader',
};
const _systemAnnotationPrefixes = [
  'pv.kubernetes.io/',
  'volume.kubernetes.io/',
  'volume.beta.kubernetes.io/',
  'node.alpha.kubernetes.io/',
  'kubeadm.alpha.kubernetes.io/',
  'autoscaling.alpha.kubernetes.io/',
];

class _MetadataBody extends StatelessWidget {
  final PanelContext ctx;
  const _MetadataBody(this.ctx);

  @override
  Widget build(BuildContext context) {
    final m = ctx.metadata;
    final small = Theme.of(context).textTheme.bodySmall;
    final created = m['creationTimestamp'];
    final deleting = m['deletionTimestamp'];
    final owners = OwnerLine.ordered(ctx.object);
    final finalizers = [for (final f in (m['finalizers'] as List?) ?? const []) '$f'];
    final labels = asMap(m['labels']);
    final annotations = asMap(m['annotations']);
    String? str(Object? v) => v == null || '$v'.isEmpty ? null : '$v';

    final facts = [
      if (str(m['name']) case final name?) _Kv.text('Name', name),
      if (str(m['namespace']) case final ns?) _Kv.widget('Namespace', ResourceLink(ObjectRef(kind: 'Namespace', name: ns), label: ns)),
      if (created != null) _Kv.widget('Created', AgeText(created, suffix: ' ago', style: small)),
      if (deleting != null) _Kv.widget('Deleting', StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true)),
      if (owners.isNotEmpty) _Kv.widget(owners.length > 1 ? 'Owners' : 'Owner', Wrap(spacing: 10, runSpacing: 2, children: [for (final o in owners) ResourceLink(o)])),
      if (str(ctx.object['apiVersion']) case final v?) _Kv.text('API version', v),
      if (str(m['uid']) case final uid?) _Kv.text('UID', uid, mono: true),
      if (str(m['resourceVersion']) case final rv?) _Kv.text('Resource version', rv, mono: true),
      if (str(m['generation']) case final g?) _Kv.text('Generation', g),
      if (finalizers.isNotEmpty) _Kv.widget('Finalizers', Wrap(spacing: 4, runSpacing: 4, children: [for (final f in finalizers) Chipish(text: f, copyValue: f)])),
    ];
    final userAnnotations = [for (final e in annotations.entries) if (!isSystemAnnotation(e.key)) _Kv.text(e.key, '${e.value}')];
    final systemAnnotations = [for (final e in annotations.entries) if (isSystemAnnotation(e.key)) _Kv.text(e.key, '${e.value}')];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _KvGrid(key: const ValueKey('metadata-facts'), rows: facts),
      if (labels.isNotEmpty) ...[
        const SizedBox(height: 12),
        QuietGroup(key: const ValueKey('metadata-labels'), 'Labels', [
          _KvGrid(rows: [for (final e in labels.entries) _Kv.text(e.key, '${e.value}', copy: '${e.key}=${e.value}')]),
        ]),
      ],
      if (annotations.isNotEmpty) ...[
        const SizedBox(height: 12),
        QuietGroup(key: const ValueKey('metadata-annotations'), 'Annotations', [
          _KvGrid(rows: userAnnotations, folded: systemAnnotations, foldedLabel: plural(systemAnnotations.length, 'system annotation')),
        ]),
      ],
    ]);
  }
}

/// One grid row: a key and either a one-line [text] (expands on click;
/// [copy] on hover, the text by default) or a [widget].
class _Kv {
  final String k;
  final String? text;
  final Widget? widget;
  final bool mono;
  final String? copy;
  const _Kv.text(this.k, String this.text, {this.mono = false, this.copy}) : widget = null;
  const _Kv.widget(this.k, Widget this.widget)
      : text = null,
        mono = false,
        copy = null;
}

/// Height of one grid line; a row's copy icon fits inside it, so hovering
/// moves nothing and rows with and without copy are the same height.
const _lineH = 18.0;
const _keyGap = 12.0;

/// Rows as a key/value grid: one key column for the grid, as wide as its
/// widest key but at most 40% of the width (longer keys shortened in the
/// middle, the full key in a tooltip), so every value starts at the same x.
/// Long lists are trimmed; [folded] rows (system annotations) sit closed
/// behind a "[foldedLabel]" row at the end.
class _KvGrid extends StatefulWidget {
  final List<_Kv> rows;
  final List<_Kv> folded;
  final String? foldedLabel;
  const _KvGrid({super.key, required this.rows, this.folded = const [], this.foldedLabel});

  @override
  State<_KvGrid> createState() => _KvGridState();
}

class _KvGridState extends State<_KvGrid> {
  static const _keep = 8;
  static const _trimAbove = 10;
  bool _all = false;
  bool _foldOpen = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final keyStyle = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final scaler = MediaQuery.textScalerOf(context);
    final rows = widget.rows;
    final folded = widget.folded;
    return LayoutBuilder(builder: (context, box) {
      var widest = 0.0;
      for (final r in [...rows, ...folded]) {
        final w = _textWidth(r.k, keyStyle, scaler);
        if (w > widest) widest = w;
      }
      final keyW = (widest + _keyGap).clamp(0.0, box.maxWidth * 0.4).toDouble();
      final trims = rows.length > _trimAbove;
      final shown = trims && !_all ? rows.take(_keep) : rows;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final r in shown) _KvRow(r, keyW: keyW),
        if (trims) ShowMoreLink(_all ? 'Show fewer' : 'Show ${rows.length - _keep} more', indent: 0, onTap: () => setState(() => _all = !_all)),
        if (folded.isNotEmpty) ...[
          Hoverable(
            key: const ValueKey('metadata-system-annotations'),
            onTap: () => setState(() => _foldOpen = !_foldOpen),
            builder: (h) => SizedBox(
              height: _lineH + 4,
              child: Row(children: [
                Icon(_foldOpen ? Icons.expand_more : Icons.chevron_right, size: 14, color: h ? theme.colorScheme.onSurface : colors.faint),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(widget.foldedLabel ?? plural(folded.length, 'more'),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: keyStyle?.copyWith(color: h ? theme.colorScheme.onSurface : null)),
                ),
              ]),
            ),
          ),
          if (_foldOpen) for (final r in folded) _KvRow(r, keyW: keyW),
        ],
      ]);
    });
  }
}

double _textWidth(String s, TextStyle? style, TextScaler scaler) =>
    (TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, textScaler: scaler)..layout()).width;

/// [k] split into a prefix ("example.com/") and a name, shortened in the
/// middle to fit [w] if need be: the prefix first, so the name stays whole
/// while it can.
({String prefix, String name, bool cut}) fitKey(String k, double w, TextStyle? style, TextScaler scaler) {
  ({String prefix, String name, bool cut}) split(String s, bool cut) {
    final i = s.indexOf('/');
    return i < 0 ? (prefix: '', name: s, cut: cut) : (prefix: s.substring(0, i + 1), name: s.substring(i + 1), cut: cut);
  }

  if (_textWidth(k, style, scaler) <= w) return split(k, false);
  String mid(String s, int n) => '${s.substring(0, (n + 1) ~/ 2)}…${s.substring(s.length - n ~/ 2)}';
  // The largest n in [0, max] whose make(n) fits.
  int fit(String Function(int) make, int max) {
    var lo = 0, hi = max;
    while (lo < hi) {
      final m = (lo + hi + 1) ~/ 2;
      if (_textWidth(make(m), style, scaler) <= w) {
        lo = m;
      } else {
        hi = m - 1;
      }
    }
    return lo;
  }

  final whole = split(k, true);
  if (whole.prefix.isNotEmpty && _textWidth('…/${whole.name}', style, scaler) <= w) {
    final body = whole.prefix.substring(0, whole.prefix.length - 1);
    final n = fit((n) => '${mid(body, n)}/${whole.name}', body.length - 1);
    return (prefix: '${mid(body, n)}/', name: whole.name, cut: true);
  }
  return split(mid(k, fit((n) => mid(k, n), k.length - 1)), true);
}

class _KvRow extends StatelessWidget {
  final _Kv row;
  final double keyW;
  const _KvRow(this.row, {required this.keyW});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final keyStyle = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final key = fitKey(row.k, keyW - _keyGap, keyStyle, MediaQuery.textScalerOf(context));
    Widget keyText = Text.rich(
      TextSpan(children: [
        if (key.prefix.isNotEmpty) TextSpan(text: key.prefix, style: TextStyle(color: colors.faint)),
        TextSpan(text: key.name),
      ]),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: keyStyle,
    );
    if (key.cut) keyText = Tooltip(message: row.k, waitDuration: const Duration(milliseconds: 500), child: keyText);
    return Hoverable(
      builder: (h) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: keyW, height: _lineH, child: Align(alignment: Alignment.centerLeft, child: keyText)),
          Expanded(
            child: row.text != null
                ? _TextValue(row.text!, mono: row.mono, copy: row.copy ?? row.text!, hovered: h)
                : ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _lineH),
                    child: Align(alignment: Alignment.centerLeft, child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: row.widget!)),
                  ),
          ),
        ]),
      ),
    );
  }
}

/// A value on one line with an end ellipsis; when it doesn't fit (or is
/// multi-line, or JSON) a chevron and a click open it: the full text
/// wrapped, or JSON pretty-printed and coloured in a scrolling block.
class _TextValue extends StatefulWidget {
  final String text;
  final bool mono;
  final String copy;
  final bool hovered;
  const _TextValue(this.text, {required this.mono, required this.copy, required this.hovered});

  @override
  State<_TextValue> createState() => _TextValueState();
}

class _TextValueState extends State<_TextValue> {
  static const _copyW = 20.0; // CopyIcon: 6 + 12 + 2
  static const _chevronW = 16.0;
  bool _open = false;
  late Object? _json = _parse(widget.text);

  static Object? _parse(String s) {
    final t = s.trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return null;
    try {
      final v = jsonDecode(s);
      return v is Map || v is List ? v : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(_TextValue old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _json = _parse(widget.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final style = widget.mono ? monoStyle(context, size: 11.5) : theme.textTheme.bodySmall;
    final line = widget.text.replaceAll(RegExp(r'\s*\n\s*'), ' ');
    return LayoutBuilder(builder: (context, box) {
      final overflows = widget.text.contains('\n') || _textWidth(line, style, MediaQuery.textScalerOf(context)) > box.maxWidth - _copyW - _chevronW;
      final expandable = _json != null || overflows;
      final wrapped = _open && _json == null;
      final copySlot = SizedBox(
        width: _copyW,
        height: _lineH,
        // Always laid out, so showing it moves nothing.
        child: Visibility(
          visible: widget.hovered,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Center(child: CopyIcon(widget.copy)),
        ),
      );
      Widget text() => wrapped
          ? Text(widget.text, style: style)
          : SizedBox(
              height: _lineH,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(line, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style),
              ),
            );
      final head = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(
          child: !expandable
              ? text()
              : Hoverable(
                  onTap: () => setState(() => _open = !_open),
                  builder: (h) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Flexible(child: text()),
                    SizedBox(
                      width: _chevronW,
                      height: _lineH,
                      child: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 14, color: h ? theme.colorScheme.onSurface : colors.faint),
                    ),
                  ]),
                ),
        ),
        copySlot,
      ]);
      if (!_open || _json == null) return head;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 4), child: _JsonBlock(_json!)),
      ]);
    });
  }
}

/// JSON pretty-printed and coloured, in a block that scrolls past 240.
class _JsonBlock extends StatefulWidget {
  final Object value;
  const _JsonBlock(this.value);

  @override
  State<_JsonBlock> createState() => _JsonBlockState();
}

class _JsonBlockState extends State<_JsonBlock> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final pretty = const JsonEncoder.withIndent('  ').convert(widget.value);
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: dark ? const Color(0x0DFFFFFF) : const Color(0x08000000),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.separator, width: 0.5),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          child: Text.rich(TextSpan(children: jsonSpans(context, pretty)), style: monoStyle(context, size: 11)),
        ),
      ),
    );
  }
}

final _jsonToken = RegExp(r'("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}\[\],])');

/// [json] (pretty-printed) as coloured spans: keys, strings, literals and
/// punctuation in theme colours, so it reads in light and dark.
List<TextSpan> jsonSpans(BuildContext context, String json) {
  final theme = Theme.of(context);
  final keyC = theme.colorScheme.primary;
  final strC = severityColor(context, Severity.ok);
  final litC = theme.colorScheme.tertiary;
  final punctC = theme.hintColor;
  final spans = <TextSpan>[];
  var at = 0;
  for (final m in _jsonToken.allMatches(json)) {
    if (m.start > at) spans.add(TextSpan(text: json.substring(at, m.start)));
    if (m.group(1) != null) {
      if (m.group(2) != null) {
        spans.add(TextSpan(text: m.group(1), style: TextStyle(color: keyC)));
        spans.add(TextSpan(text: m.group(2), style: TextStyle(color: punctC)));
      } else {
        spans.add(TextSpan(text: m.group(1), style: TextStyle(color: strC)));
      }
    } else if (m.group(3) != null || m.group(4) != null) {
      spans.add(TextSpan(text: m.group(0), style: TextStyle(color: litC)));
    } else {
      spans.add(TextSpan(text: m.group(0), style: TextStyle(color: punctC)));
    }
    at = m.end;
  }
  if (at < json.length) spans.add(TextSpan(text: json.substring(at)));
  return spans;
}
