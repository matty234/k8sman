import 'package:flutter/material.dart';

import '../../panels/panel.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shared metadata block shown first for every object.
///
/// Collapsed by default to a one-line summary (namespace · age · owner ·
/// label count); expands to the full key/value list. The expanded state is
/// remembered while navigating between objects.
class MetadataSection extends StatefulWidget {
  final PanelContext ctx;
  const MetadataSection({super.key, required this.ctx});

  @override
  State<MetadataSection> createState() => _MetadataSectionState();
}

class _MetadataSectionState extends State<MetadataSection> {
  static bool _rememberExpanded = false;
  bool _expanded = _rememberExpanded;

  void _toggle() => setState(() => _rememberExpanded = _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final theme = Theme.of(context);
    final m = ctx.metadata;
    final created = m['creationTimestamp'];
    final deleting = m['deletionTimestamp'];
    final owners = ownerRefs(ctx.object);
    final finalizers = (m['finalizers'] as List?)?.cast<Object>() ?? const [];
    final labels = asMap(m['labels']);
    final annotations = asMap(m['annotations']);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);

    Widget fact(IconData icon, Widget child) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: AppColors.of(context).faint),
          const SizedBox(width: 4),
          Flexible(child: DefaultTextStyle.merge(style: muted, child: child)),
        ]);
    String plural(int n, String s) => '$n $s${n == 1 ? '' : 's'}';

    final facts = <Widget>[
      if (deleting != null) StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true),
      if (m['namespace'] != null) fact(Icons.folder_outlined, Text('${m['namespace']}', overflow: TextOverflow.ellipsis)),
      if (created != null) fact(Icons.schedule, AgeText(created, style: muted)),
      for (final o in owners.take(1)) fact(Icons.subdirectory_arrow_right, ResourceLink(o)),
      if (owners.length > 1) Text('+${owners.length - 1}', style: muted),
      fact(Icons.sell_outlined, Text(plural(labels.length, 'label'))),
      if (annotations.isNotEmpty) fact(Icons.notes, Text(plural(annotations.length, 'annotation'))),
      if (finalizers.isNotEmpty) fact(Icons.lock_outline, Text(plural(finalizers.length, 'finalizer'))),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Hoverable(
          onTap: _toggle,
          builder: (h) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: facts)),
              const SizedBox(width: 8),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_expanded ? 'Hide' : 'Metadata', style: theme.textTheme.labelSmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor)),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: Icon(Icons.chevron_right, size: 15, color: h ? theme.colorScheme.onSurface : theme.hintColor),
                ),
              ]),
            ]),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).separator, width: 0.5),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyValueTable(keyWidth: 120, [
                ('Name', m['name']),
                ('Namespace', m['namespace']),
                ('API version', '${ctx.object['apiVersion']}'),
                ('UID', m['uid'] == null ? null : Text('${m['uid']}', style: monoStyle(context, size: 11, color: theme.colorScheme.onSurface))),
                (
                  'Created',
                  created == null
                      ? null
                      : Row(children: [
                          AgeText(created, suffix: ' ago', style: theme.textTheme.bodySmall),
                          Flexible(child: Text('  ·  $created', overflow: TextOverflow.ellipsis, style: muted)),
                        ])
                ),
                ('Deleting since', deleting == null ? null : StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true)),
                ('Generation', m['generation']?.toString()),
                ('Resource version', m['resourceVersion']),
                ('Owners', owners.isEmpty ? null : Wrap(spacing: 8, children: [for (final o in owners) ResourceLink(o)])),
                ('Finalizers', finalizers.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final f in finalizers) Chipish(text: '$f')])),
                ('Labels', LabelChips(labels)),
              ]),
              if (annotations.isNotEmpty) _Annotations(annotations),
            ]),
          ),
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
      Hoverable(
        onTap: () => setState(() => _open = !_open),
        builder: (h) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 120, child: Text('Annotations', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
            Text('${widget.annotations.length}', style: theme.textTheme.bodySmall),
            Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 15, color: h ? theme.colorScheme.onSurface : theme.hintColor),
          ]),
        ),
      ),
      if (_open)
        for (final e in widget.annotations.entries)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2, bottom: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.key, style: monoStyle(context, size: 11, color: theme.hintColor)),
              '${e.value}'.length > 120 || '${e.value}'.contains('\n') ? CodeBlock('${e.value}', maxLines: 12) : SelectableText('${e.value}', style: theme.textTheme.bodySmall),
            ]),
          ),
    ]);
  }
}
