/// The inspector's Security tab for Pods and pod controllers: the object's
/// findings (from `GET /api/security/object`, the Security page's analysis),
/// its images' vulnerabilities (Trivy), its effective security context and,
/// when Kyverno is connected, its policy results. Also the tab's count badge
/// and the one Overview insight kept for critical settings.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../addons/addons.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../modules/kyverno_module.dart' show kyvernoConnected;
import '../../modules/modules.dart' show moduleInspectorTabs;
import '../../panels/kyverno/index.dart' show ObjectPolicyResults, policyReportResource;
import '../../panels/registry.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../inspector/inspector.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import '../widgets/common.dart';
import 'ignore_ui.dart';
import 'security_api.dart';
import 'security_view.dart' show SecurityFocus;
import 'security_widgets.dart';

/// Kinds (`group/Kind`) with a Security tab.
const securityTabKinds = {'/Pod', 'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job', 'batch/CronJob'};

const _tabLabel = 'Security';

/// The Security tab for [ctx]'s object.
PanelTab securityTab(PanelContext ctx) => PanelTab(
      label: _tabLabel,
      badge: (context, ctx) => SecurityBadge(key: ValueKey('security-badge-${ctx.uid}'), ctx: ctx),
      builder: (context, ctx) => SecurityTabView(key: ValueKey('security-${ctx.uid}'), ctx: ctx),
    );

/// Switches the inspector to the Security tab (from inside the Overview).
void openSecurityTab(BuildContext context, PanelContext ctx) {
  final tabs = [...panelFor(ctx.type, ctx.app).tabs(ctx), ...moduleInspectorTabs(ctx)];
  final i = tabs.indexWhere((t) => t.label == _tabLabel);
  final c = DefaultTabController.maybeOf(context);
  if (i >= 0 && c != null) c.index = 1 + i;
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

const _keyPrefix = 'security-object|';

String _fetchKey(PanelContext ctx) =>
    '$_keyPrefix${identityHashCode(ctx.api)}|${ctx.app.currentContext}|${ctx.namespace}|${ctx.type.gk}|${ctx.name}|';

/// Refetches of a key whose answer still had categories loading.
final _pendingRetries = <String, int>{};

/// The object's security, shared by the badge and the tab. While the
/// backend still lists some categories, asks again a few times.
Future<ObjectSecurity> _load(PanelContext ctx) {
  final key = _fetchKey(ctx);
  return SharedFetch.get(key, () async {
    final d = await securityApiFor(ctx.api).forObject(namespace: ctx.namespace ?? '', kind: ctx.type.kind, name: ctx.name, group: ctx.type.group);
    if (d.pending.isEmpty) {
      _pendingRetries.remove(key);
    } else {
      final n = _pendingRetries[key] = (_pendingRetries[key] ?? 0) + 1;
      if (n <= 4) Timer(Duration(milliseconds: 800 * n), () => SharedFetch.invalidate(key));
    }
    return d;
  });
}

/// Refetch every object's security (after an ignore rule changed).
void _invalidateAll() => SharedFetch.invalidate(_keyPrefix);

/// The open findings and critical/high CVEs, and how bad the worst is
/// (null: nothing to show).
({int count, Severity? tone}) securityBadgeOf(ObjectSecurity d) {
  final cves = d.cveCounts;
  final count = d.findings.length + cves.critical + cves.high;
  if (count == 0) return (count: 0, tone: null);
  final sevs = {for (final f in d.findings) f.severity};
  if (sevs.contains(SecSeverity.critical) || cves.critical > 0) return (count: count, tone: Severity.error);
  if (sevs.contains(SecSeverity.high) || sevs.contains(SecSeverity.medium) || cves.high > 0) return (count: count, tone: Severity.warn);
  return (count: count, tone: Severity.neutral);
}

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

/// The tab label's count: open findings plus critical and high CVEs, red
/// when anything is critical, amber for high or medium, absent when clean
/// or unknown. Fetched a moment after the object is shown (arrowing
/// through rows doesn't fetch every one), at once when cached.
class SecurityBadge extends StatefulWidget {
  final PanelContext ctx;
  const SecurityBadge({super.key, required this.ctx});

  @override
  State<SecurityBadge> createState() => _SecurityBadgeState();
}

class _SecurityBadgeState extends State<SecurityBadge> {
  late bool _go = SharedFetch.has(_fetchKey(widget.ctx));
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    if (!_go) _wait = Timer(const Duration(milliseconds: 250), () => mounted ? setState(() => _go = true) : null);
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_go) return const SizedBox.shrink();
    final ctx = widget.ctx;
    return SharedFetchBuilder<ObjectSecurity>(
      fetchKey: _fetchKey(ctx),
      fetch: () => _load(ctx),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox.shrink();
        final b = securityBadgeOf(d);
        if (b.tone == null) return const SizedBox.shrink();
        final c = severityColor(context, b.tone!);
        return Padding(
          key: const ValueKey('security-badge'),
          padding: const EdgeInsets.only(left: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(b.count > 999 ? '999+' : '${b.count}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Overview insight
// ---------------------------------------------------------------------------

/// The one security line the Overview keeps: shown only for a critical
/// setting (privileged, host PID, node-level capabilities or host paths),
/// with a link to the Security tab. Draws nothing otherwise.
class SecurityInsight extends StatelessWidget {
  final PanelContext ctx;
  const SecurityInsight(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final reasons = criticalSecurityReasons(podSpecOf(ctx).spec);
    if (reasons.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final text = reasons.length == 1 ? reasons.first : '${reasons.first} (+${reasons.length - 1} more)';
    return InsightLine(
      Severity.error,
      text,
      key: const ValueKey('security-insight'),
      title: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(text),
        Text('  ·  ', style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w400)),
        _QuietLink('see Security', key: const ValueKey('security-insight-link'), onTap: () => openSecurityTab(context, ctx)),
      ]),
    );
  }
}

/// [ctx]'s pod spec and pod metadata: a Pod's own, a workload's template.
({Json spec, Json meta}) podSpecOf(PanelContext ctx) {
  final o = ctx.object;
  final tpl = switch (ctx.type.kind) {
    'Pod' => o,
    'CronJob' => asMap(dig(o, ['spec', 'jobTemplate', 'spec', 'template'])),
    _ => asMap(dig(o, ['spec', 'template'])),
  };
  return (spec: asMap(tpl['spec']), meta: asMap(tpl['metadata']));
}

const _baselineCaps = {
  'AUDIT_WRITE', 'CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'FSETID', 'KILL', 'MKNOD', 'NET_BIND_SERVICE', 'SETFCAP', 'SETGID', 'SETPCAP', 'SETUID', 'SYS_CHROOT', //
};
const _criticalCaps = {'SYS_ADMIN', 'ALL', 'SYS_MODULE', 'SYS_PTRACE', 'BPF'};

String _cap(Object c) => '$c'.toUpperCase().replaceFirst('CAP_', '');

bool _criticalHostPath(String path) {
  var p = path;
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.isEmpty || p == '/etc' || p == '/var/run' || p == '/run' || p.endsWith('.sock') || p == '/var/lib/kubelet' || p == '/proc';
}

List<Json> _allContainers(Json spec) => [...asMapList(spec['initContainers']), ...asMapList(spec['containers']), ...asMapList(spec['ephemeralContainers'])];

/// What makes [spec] critical, as the Security page's baseline checks rate
/// it: privileged containers, the host PID namespace, node-level
/// capabilities and sensitive host paths.
List<String> criticalSecurityReasons(Json spec) {
  final cs = _allContainers(spec);
  final privileged = [for (final c in cs) if (dig(c, ['securityContext', 'privileged']) == true) '${c['name']}'];
  final caps = <String>{
    for (final c in cs)
      for (final a in (dig<List>(c, ['securityContext', 'capabilities', 'add']) ?? const [])) if (_criticalCaps.contains(_cap(a))) _cap(a),
  };
  final paths = [for (final v in asMapList(spec['volumes'])) if (v['hostPath'] is Map && _criticalHostPath('${dig(v, ['hostPath', 'path']) ?? ''}')) '${dig(v, ['hostPath', 'path'])}'];
  return [
    if (privileged.isNotEmpty) privileged.length == 1 ? 'Privileged container' : '${privileged.length} privileged containers',
    if (spec['hostPID'] == true) 'Shares the host PID namespace',
    if (caps.isNotEmpty) 'Adds ${caps.join(', ')}',
    if (paths.isNotEmpty) 'Mounts ${paths.first} from the host',
  ];
}

// ---------------------------------------------------------------------------
// The tab
// ---------------------------------------------------------------------------

class SecurityTabView extends StatelessWidget {
  final PanelContext ctx;
  const SecurityTabView({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final kyverno = kyvernoConnected(ctx) ? policyReportResource(ctx) : null;
    return SelectionArea(
      child: SingleChildScrollView(
        key: PageStorageKey('security-${ctx.uid}'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SharedFetchBuilder<ObjectSecurity>(
            fetchKey: _fetchKey(ctx),
            fetch: () => _load(ctx),
            builder: (context, snap) {
              final d = snap.data;
              if (d == null && snap.hasError) return _Unavailable(snap.error!, onRetry: () => SharedFetch.invalidate(_fetchKey(ctx)));
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InspectorSection(
                  id: 'security-findings',
                  title: 'Findings',
                  trailing: d == null || d.pending.contains('workloads') ? null : SectionSummary(_findingsSummary(d)),
                  child: d == null ? const PendingSecurityRows(rows: 2) : _Findings(ctx: ctx, data: d),
                ),
                InspectorSection(
                  id: 'security-images',
                  title: 'Image vulnerabilities',
                  trailing: d == null ? null : _imagesSummary(context, d),
                  child: d == null ? const PendingSecurityRows(rows: 2) : _Images(ctx: ctx, data: d),
                ),
              ]);
            },
          ),
          InspectorSection(id: 'security-context', title: 'Security context', child: SecurityContextTable(ctx)),
          if (kyverno != null)
            ObjectPolicyResults(
              key: ValueKey('security-kyverno-${ctx.uid}'),
              ctx: ctx,
              resource: kyverno,
              wrap: (content, reload) => InspectorSection(id: 'security-policy', title: 'Policy results', trailing: RefreshButton(reload), child: content),
            ),
        ]),
      ),
    );
  }

  static String _findingsSummary(ObjectSecurity d) => [
        if (d.findings.isEmpty) 'none open' else '${d.findings.length} open',
        if (d.ignored.isNotEmpty) '${d.ignored.length} ignored',
      ].join(' · ');

  static Widget? _imagesSummary(BuildContext context, ObjectSecurity d) {
    if (d.pending.contains('images') || !d.images.any((i) => i.scanned)) return null;
    final c = d.cveCounts;
    if (c.critical + c.high == 0) return const SectionSummary('no critical or high');
    return SectionSummary(
      [if (c.critical > 0) '${c.critical} critical', if (c.high > 0) '${c.high} high'].join(' · '),
      color: sevColor(context, c.critical > 0 ? SecSeverity.critical : SecSeverity.high),
    );
  }
}

/// The fetch failed: forbidden reads as a quiet line, anything else with a
/// retry.
class _Unavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _Unavailable(this.error, {required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = error;
    final forbidden = e is ApiException && (e.status == 403 || e.reason == 'Forbidden');
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(children: [
        Expanded(child: HintText(forbidden ? 'Security findings need access to the workloads in this namespace.' : 'Could not load security findings: $e')),
        if (!forbidden) RefreshButton(onRetry),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

class _Findings extends StatefulWidget {
  final PanelContext ctx;
  final ObjectSecurity data;
  const _Findings({required this.ctx, required this.data});

  @override
  State<_Findings> createState() => _FindingsState();
}

class _FindingsState extends State<_Findings> {
  bool _showIgnored = false;

  SecurityApi get _api => securityApiFor(widget.ctx.api);

  Future<void> _change(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not save the ignore rules: $e')));
      return;
    }
    _invalidateAll();
  }

  Future<void> _ignore(SecFinding f) async {
    final rules = await showIgnoreDialog(context, f, widget.data.findings);
    if (rules == null || !mounted) return;
    final at = DateTime.now().toUtc().toIso8601String();
    await _change(() => _api.addIgnores([
          for (final r in rules) SecIgnoreRule(check: r.check, namespace: r.namespace, kind: r.kind, name: r.name, reason: r.reason, at: at),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (d.inherited)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Row(key: const ValueKey('security-from'), children: [
            Text('From ', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            Flexible(child: RefLink(d.target, label: '${d.target.kind}/${d.target.name}')),
          ]),
        ),
      if (d.pending.contains('workloads'))
        const PendingSecurityRows(rows: 2)
      else if (d.findings.isEmpty)
        const Padding(padding: EdgeInsets.only(left: 4), child: Quiet('No open findings'))
      else
        for (final f in d.findings) _FindingRow(key: ValueKey('security-finding-${f.id}'), finding: f, onIgnore: () => _ignore(f)),
      if (d.ignored.isNotEmpty) ...[
        ShowMoreLink(_showIgnored ? 'Hide ignored' : 'Show ${d.ignored.length} ignored', onTap: () => setState(() => _showIgnored = !_showIgnored)),
        if (_showIgnored)
          IgnoredList(
            items: d.ignored,
            coveredBy: (r) => d.ignored.where((i) => i.rule.sameTarget(r)).length,
            onUnignore: (f) => _change(() => _api.unignore(f)),
          ),
      ],
    ]);
  }
}

class _FindingRow extends StatelessWidget {
  final SecFinding finding;
  final VoidCallback onIgnore;
  const _FindingRow({super.key, required this.finding, required this.onIgnore});

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    return InspectorRow(
      memoryId: 'security-finding-${f.id}',
      leading: SevDot(f.severity, size: 7),
      title: Text(f.title),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: f.severity.label, style: TextStyle(color: f.severity.index <= SecSeverity.medium.index ? sevColor(context, f.severity) : null)),
        if (f.remediation.isNotEmpty) TextSpan(text: ' · ${f.remediation}'),
      ])),
      actions: [RowAction(key: ValueKey('ignore-${f.id}'), icon: Icons.visibility_off_outlined, tooltip: 'Ignore…', onTap: onIgnore)],
      details: (context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (f.detail.isNotEmpty) Text(f.detail, style: small),
        for (final c in f.checks)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('•  ', style: hint), Expanded(child: Text(c, style: small))]),
          ),
        if (f.remediation.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.build_outlined, size: 13, color: theme.hintColor)),
              const SizedBox(width: 6),
              Expanded(child: Text(f.remediation, style: hint)),
            ]),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Image vulnerabilities
// ---------------------------------------------------------------------------

class _Images extends StatelessWidget {
  final PanelContext ctx;
  final ObjectSecurity data;
  const _Images({required this.ctx, required this.data});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final app = context.read<AppState>();
    if (d.pending.contains('images')) return const PendingSecurityRows(rows: 2);
    final scanned = d.images.any((i) => i.scanned);
    if (!d.trivyOperator && !scanned) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Quiet('Trivy Operator isn\'t installed  ·  '),
          _QuietLink('Add-ons…', key: const ValueKey('security-install-trivy'), onTap: () => requestAddon(context, AddonIds.trivyOperator)),
        ]),
      );
    }
    final reports = [for (final i in d.images) ?i.report];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (n, img) in d.images.indexed)
        Padding(
          padding: EdgeInsets.only(top: n == 0 ? 0 : 14),
          child: _ImageBlock(key: ValueKey('security-image-${img.container}'), image: img, trivyOperator: d.trivyOperator),
        ),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Wrap(spacing: 14, runSpacing: 4, children: [
          if (reports.length == 1 && app.typeFor(reports.single.group, reports.single.kind) != null)
            _QuietLink('VulnerabilityReport', icon: Icons.description_outlined, onTap: () => openRef(context, reports.single))
          else
            for (final r in {for (final r in reports) r.name: r}.values)
              if (app.typeFor(r.group, r.kind) != null) _QuietLink(r.name, icon: Icons.description_outlined, onTap: () => openRef(context, r)),
          _QuietLink('Open in Security', key: const ValueKey('security-open-page'), icon: Icons.shield_outlined, onTap: () => SecurityFocus.open(app, d.target)),
        ]),
      ),
    ]);
  }
}

class _ImageBlock extends StatefulWidget {
  final ObjectImage image;
  final bool trivyOperator;
  const _ImageBlock({super.key, required this.image, required this.trivyOperator});

  @override
  State<_ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<_ImageBlock> {
  static const _top = 5;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final img = widget.image;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final shown = _all ? img.cves : img.cves.take(_top).toList();
    final c = img.counts;
    Widget count(int n, SecSeverity s) {
      final loud = n > 0 && s.index <= SecSeverity.medium.index;
      return Text('$n ${s.label.toLowerCase()}',
          style: small?.copyWith(color: loud ? sevColor(context, s) : theme.hintColor, fontWeight: loud ? FontWeight.w600 : null));
    }

    final sep = Text('  ·  ', style: small?.copyWith(color: theme.hintColor));
    return QuietGroup(img.container, [
      Padding(padding: const EdgeInsets.only(left: 4), child: MonoCopy(img.image)),
      if (!img.scanned)
        Padding(padding: const EdgeInsets.only(left: 4), child: Quiet(widget.trivyOperator ? 'Not scanned yet' : 'Not scanned'))
      else ...[
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            count(c.critical, SecSeverity.critical),
            sep,
            count(c.high, SecSeverity.high),
            sep,
            count(c.medium, SecSeverity.medium),
            sep,
            count(c.low, SecSeverity.low),
            if (c.fixable > 0) ...[sep, Text('${c.fixable} critical/high fixable', style: small?.copyWith(color: theme.hintColor))],
          ]),
        ),
        for (final v in shown) _CveRow(key: ValueKey('cve-${img.container}-${v.id}-${v.package}'), cve: v),
        if (img.cves.length > _top)
          ShowMoreLink(_all ? 'Show fewer' : 'Show all ${img.cves.length}', onTap: () => setState(() => _all = !_all)),
      ],
    ]);
  }
}

class _CveRow extends StatelessWidget {
  final Cve cve;
  const _CveRow({super.key, required this.cve});

  @override
  Widget build(BuildContext context) {
    final v = cve;
    final theme = Theme.of(context);
    final link = v.link;
    return InspectorRow(
      leading: SevDot(v.severity, size: 7),
      title: Text.rich(TextSpan(children: [
        TextSpan(text: v.id, style: monoStyle(context, size: 11.5).copyWith(fontWeight: FontWeight.w600)),
        TextSpan(text: '  ${v.package}'),
      ])),
      subtitle: Text([
        v.fixed == null ? '${v.installed} · no fix yet' : '${v.installed} → ${v.fixed}',
        if (v.title.isNotEmpty) v.title,
      ].join(' · ')),
      trailing: [
        if (v.fixed != null) Text('fixable', style: TextStyle(color: theme.hintColor)),
      ],
      actions: [if (link != null) RowAction(icon: Icons.open_in_new, tooltip: 'Open the advisory', onTap: () => openUrl(link))],
    );
  }
}

// ---------------------------------------------------------------------------
// Security context
// ---------------------------------------------------------------------------

/// The security context table's key column.
const double _keyWidth = 120;

/// One table cell: the text, how risky it is, and whether it comes from
/// the pod's securityContext.
typedef _Cell = ({String text, SecSeverity? risk, bool fromPod});

_Cell _cell(String text, [SecSeverity? risk, bool fromPod = false]) => (text: text, risk: risk, fromPod: fromPod);

/// The pod-level and per-container effective security settings as a
/// compact table (a column per container, settings inherited from the pod
/// in the hint colour), host namespaces and paths above it. Risky values
/// are in the Security page's severity colours.
class SecurityContextTable extends StatelessWidget {
  final PanelContext ctx;
  const SecurityContextTable(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final (:spec, :meta) = podSpecOf(ctx);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final pod = asMap(spec['securityContext']);
    final annotations = asMap(meta['annotations']);
    final containers = [
      for (final c in asMapList(spec['initContainers'])) (c, ' (init)'),
      for (final c in asMapList(spec['containers'])) (c, ''),
      for (final c in asMapList(spec['ephemeralContainers'])) (c, ' (debug)'),
    ];

    Widget value(_Cell c) {
      final risky = c.risk != null && c.risk!.index <= SecSeverity.medium.index;
      final t = Text(c.text,
          style: small?.copyWith(
            color: risky ? sevColor(context, c.risk!) : (c.fromPod || c.risk != null ? theme.hintColor : null),
            fontWeight: risky ? FontWeight.w600 : null,
          ));
      return c.fromPod ? Tooltip(message: 'From the pod\'s securityContext', child: t) : t;
    }

    // Pod-wide settings.
    final hostNs = [
      if (spec['hostPID'] == true) ('hostPID', SecSeverity.critical),
      if (spec['hostNetwork'] == true) ('hostNetwork', SecSeverity.high),
      if (spec['hostIPC'] == true) ('hostIPC', SecSeverity.high),
    ];
    final hostPaths = [for (final v in asMapList(spec['volumes'])) if (v['hostPath'] is Map) '${dig(v, ['hostPath', 'path']) ?? ''}'];
    final groups = [for (final g in (pod['supplementalGroups'] as List? ?? const [])) '$g'];
    final sysctls = [for (final s in asMapList(pod['sysctls'])) '${s['name']}=${s['value']}'];
    final podRows = <(String, Object?)>[
      (
        'Host namespaces',
        hostNs.isEmpty
            ? value(_cell('none'))
            : Wrap(spacing: 6, children: [for (final (n, s) in hostNs) value(_cell(n, s))]),
      ),
      if (hostPaths.isNotEmpty) ('Host paths', Wrap(spacing: 6, children: [for (final p in hostPaths) value(_cell(p, _criticalHostPath(p) ? SecSeverity.critical : SecSeverity.high))])),
      if (pod['fsGroup'] != null) ('fsGroup', value(_cell('${pod['fsGroup']}'))),
      if (groups.isNotEmpty) ('Groups', value(_cell(groups.join(', ')))),
      if (sysctls.isNotEmpty) ('Sysctls', value(_cell(sysctls.join(', ')))),
    ];

    // Per container, effective (container over pod).
    _Cell inherit(Json sc, String key, _Cell Function(dynamic v) show, _Cell unset) {
      if (sc[key] != null) return show(sc[key]);
      if (pod[key] != null) {
        final c = show(pod[key]);
        return _cell(c.text, c.risk, true);
      }
      return unset;
    }

    String? profile(Json? p) => p == null || p['type'] == null ? null : (p['type'] == 'Localhost' && p['localhostProfile'] != null ? 'Localhost ${p['localhostProfile']}' : '${p['type']}');
    final rows = <(String, _Cell Function(Json c, Json sc))>[
      ('Run as non-root', (c, sc) => inherit(sc, 'runAsNonRoot', (v) => v == true ? _cell('yes') : _cell('no', SecSeverity.low), _cell('not set', SecSeverity.low))),
      ('Run as user', (c, sc) => inherit(sc, 'runAsUser', (v) => v == 0 ? _cell('0 (root)', SecSeverity.medium) : _cell('$v'), _cell('image default'))),
      if (pod['runAsGroup'] != null || containers.any((c) => dig(c.$1, ['securityContext', 'runAsGroup']) != null))
        ('Run as group', (c, sc) => inherit(sc, 'runAsGroup', (v) => _cell('$v'), _cell('image default'))),
      ('Privileged', (c, sc) => sc['privileged'] == true ? _cell('yes', SecSeverity.critical) : _cell('no')),
      (
        'Privilege escalation',
        (c, sc) => switch (sc['allowPrivilegeEscalation']) {
              false => _cell('blocked'),
              true => _cell('allowed', SecSeverity.low),
              _ => _cell('not blocked', SecSeverity.low),
            },
      ),
      ('Read-only root fs', (c, sc) => sc['readOnlyRootFilesystem'] == true ? _cell('yes') : _cell('no', SecSeverity.low)),
      (
        'Capabilities added',
        (c, sc) {
          final add = [for (final a in (dig<List>(sc, ['capabilities', 'add']) ?? const [])) _cap(a)];
          if (add.isEmpty) return _cell('none');
          final risk = add.any(_criticalCaps.contains) ? SecSeverity.critical : (add.any((a) => !_baselineCaps.contains(a)) ? SecSeverity.high : null);
          return _cell(add.join(', '), risk);
        },
      ),
      (
        'Capabilities dropped',
        (c, sc) {
          final drop = [for (final d in (dig<List>(sc, ['capabilities', 'drop']) ?? const [])) _cap(d)];
          return drop.isEmpty ? _cell('none', SecSeverity.low) : _cell(drop.join(', '), drop.contains('ALL') ? null : SecSeverity.low);
        },
      ),
      (
        'Seccomp',
        (c, sc) => inherit(
              sc,
              'seccompProfile',
              (v) => switch (profile(asMap(v))) {
                'Unconfined' => _cell('Unconfined', SecSeverity.high),
                final String p => _cell(p),
                null => _cell('not set', SecSeverity.low),
              },
              _cell('not set', SecSeverity.low),
            ),
      ),
      (
        'AppArmor',
        (c, sc) {
          final ann = annotations['container.apparmor.security.beta.kubernetes.io/${c['name']}'];
          _Cell show(String? p) => p == null ? _cell('runtime default') : (p.toLowerCase() == 'unconfined' ? _cell(p, SecSeverity.high) : _cell(p));
          if (sc['appArmorProfile'] != null) return show(profile(asMap(sc['appArmorProfile'])));
          if (ann != null) return show('$ann');
          if (pod['appArmorProfile'] != null) {
            final v = show(profile(asMap(pod['appArmorProfile'])));
            return _cell(v.text, v.risk, true);
          }
          return show(null);
        },
      ),
      if (containers.any((c) => dig(c.$1, ['securityContext', 'procMount']) != null))
        ('procMount', (c, sc) => sc['procMount'] == null ? _cell('Default') : _cell('${sc['procMount']}', sc['procMount'] == 'Unmasked' ? SecSeverity.high : null)),
    ];

    final head = small?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    final table = Table(
      // The first column lines up with the pod rows' keys above.
      columnWidths: const {0: FixedColumnWidth(_keyWidth + 16)},
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(children: [
          const SizedBox.shrink(),
          for (final (c, suffix) in containers)
            Padding(padding: const EdgeInsets.fromLTRB(0, 0, 18, 4), child: Text('${c['name']}$suffix', style: head)),
        ]),
        for (final (label, of) in rows)
          TableRow(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(label, style: small?.copyWith(color: theme.hintColor))),
            for (final (c, _) in containers)
              Padding(padding: const EdgeInsets.fromLTRB(0, 3, 18, 3), child: value(of(c, asMap(c['securityContext'])))),
          ]),
      ],
    );
    return Column(key: const ValueKey('security-context'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable(podRows, keyWidth: _keyWidth),
      if (containers.isNotEmpty) ...[
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------

/// A quiet link: hint-coloured text (and an optional icon), underlined on
/// hover.
class _QuietLink extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback onTap;
  const _QuietLink(this.text, {super.key, required this.onTap, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (h) {
        final color = h ? theme.colorScheme.onSurface : theme.colorScheme.primary;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w400, decoration: h ? TextDecoration.underline : null)),
        ]);
      },
    );
  }
}
