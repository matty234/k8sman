import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'usage.dart';
import 'values.dart';
import 'widgets.dart';


class ConfigMapPanel extends ResourcePanel {
  const ConfigMapPanel();

  @override
  Set<String> get kinds => {'/ConfigMap'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final data = asMap(ctx.object['data']);
    final binary = asMap(ctx.object['binaryData']);
    final immutable = ctx.object['immutable'] == true;
    final dataBytes = data.values.fold<int>(0, (s, v) => s + utf8Size('$v'));
    final binaryBytes = binary.values.fold<int>(0, (s, v) => s + (decodeBase64(v)?.length ?? 0));
    final keys = data.keys.toList()..sort();
    final binKeys = binary.keys.toList()..sort();
    final existing = {...data.keys, ...binary.keys};

    return [
      // How much is in it, and who depends on it?
      UsageReportBuilder(
        ctx: ctx,
        kind: RefKind.configMap,
        builder: (context, snap) => InspectorHeader(
          chips: [if (immutable) const StatusBadge('immutable', dense: true, severity: Severity.info)],
          figures: [
            InspectorFigure('${keys.length + binKeys.length}', keys.length + binKeys.length == 1 ? 'key' : 'keys'),
            sizeFigure(dataBytes + binaryBytes, 'size'),
            ...usedByFigures(snap),
          ],
          extraInsights: missingKeyInsights(snap, existing, 'ConfigMap'),
          facts: [?ownerFact(ctx.object)],
        ),
      ),
      InspectorSection(
        id: 'cm-data',
        title: 'Data',
        trailing: SectionSummary(keys.isEmpty ? 'empty' : '${plural(keys.length, 'key')} · ${formatSize(dataBytes)}'),
        child: keys.isEmpty
            ? InlineMessage(binKeys.isEmpty ? 'This ConfigMap has no data.' : 'No text data; see Binary data.')
            : TrimmedList(trimAbove: 12, keep: 10, [
                for (final k in keys)
                  DataEntry(
                    key: ValueKey('${ctx.uid}/$k'),
                    memoryId: 'cm-key:${ctx.uid}/$k',
                    name: k,
                    value: '${data[k] ?? ''}',
                    initiallyExpanded: keys.length == 1,
                  ),
              ]),
      ),
      UsedBySection(key: ValueKey('${ctx.uid}/usedby'), ctx: ctx, kind: RefKind.configMap, existingKeys: existing),
      if (binKeys.isNotEmpty)
        InspectorSection(
          id: 'cm-binary',
          title: 'Binary data',
          initiallyExpanded: false,
          trailing: SectionSummary('${plural(binKeys.length, 'key')} · ${formatSize(binaryBytes)}'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final k in binKeys) _BinaryEntry(name: k, value: binary[k])]),
        ),
    ];
  }
}

/// One data key as a compact row: the key, a one-line preview (or its line
/// count), its format and size, copy on hover; open for the
/// (pretty-printed, trimmed when long) value.
class DataEntry extends StatelessWidget {
  final String name;
  final String value;
  final bool initiallyExpanded;
  final String? memoryId;
  const DataEntry({super.key, required this.name, required this.value, this.initiallyExpanded = true, this.memoryId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final format = detectFormat(v);
    final lines = lineCount(v);
    final singleLine = !v.trimRight().contains('\n') && v.length <= 80;
    return InspectorRow(
      memoryId: memoryId,
      initiallyExpanded: initiallyExpanded,
      title: Tooltip(
        message: name.length > 28 ? name : '',
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
      ),
      subtitle: v.isEmpty
          ? const Text('(empty)')
          : singleLine
              ? Text(v.trim(), style: monoStyle(context, size: 11, color: theme.hintColor))
              : Text(plural(lines, 'line')),
      trailing: [
        Text([if (format != ValueFormat.plain) format.name, formatSize(utf8Size(v))].join(' · ')),
      ],
      actions: [RowAction(icon: Icons.copy, tooltip: 'Copy value', onTap: () => copyToClipboard(context, v))],
      details: (context) => LongValue(prettyValue(v, format)),
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
    return InspectorRow(
      leading: const Icon(Icons.memory),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
      subtitle: bytes == null || bytes.isEmpty ? null : Text(hexPreview(bytes, max: 24), style: monoStyle(context, size: 11, color: theme.hintColor)),
      trailing: [
        Text(bytes == null ? 'invalid base64' : formatSize(bytes.length),
            style: bytes == null ? TextStyle(color: severityColor(context, Severity.error)) : null),
      ],
    );
  }
}
