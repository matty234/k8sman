import 'package:flutter/material.dart';

import '../../../actions/actions.dart';
import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../ui/detail/inspector_parts.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/text.dart';
import '../../pod/pod_section.dart';
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

  /// Draws the list as a collapsible section with this title and the pod
  /// counts as its summary (amber when any pod has a problem).
  final String? sectionTitle;

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
    this.sectionTitle,
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
  Widget build(BuildContext context) => FutureBuilder<List<Json>>(
    future: _future,
    builder: (context, snap) {
      final pods = snap.data;
      final Widget body = snap.hasError
          ? InlineMessage('${snap.error}', isError: true)
          : pods == null
          ? const SectionSpinner()
          : pods.isEmpty
          ? const InlineMessage('No matching pods')
          : PodRows(pods: pods, showNode: widget.showNode, actionCtx: widget.actionCtx);
      final title = widget.sectionTitle;
      if (title == null) return body;
      final problems = pods == null ? 0 : pods.where(podHasProblem).length;
      return PodSection(
        key: const ValueKey('workload-pods'),
        id: 'workload-pods',
        title: title,
        trailing: pods == null || pods.isEmpty
            ? null
            : SectionSummary(podCountsSummary(pods), color: problems > 0 ? severityColor(context, Severity.warn) : null),
        child: body,
      );
    },
  );
}

/// Whether a pod in a workload's list needs a look: not running with all
/// containers ready (and not finished successfully).
bool podHasProblem(Json pod) {
  final s = podStatus(pod);
  if (s == 'Succeeded' || s == 'Completed') return false;
  final r = podReadyCount(pod);
  return s != 'Running' || r.ready < r.total;
}

/// "3 Running" / "2 Running · 1 CrashLoopBackOff", most first.
String podCountsSummary(List<Json> pods) {
  final counts = <String, int>{};
  for (final p in pods) {
    final s = podStatus(p);
    counts[s] = (counts[s] ?? 0) + 1;
  }
  final e = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return e.map((x) => '${x.value} ${x.key}').join(' · ');
}

/// Pods as compact rows, problems first: a state dot, the name, its state
/// when not plainly running, ready containers, restarts, node and age; the
/// restart/delete menu shows on hover. Long lists are trimmed.
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
    final ordered = [...pods.where(podHasProblem), ...pods.where((p) => !podHasProblem(p))];
    return LayoutBuilder(
      builder: (context, box) {
        // The node goes first when narrow; the name needs the room.
        final wide = box.maxWidth >= 400;
        return TrimmedList([for (final p in ordered) _PodRow(p, showNode: showNode && wide, stacked: !wide, menuCtx: _podCtx(p))], keep: 8, trimAbove: 10, gap: 0);
      },
    );
  }
}

class _PodRow extends StatelessWidget {
  final Json pod;
  final bool showNode;

  /// Narrow: the state goes under the name rather than beside it.
  final bool stacked;
  final PanelContext? menuCtx;
  const _PodRow(this.pod, {required this.showNode, this.stacked = false, this.menuCtx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final p = pod;
    final name = '${dig(p, ['metadata', 'name'])}';
    final ns = dig<String>(p, ['metadata', 'namespace']);
    final status = podStatus(p);
    final r = podReadyCount(p);
    final restarts = podRestarts(p);
    final node = dig<String>(p, ['spec', 'nodeName']);
    final problem = podHasProblem(p);
    final done = status == 'Succeeded' || status == 'Completed';
    final sev = problem ? (severityOf(status) == Severity.error ? Severity.error : Severity.warn) : (done ? Severity.neutral : Severity.ok);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]);
    final warn = severityColor(context, Severity.warn);
    final dotColor = severityColor(context, sev);
    final Widget link = OneLineLink(ObjectRef(kind: 'Pod', name: name, namespace: ns));
    final stateText = status == 'Running'
        ? null
        : Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small?.copyWith(color: problem ? severityColor(context, sev) : theme.hintColor, fontWeight: problem ? FontWeight.w600 : null),
          );
    return Hoverable(
      key: ValueKey('pod-row-$name'),
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
        padding: const EdgeInsets.fromLTRB(4, 5, 2, 5),
        child: Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: sev == Severity.neutral ? null : dotColor,
              shape: BoxShape.circle,
              border: sev == Severity.neutral ? Border.all(color: theme.hintColor, width: 1.2) : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: stacked && stateText != null
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [link, const SizedBox(height: 1), stateText])
                : Row(children: [Flexible(child: link), if (stateText != null) ...[const SizedBox(width: 8), Flexible(child: stateText)]]),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '${r.ready} of ${r.total} containers ready',
            child: Text('${r.ready}/${r.total}', style: hint?.copyWith(color: r.ready < r.total && !done ? warn : null)),
          ),
          SizedBox(
            width: 34,
            child: restarts == 0
                ? null
                : Tooltip(
                    message: plural(restarts, 'restart'),
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Icon(Icons.replay, size: 11, color: warn),
                      const SizedBox(width: 2),
                      Text('$restarts', style: small?.copyWith(color: warn, fontWeight: FontWeight.w600)),
                    ]),
                  ),
          ),
          if (showNode) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 120,
              child: node == null ? Text('unscheduled', style: hint) : OneLineLink(ObjectRef(kind: 'Node', name: node)),
            ),
          ],
          SizedBox(
            width: 34,
            child: Align(alignment: Alignment.centerRight, child: AgeText(dig(p, ['metadata', 'creationTimestamp']), style: hint)),
          ),
          if (menuCtx case final podCtx?)
            IgnorePointer(
              ignoring: !hovered,
              child: Opacity(opacity: hovered ? 1 : 0, child: SizedBox(width: 24, height: 20, child: _PodMenu(podCtx))),
            ),
        ]),
      ),
    );
  }
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
