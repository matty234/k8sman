import 'package:flutter/material.dart';

import '../../panels/panel.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shared metadata block shown first for every object.
class MetadataSection extends StatelessWidget {
  final PanelContext ctx;
  const MetadataSection({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final m = ctx.metadata;
    final created = m['creationTimestamp'];
    final deleting = m['deletionTimestamp'];
    final owners = ownerRefs(ctx.object);
    final finalizers = (m['finalizers'] as List?)?.cast<Object>() ?? const [];
    final annotations = asMap(m['annotations']);
    return DetailSection(
      title: 'Metadata',
      icon: Icons.info_outline,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueTable([
          ('Name', m['name']),
          ('Namespace', m['namespace']),
          ('API version', '${ctx.object['apiVersion']}'),
          ('UID', m['uid']),
          ('Created', created == null ? null : Row(children: [AgeText(created, suffix: ' ago', style: Theme.of(context).textTheme.bodySmall), Text('  ·  $created', style: Theme.of(context).textTheme.bodySmall)])),
          ('Deleting since', deleting == null ? null : StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true)),
          ('Generation', m['generation']?.toString()),
          ('Resource version', m['resourceVersion']),
          ('Owners', owners.isEmpty ? null : Wrap(spacing: 8, children: [for (final o in owners) ResourceLink(o)])),
          ('Finalizers', finalizers.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final f in finalizers) Chipish(text: '$f')])),
          ('Labels', LabelChips(asMap(m['labels']))),
        ]),
        if (annotations.isNotEmpty) _Annotations(annotations),
      ]),
    );
  }
}

class _Annotations extends StatefulWidget {
  final Map<String, dynamic> annotations;
  const _Annotations(this.annotations);

  @override
  State<_Annotations> createState() => _AnnotationsState();
}

class _AnnotationsState extends State<_Annotations> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 140, child: Text('Annotations', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
            Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: theme.hintColor),
            Text('${widget.annotations.length}', style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
      if (_open)
        for (final e in widget.annotations.entries)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.key, style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
              '${e.value}'.length > 120 || '${e.value}'.contains('\n') ? CodeBlock('${e.value}', maxLines: 12) : SelectableText('${e.value}', style: theme.textTheme.bodySmall),
            ]),
          ),
    ]);
  }
}
