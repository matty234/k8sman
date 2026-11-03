/// Helpers and small widgets shared by the storage panels (PVC, PV,
/// StorageClass). Kept inside the area folder per docs/PANELS.md.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';

const pvcResource = ResourceRef(resource: 'persistentvolumeclaims');
const pvResource = ResourceRef(resource: 'persistentvolumes');
const podResource = ResourceRef(resource: 'pods');
const scResource = ResourceRef(group: 'storage.k8s.io', resource: 'storageclasses');
const stsResource = ResourceRef(group: 'apps', resource: 'statefulsets');

const defaultClassAnnotations = ['storageclass.kubernetes.io/is-default-class', 'storageclass.beta.kubernetes.io/is-default-class'];

ObjectRef scRef(String name) => ObjectRef(group: 'storage.k8s.io', kind: 'StorageClass', name: name);
ObjectRef pvRef(String name) => ObjectRef(kind: 'PersistentVolume', name: name);
ObjectRef pvcRef(String name, String? ns) => ObjectRef(kind: 'PersistentVolumeClaim', name: name, namespace: ns);
ObjectRef nodeRef(String name) => ObjectRef(kind: 'Node', name: name);

/// Abbreviation and one-line meaning of each access mode.
const accessModeInfo = <String, (String, String)>{
  'ReadWriteOnce': ('RWO', 'read-write by pods on a single node'),
  'ReadOnlyMany': ('ROX', 'read-only by pods on many nodes'),
  'ReadWriteMany': ('RWX', 'read-write by pods on many nodes'),
  'ReadWriteOncePod': ('RWOP', 'read-write by exactly one pod'),
};

String accessModeShort(String m) => accessModeInfo[m]?.$1 ?? m;

bool isDefaultClass(Json sc) {
  final ann = asMap(dig(sc, ['metadata', 'annotations']));
  return defaultClassAnnotations.any((a) => '${ann[a]}'.toLowerCase() == 'true');
}

/// Human explanation of a StorageClass volumeBindingMode.
String bindingModeExplanation(String? mode) => switch (mode) {
      'WaitForFirstConsumer' => 'Volume is provisioned and bound only once a pod using the claim is scheduled, '
          'so it lands in the pod\'s zone/node.',
      _ => 'Volume is provisioned and bound as soon as the claim is created, before any pod uses it.',
    };

/// Quantity → pretty string, keeping the original when it can't be parsed.
String prettyQuantity(dynamic q) {
  if (q == null) return '';
  final b = parseBytes(q);
  if (b == null) return '$q';
  final pretty = formatBytes(b);
  // "1Gi" already reads well; only add the normalised form when it differs.
  final raw = '$q';
  return RegExp(r'^\d+(Ki|Mi|Gi|Ti|Pi)$').hasMatch(raw) || raw == pretty ? raw : '$raw ($pretty)';
}

/// Coloured callout box for derived insights / warnings.
class Callout extends StatelessWidget {
  final Severity severity;
  final String? title;
  final String text;
  final Widget? child;
  const Callout({super.key, required this.severity, required this.text, this.title, this.child});

  IconData get _icon => switch (severity) {
        Severity.error => Icons.error_outline,
        Severity.warn => Icons.warning_amber_rounded,
        Severity.ok => Icons.check_circle_outline,
        _ => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = severityColor(context, severity);
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(_icon, size: 15, color: c)),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null) Text(title!, style: theme.textTheme.bodySmall?.copyWith(color: c, fontWeight: FontWeight.w600)),
            SelectableText(text, style: theme.textTheme.bodySmall),
            ?child,
          ]),
        ),
      ]),
    );
  }
}

/// Access modes as `RWO` chips with their meaning.
class AccessModesView extends StatelessWidget {
  final List<String> modes;
  const AccessModesView(this.modes, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (modes.isEmpty) return Text('—', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final m in modes)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 44, child: Chipish(text: accessModeShort(m))),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: m, style: theme.textTheme.bodySmall),
                  if (accessModeInfo[m] != null)
                    TextSpan(text: ' · ${accessModeInfo[m]!.$2}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// Monospace selectable value (paths, handles, provisioners).
class MonoValue extends StatelessWidget {
  final String text;
  final Color? color;
  const MonoValue(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) => SelectableText(text, style: monoStyle(context, size: 11.5, color: color));
}

/// Inline row of a badge/chip with explanatory hint text.
class ValueWithHint extends StatelessWidget {
  final Widget value;
  final String? hint;
  final Color? hintColor;
  const ValueWithHint(this.value, {super.key, this.hint, this.hintColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
      value,
      if (hint != null && hint!.isNotEmpty) Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: hintColor ?? theme.hintColor)),
    ]);
  }
}

/// Map of strings rendered as a compact mono key/value table.
class ParamsTable extends StatelessWidget {
  final Json params;
  final String emptyText;
  const ParamsTable(this.params, {super.key, this.emptyText = 'none'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (params.isEmpty) return Text(emptyText, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    final keys = params.keys.toList()..sort();
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(flex: 1), 1: FlexColumnWidth(2)},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final k in keys)
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.only(right: 12, top: 2, bottom: 2),
              child: Text(k, style: monoStyle(context, size: 11.5, color: theme.colorScheme.primary)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(_str(params[k]), style: monoStyle(context, size: 11.5)),
            ),
          ]),
      ],
    );
  }

  static String _str(dynamic v) => v is String ? v : '$v';
}

/// Readable NodeSelector terms (PV nodeAffinity / SC allowedTopologies).
/// Terms are OR'd, expressions inside a term are AND'd. Hostname terms get
/// node links.
class NodeSelectorView extends StatelessWidget {
  final List<Json> terms;
  const NodeSelectorView(this.terms, {super.key});

  static const hostnameKey = 'kubernetes.io/hostname';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (terms.isEmpty) return Text('none', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < terms.length; i++) ...[
        if (i > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('— or —', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
          ),
        for (final (field, ex) in [
          for (final e in asMapList(terms[i]['matchExpressions'])) (false, e),
          for (final e in asMapList(terms[i]['matchFields'])) (true, e),
        ])
          _expr(context, ex, field),
      ],
    ]);
  }

  Widget _expr(BuildContext context, Json ex, bool field) {
    final theme = Theme.of(context);
    final key = '${ex['key'] ?? ''}';
    final op = '${ex['operator'] ?? ''}';
    final values = [for (final v in (ex['values'] as List? ?? const [])) '$v'];
    final isHost = (key == hostnameKey || (field && key == 'metadata.name')) && op == 'In';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 3, children: [
        Text(key, style: monoStyle(context, size: 11.5, color: theme.colorScheme.primary)),
        Text(_opText(op), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontStyle: FontStyle.italic)),
        for (final v in values) isHost ? ResourceLink(nodeRef(v), label: v) : Chipish(text: v),
      ]),
    );
  }

  static String _opText(String op) => switch (op) {
        'In' => 'in',
        'NotIn' => 'not in',
        'Exists' => 'exists',
        'DoesNotExist' => 'does not exist',
        'Gt' => '>',
        'Lt' => '<',
        _ => op,
      };
}

/// Runs a fetch once per [deps] value (not on every live re-render).
class FetchOnce<T> extends StatefulWidget {
  final Object? deps;
  final Future<T> Function() fetch;
  final Widget Function(BuildContext context, T data) builder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final Widget? loading;
  const FetchOnce({super.key, required this.deps, required this.fetch, required this.builder, this.errorBuilder, this.loading});

  @override
  State<FetchOnce<T>> createState() => _FetchOnceState<T>();
}

class _FetchOnceState<T> extends State<FetchOnce<T>> {
  late Future<T> _future = widget.fetch();

  @override
  void didUpdateWidget(covariant FetchOnce<T> old) {
    super.didUpdateWidget(old);
    if (old.deps != widget.deps) _future = widget.fetch();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return widget.errorBuilder?.call(context, snap.error!) ?? InlineMessage('${snap.error}', isError: true);
          }
          if (snap.connectionState != ConnectionState.done) {
            return widget.loading ??
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                );
          }
          return widget.builder(context, snap.data as T);
        },
      );
}

/// Small "N" count pill for section headers.
class CountPill extends StatelessWidget {
  final String text;
  final Severity severity;
  const CountPill(this.text, {super.key, this.severity = Severity.neutral});
  @override
  Widget build(BuildContext context) => StatusBadge(text, severity: severity, dense: true);
}
