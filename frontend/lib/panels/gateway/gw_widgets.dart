/// Widgets and fetch helpers shared by the Gateway API panels.
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../network/widgets.dart';
import 'gw_model.dart';

export '../network/widgets.dart' show NetFetch, NetTable, Mono, Muted, CopyText, CopyLine, Callout, RefreshButton, spinner, fingerprint;

/// Route kinds this cluster serves (TLS/TCP/UDP routes are experimental).
List<RouteKind> servedRouteKinds(AppState app) => [for (final k in routeKinds) if (app.typeForResource(gwGroup, k.resource) != null) k];

/// Every route of the served kinds, optionally in one namespace.
Future<List<RouteObj>> fetchRoutes(ApiClient api, AppState app, {String? namespace}) async {
  final kinds = servedRouteKinds(app);
  final lists = await Future.wait(kinds.map((k) async {
    try {
      return await api.items(k.ref, namespace: namespace);
    } on ApiException catch (e) {
      // A kind can vanish (CRD removed) between discovery and now.
      if (e.status == 404) return const <Json>[];
      rethrow;
    }
  }));
  return [
    for (var i = 0; i < kinds.length; i++)
      for (final o in lists[i]) RouteObj(kinds[i], o),
  ];
}

/// GET one object; null on 404. Other errors propagate.
Future<Json?> fetchOrNull(ApiClient api, ResourceRef r, {String? namespace, required String name}) async {
  try {
    return await api.object(r, namespace: namespace, name: name);
  } on ApiException catch (e) {
    if (e.status == 404) return null;
    rethrow;
  }
}

/// Existence of each object (key → exists; null when unknown, e.g. forbidden).
Future<Map<String, bool?>> existence(ApiClient api, Iterable<BackendRef> refs, {int limit = 40}) async {
  final unique = {for (final r in refs) r.key: r}.values.take(limit).toList();
  final results = await Future.wait(unique.map((r) async {
    final res = switch ((r.group, r.kind)) {
      ('', 'Service') => const ResourceRef(resource: 'services'),
      ('', 'Secret') => const ResourceRef(resource: 'secrets'),
      _ => null,
    };
    if (res == null) return null;
    try {
      return await fetchOrNull(api, res, namespace: r.namespace, name: r.name) != null;
    } on ApiException {
      return null;
    }
  }));
  return {for (var i = 0; i < unique.length; i++) unique[i].key: results[i]};
}

Severity diagSeverity(DiagLevel l) => switch (l) {
      DiagLevel.error => Severity.error,
      DiagLevel.warn => Severity.warn,
      DiagLevel.info => Severity.info,
    };

/// A diagnosis as a callout.
class DiagCallout extends StatelessWidget {
  final Diag diag;
  const DiagCallout(this.diag, {super.key});

  @override
  Widget build(BuildContext context) => Callout(severity: diagSeverity(diag.level), title: diag.title, detail: diag.detail);
}

/// Dense badge for a condition: "Accepted" / "Not accepted · Reason" / "Pending".
class CondBadge extends StatelessWidget {
  final Json? cond;
  final String label;
  final String negative;
  const CondBadge(this.cond, {super.key, required this.label, required this.negative});

  @override
  Widget build(BuildContext context) {
    final c = cond;
    if (c == null) return StatusBadge('$label: no status', dense: true, severity: Severity.warn);
    if (condTrue(c)) return StatusBadge(label, dense: true, severity: Severity.ok);
    if (c['status'] == 'Unknown') return StatusBadge('$label: ${c['reason'] ?? 'Unknown'}', dense: true, severity: Severity.warn);
    return StatusBadge('$negative${c['reason'] != null ? ' · ${c['reason']}' : ''}', dense: true, severity: Severity.error);
  }
}

/// Link to a Gateway API object, labelled "ns/name" (or "name").
Widget gwLink(String kind, String name, {String? namespace, String? label}) => ResourceLink(
      ObjectRef(group: gwGroup, kind: kind, name: name, namespace: namespace),
      label: label ?? (namespace != null ? '$namespace/$name' : name),
    );

/// Link to a route, labelled "Kind ns/name" when [showKind].
Widget routeLink(RouteObj r, {bool showKind = false, String? fromNamespace}) {
  final qualified = fromNamespace == r.namespace ? r.name : '${r.namespace}/${r.name}';
  return gwLink(r.kind.kind, r.name, namespace: r.namespace, label: showKind ? '${r.kind.kind} $qualified' : qualified);
}

/// Link to a backend (Service or other), with optional flags after it.
class BackendLine extends StatelessWidget {
  final BackendRef ref;
  final String fromNamespace;
  final int? percent;
  final bool? exists;
  final bool notPermitted;
  final String? suffix;
  const BackendLine(this.ref, {super.key, required this.fromNamespace, this.percent, this.exists, this.notPermitted = false, this.suffix});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: ResourceLink(ref.objectRef, label: '${ref.isService ? '' : '${ref.kind} '}${ref.label(fromNamespace)}'),
        ),
        if (ref.port != null) Text(':${ref.port}', style: monoStyle(context, size: 11.5, color: theme.hintColor)),
      ]),
      if (percent != null) Text('$percent%', style: monoStyle(context, size: 11.5)),
      if (suffix != null) Muted(suffix!),
      if (exists == false) StatusBadge('${ref.kind} not found', dense: true, severity: Severity.error),
      if (notPermitted) const StatusBadge('needs ReferenceGrant', dense: true, severity: Severity.error),
    ]);
  }
}

/// Small uppercase caption used for sub-groups inside a section.
class SubHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SubHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(children: [
        Expanded(
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// A block of rows separated by hairlines.
class HairlineList extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  const HairlineList(this.children, {super.key, this.padding = const EdgeInsets.symmetric(vertical: 6)});

  @override
  Widget build(BuildContext context) {
    final line = BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < children.length; i++)
        Container(
          decoration: BoxDecoration(border: i == 0 ? null : Border(top: line)),
          padding: padding,
          child: children[i],
        ),
    ]);
  }
}

/// Nested rows with a thin guide line on the left (for the topology tree).
class TreeIndent extends StatelessWidget {
  final Widget child;
  const TreeIndent({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6, top: 2),
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: AppColors.of(context).separator, width: 1))),
        child: child,
      );
}

/// One row of the topology tree: icon, a main widget and muted extras.
class TreeRow extends StatelessWidget {
  final IconData icon;
  final Widget main;
  final List<Widget> extras;
  final Severity? status;
  const TreeRow({super.key, required this.icon, required this.main, this.extras = const [], this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loud = status == Severity.error || status == Severity.warn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 13, color: loud ? severityColor(context, status!) : theme.hintColor),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [main, ...extras]),
        ),
      ]),
    );
  }
}
