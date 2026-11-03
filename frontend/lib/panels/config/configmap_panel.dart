import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'usage.dart';
import 'values.dart';
import 'widgets.dart';

/// Values longer than this are collapsed behind "show all".
const kCollapseLines = 30;
const kCollapseChars = 3000;

class ConfigMapPanel extends ResourcePanel {
  const ConfigMapPanel();

  @override
  Set<String> get kinds => {'/ConfigMap'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final data = asMap(ctx.object['data']);
    final binary = asMap(ctx.object['binaryData']);
    final immutable = ctx.object['immutable'] == true;
    final totalBytes = data.values.fold<int>(0, (s, v) => s + utf8Size('$v')) +
        binary.values.fold<int>(0, (s, v) => s + (decodeBase64(v)?.length ?? 0));
    final keys = data.keys.toList()..sort();
    final binKeys = binary.keys.toList()..sort();

    return [
      DetailSection(
        title: 'Data',
        icon: Icons.description_outlined,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (immutable) const CountPill('immutable', severity: Severity.info),
          CountPill('${keys.length + binKeys.length} key${keys.length + binKeys.length == 1 ? '' : 's'} · ${formatSize(totalBytes)}'),
        ]),
        child: keys.isEmpty && binKeys.isEmpty
            ? const InlineMessage('This ConfigMap has no data.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final k in keys)
                  DataEntry(key: ValueKey('${ctx.uid}/$k'), name: k, value: '${data[k] ?? ''}', initiallyExpanded: keys.length <= 6),
                for (final k in binKeys) _BinaryEntry(name: k, value: binary[k]),
              ]),
      ),
      UsedBySection(
        key: ValueKey('${ctx.uid}/usedby'),
        ctx: ctx,
        kind: RefKind.configMap,
        existingKeys: {...data.keys, ...binary.keys},
      ),
    ];
  }
}

/// One expandable data key: header with format, size and line count, and
/// the (pretty-printed) value in a CodeBlock.
class DataEntry extends StatefulWidget {
  final String name;
  final String value;
  final bool initiallyExpanded;
  const DataEntry({super.key, required this.name, required this.value, this.initiallyExpanded = true});

  @override
  State<DataEntry> createState() => _DataEntryState();
}

class _DataEntryState extends State<DataEntry> {
  late bool _open = widget.initiallyExpanded;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.value;
    final format = detectFormat(v);
    final pretty = prettyValue(v, format);
    final lines = lineCount(v);
    final singleLine = !v.trimRight().contains('\n') && v.length <= 80;
    final prettyLines = pretty.split('\n');
    final long = prettyLines.length > kCollapseLines || pretty.length > kCollapseChars;
    var shown = pretty;
    if (long && !_showAll) {
      shown = prettyLines.take(kCollapseLines).join('\n');
      if (shown.length > kCollapseChars) shown = shown.substring(0, kCollapseChars);
      shown = '$shown\n…';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
            child: Row(children: [
              Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: theme.hintColor),
              const SizedBox(width: 2),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(widget.name, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 8),
              if (!_open && singleLine)
                Expanded(
                  child: Text(v.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5, color: theme.hintColor)),
                )
              else
                const Spacer(),
              const SizedBox(width: 6),
              _FormatTag(format),
              const SizedBox(width: 6),
              Text('${formatSize(utf8Size(v))} · $lines line${lines == 1 ? '' : 's'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11)),
              IconButton(
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                tooltip: 'Copy value',
                icon: const Icon(Icons.copy),
                onPressed: () => copyToClipboard(context, v),
              ),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              v.isEmpty ? Text('(empty)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)) : CodeBlock(shown),
              if (long)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: Theme.of(context).textTheme.labelMedium),
                    onPressed: () => setState(() => _showAll = !_showAll),
                    icon: Icon(_showAll ? Icons.unfold_less : Icons.unfold_more, size: 14),
                    label: Text(_showAll ? 'Show less' : 'Show all ${prettyLines.length} lines'),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

class _FormatTag extends StatelessWidget {
  final ValueFormat format;
  const _FormatTag(this.format);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = format == ValueFormat.plain ? theme.hintColor : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0.5),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(3)),
      child: Text(format.name, style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

class _BinaryEntry extends StatelessWidget {
  final String name;
  final dynamic value;
  const _BinaryEntry({required this.name, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = decodeBase64(value);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.memory, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: monoStyle(context).copyWith(fontWeight: FontWeight.w600))),
          const StatusBadge('binaryData', dense: true, severity: Severity.info),
          const SizedBox(width: 6),
          Text(bytes == null ? 'invalid base64' : formatSize(bytes.length), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11)),
        ]),
        if (bytes != null && bytes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 20),
            child: Text(hexPreview(bytes, max: 24), style: monoStyle(context, size: 11, color: theme.hintColor)),
          ),
      ]),
    );
  }
}
