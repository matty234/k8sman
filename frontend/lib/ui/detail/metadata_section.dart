import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../panels/pod/pod_section.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'inspector_parts.dart';
import 'owner_line.dart';

/// The shared Metadata section, last on every inspector's Overview:
/// collapsed to a one-line summary ("7 labels · 2 annotations · created 5d
/// ago"); open, the namespace, age and owners, labels and annotations as
/// quiet copyable rows (long lists trimmed), and the API details (UID,
/// resourceVersion, generation, finalizers). The open state is remembered
/// for the session.
class MetadataSection extends StatelessWidget {
  final PanelContext ctx;
  const MetadataSection({super.key, required this.ctx});

  /// "7 labels · 2 annotations · created 5d ago".
  static String summary(Json m) {
    final labels = asMap(m['labels']).length;
    final annotations = asMap(m['annotations']).length;
    final finalizers = (m['finalizers'] as List?)?.length ?? 0;
    final created = parseTime(m['creationTimestamp']);
    return [
      labels == 0 ? 'no labels' : plural(labels, 'label'),
      if (annotations > 0) plural(annotations, 'annotation'),
      if (finalizers > 0) plural(finalizers, 'finalizer'),
      if (created != null) 'created ${formatAge(created)} ago',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final m = ctx.metadata;
    return PodSection(
      key: const ValueKey('metadata-section'),
      id: 'metadata',
      title: 'Metadata',
      initiallyExpanded: false,
      trailing: SectionSummary(summary(m)),
      child: _MetadataBody(ctx),
    );
  }
}

class _MetadataBody extends StatelessWidget {
  final PanelContext ctx;
  const _MetadataBody(this.ctx);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = ctx.metadata;
    final small = theme.textTheme.bodySmall;
    final created = m['creationTimestamp'];
    final deleting = m['deletionTimestamp'];
    final owners = OwnerLine.ordered(ctx.object);
    final finalizers = [for (final f in (m['finalizers'] as List?) ?? const []) '$f'];
    final labels = asMap(m['labels']);
    final annotations = asMap(m['annotations']);
    final mono = monoStyle(context, size: 11);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable(keyWidth: 80, [
        ('Namespace', m['namespace'] == null ? null : ResourceLink(ObjectRef(kind: 'Namespace', name: '${m['namespace']}'), label: '${m['namespace']}')),
        ('Created', created == null ? null : AgeText(created, suffix: ' ago', style: small)),
        ('Deleting', deleting == null ? null : StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true)),
        (owners.length > 1 ? 'Owners' : 'Owner', owners.isEmpty ? null : Wrap(spacing: 10, runSpacing: 2, children: [for (final o in owners) ResourceLink(o)])),
      ]),
      const SizedBox(height: 12),
      QuietGroup(key: const ValueKey('metadata-labels'), 'Labels', [
        if (labels.isEmpty)
          Text('none', style: small?.copyWith(color: theme.hintColor))
        else
          TrimmedList([
            for (final e in labels.entries)
              HoverCopy(
                copy: '${e.key}=${e.value}',
                child: Tooltip(
                  message: '${e.key}=${e.value}',
                  waitDuration: const Duration(milliseconds: 600),
                  child: keyValueText(context, e.key, '${e.value}'),
                ),
              ),
          ]),
      ]),
      if (annotations.isNotEmpty) ...[
        const SizedBox(height: 12),
        QuietGroup(key: const ValueKey('metadata-annotations'), 'Annotations', [
          TrimmedList([for (final e in annotations.entries) _Annotation(e.key, '${e.value}')], gap: 6),
        ]),
      ],
      const SizedBox(height: 12),
      QuietGroup('Details', [
        KeyValueTable(keyWidth: 80, [
          ('Name', m['name'] == null ? null : HoverCopy(copy: '${m['name']}', child: Text('${m['name']}', style: mono))),
          ('API version', '${ctx.object['apiVersion'] ?? ''}'),
          ('UID', m['uid'] == null ? null : HoverCopy(copy: '${m['uid']}', child: Text('${m['uid']}', style: mono))),
          ('Version', m['resourceVersion'] == null ? null : Tooltip(message: 'resourceVersion', child: Text('${m['resourceVersion']}', style: mono))),
          ('Generation', m['generation']?.toString()),
          ('Finalizers', finalizers.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final f in finalizers) Chipish(text: f, copyValue: f)])),
        ]),
      ]),
    ]);
  }
}

/// One annotation: "key: value" on one line, ellipsised; long or multi-line
/// values open on click (in a code block); copy on hover.
class _Annotation extends StatefulWidget {
  final String k;
  final String v;
  const _Annotation(this.k, this.v);

  @override
  State<_Annotation> createState() => _AnnotationState();
}

class _AnnotationState extends State<_Annotation> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.v;
    final long = v.length > 80 || v.contains('\n');
    final line = v.replaceAll(RegExp(r'\s*\n\s*'), ' ');
    final row = HoverCopy(
      copy: v,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '${widget.k}  ', style: TextStyle(color: theme.hintColor)),
          if (!_open) TextSpan(text: line),
        ]),
        maxLines: _open ? null : 2,
        overflow: _open ? null : TextOverflow.ellipsis,
        style: monoStyle(context, size: 11),
      ),
    );
    if (!long) return row;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: row),
        Hoverable(
          onTap: () => setState(() => _open = !_open),
          builder: (h) => Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(_open ? 'less' : 'more', style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor)),
          ),
        ),
      ]),
      if (_open) Padding(padding: const EdgeInsets.only(top: 4), child: CodeBlock(v, maxLines: 12)),
    ]);
  }
}
