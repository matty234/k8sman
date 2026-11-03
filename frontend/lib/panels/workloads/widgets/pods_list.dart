import 'package:flutter/material.dart';

import '../../../actions/actions.dart';
import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../panel.dart';
import 'util.dart';
import '../../../util/pod.dart';

const podsRef = ResourceRef(resource: 'pods');
const replicaSetsRef = ResourceRef(group: 'apps', resource: 'replicasets');

/// Filters [pods] to those owned by any uid in [ownerUids].
List<Json> filterPodsByOwner(List<Json> pods, Set<String> ownerUids) => [
  for (final p in pods)
    if (isOwnedByAny(p, ownerUids)) p,
];

/// Fetches pods by label selector, optionally restricted to those owned by
/// [ownerUid] (or, with [viaReplicaSets], owned by ReplicaSets that
/// [ownerUid] owns — for Deployments). Fetches once per [ownerUid] and again
/// whenever [refreshKey] changes (pass e.g. observedGeneration + counts).
class PodsList extends StatefulWidget {
  final ApiClient api;
  final String? namespace;
  final dynamic selector;
  final String? ownerUid;
  final bool viaReplicaSets;
  final String refreshKey;
  final bool sortByOrdinal;
  final bool showNode;

  /// When given (and the app isn't read-only), each row gets an overflow
  /// menu to delete/restart that pod.
  final PanelContext? actionCtx;

  const PodsList({
    super.key,
    required this.api,
    required this.namespace,
    required this.selector,
    this.ownerUid,
    this.viaReplicaSets = false,
    this.refreshKey = '',
    this.sortByOrdinal = false,
    this.showNode = true,
    this.actionCtx,
  });

  @override
  State<PodsList> createState() => _PodsListState();
}

class _PodsListState extends State<PodsList> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(PodsList old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey ||
        old.ownerUid != widget.ownerUid ||
        selectorToString(old.selector) != selectorToString(widget.selector)) {
      _future = _load(); // build() follows didUpdateWidget
    }
  }

  Future<List<Json>> _load() async {
    final sel = selectorToString(widget.selector);
    if (sel.isEmpty && widget.ownerUid == null) return const [];
    final pods = await widget.api.items(podsRef, namespace: widget.namespace, labelSelector: sel.isEmpty ? null : sel);
    var result = pods;
    final owner = widget.ownerUid;
    if (owner != null) {
      var uids = {owner};
      if (widget.viaReplicaSets) {
        final rs = await widget.api.items(replicaSetsRef, namespace: widget.namespace, labelSelector: sel.isEmpty ? null : sel);
        uids = {
          for (final r in rs)
            if (isOwnedByAny(r, {owner})) '${dig(r, ['metadata', 'uid'])}',
        };
      }
      result = filterPodsByOwner(pods, uids);
    }
    result = [...result];
    if (widget.sortByOrdinal) {
      result.sort(
        (a, b) => (ordinalOf('${dig(a, ['metadata', 'name'])}') ?? 1 << 30).compareTo(ordinalOf('${dig(b, ['metadata', 'name'])}') ?? 1 << 30),
      );
    } else {
      result.sort((a, b) => naturalCompare('${dig(a, ['metadata', 'name'])}', '${dig(b, ['metadata', 'name'])}'));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => KeepingAsync<List<Json>>(
    future: _future,
    builder: (context, pods) {
      if (pods.isEmpty) return const InlineMessage('No matching pods');
      return PodRows(pods: pods, showNode: widget.showNode, actionCtx: widget.actionCtx);
    },
  );
}

/// Compact table of pods: status, name, ready, restarts, node, age.
class PodRows extends StatelessWidget {
  final List<Json> pods;
  final bool showNode;
  final PanelContext? actionCtx;
  const PodRows({super.key, required this.pods, this.showNode = true, this.actionCtx});

  PanelContext? _podCtx(Json pod) {
    final a = actionCtx;
    if (a == null || a.app.readOnly) return null;
    final t = a.app.typeFor('', 'Pod');
    return t == null ? null : PanelContext(object: pod, type: t, api: a.api, app: a.app);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final counts = <String, int>{};
    for (final p in pods) {
      final s = podStatus(p);
      counts[s] = (counts[s] ?? 0) + 1;
    }
    Widget row(List<Widget> cells) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: cells),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [for (final e in counts.entries) StatusBadge('${e.value} ${e.key}', severity: severityOf(e.key), dense: true)],
          ),
        ),
        row([
          Expanded(flex: 1, child: Text('POD', style: head)),
          SizedBox(width: 86, child: Text('STATUS', style: head)),
          SizedBox(width: 40, child: Text('READY', style: head)),
          SizedBox(
            width: 36,
            child: Text('RST', style: head, textAlign: TextAlign.right),
          ),
          if (showNode) ...[const SizedBox(width: 10), Expanded(flex: 1, child: Text('NODE', style: head))],
          SizedBox(
            width: 40,
            child: Text('AGE', style: head, textAlign: TextAlign.right),
          ),
          if (actionCtx != null && !actionCtx!.app.readOnly) const SizedBox(width: 24),
        ]),
        const Divider(height: 4),
        for (final p in pods) _podRow(context, p, row),
      ],
    );
  }

  Widget _podRow(BuildContext context, Json p, Widget Function(List<Widget>) row) {
    final name = '${dig(p, ['metadata', 'name'])}';
    final ns = dig<String>(p, ['metadata', 'namespace']);
    final status = podStatus(p);
    final r = podReadyCount(p);
    final restarts = podRestarts(p);
    final node = dig<String>(p, ['spec', 'nodeName']);
    final readySev = r.total > 0 && r.ready == r.total
        ? Severity.ok
        : (status == 'Succeeded' || status == 'Completed' ? Severity.neutral : Severity.warn);
    return row([
      Expanded(
        flex: 1,
        child: OneLineLink(ObjectRef(kind: 'Pod', name: name, namespace: ns)),
      ),
      SizedBox(
        width: 86,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(message: status, child: _Badge(status)),
        ),
      ),
      SizedBox(width: 40, child: coloredCount(context, '${r.ready}/${r.total}', readySev)),
      SizedBox(
        width: 36,
        child: Align(
          alignment: Alignment.centerRight,
          child: coloredCount(
            context,
            '$restarts',
            restarts > 0 ? (restarts >= 5 ? Severity.error : Severity.warn) : Severity.neutral,
            bold: restarts > 0,
          ),
        ),
      ),
      if (showNode) ...[
        const SizedBox(width: 10),
        Expanded(
          flex: 1,
          child: node == null ? const HintText('—') : OneLineLink(ObjectRef(kind: 'Node', name: node)),
        ),
      ],
      SizedBox(
        width: 40,
        child: Align(alignment: Alignment.centerRight, child: AgeText(dig(p, ['metadata', 'creationTimestamp']))),
      ),
      if (_podCtx(p) case final podCtx?) SizedBox(width: 24, height: 20, child: _PodMenu(podCtx)),
    ]);
  }
}

/// A StatusBadge that never overflows its slot.
class _Badge extends StatelessWidget {
  final String text;
  const _Badge(this.text);
  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: StatusBadge(text, dense: true));
}

/// Unobtrusive per-pod overflow menu: delete (= restart, if controller-owned).
class _PodMenu extends StatelessWidget {
  final PanelContext pod;
  const _PodMenu(this.pod);

  @override
  Widget build(BuildContext context) {
    final owned = ownerRefs(pod.object).isNotEmpty;
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
            popUpAnimationStyle: AnimationStyle.noAnimation,
      tooltip: 'Pod actions',
      padding: EdgeInsets.zero,
      iconSize: 16,
      icon: Icon(Icons.more_vert, size: 16, color: theme.hintColor),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact, minimumSize: const Size(22, 22), padding: EdgeInsets.zero),
      onSelected: (_) => runResourceAction(
        context,
        pod,
        'delete',
        title: owned ? 'Restart pod ${pod.name}?' : 'Delete pod ${pod.name}?',
        message: owned ? 'The pod is deleted and its controller creates a replacement.' : 'This pod has no controller: it will not be recreated.',
        destructive: true,
        confirmLabel: owned ? 'Restart pod' : 'Delete pod',
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'delete',
          height: 32,
          child: Row(
            children: [
              Icon(owned ? Icons.refresh : Icons.delete_outline, size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Text(owned ? 'Restart pod (delete)' : 'Delete pod'),
            ],
          ),
        ),
      ],
    );
  }
}
