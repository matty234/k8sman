import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../kubectl_menu.dart' show kubectlEnvOf;
import '../security/ignore_ui.dart';
import '../security/security_api.dart' show SecIgnoreRule;
import '../security/security_widgets.dart' show RefLink;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import 'upgrade_api.dart';

/// Upgrade readiness: what stands between the cluster and a newer
/// Kubernetes minor, per check (removed APIs, version skew, drain blockers,
/// webhooks, CRD storage versions, node health, add-ons), from
/// `GET /api/upgrade`. Read-only.
class UpgradeView extends StatefulWidget {
  /// Override the data source (tests). Defaults to [UpgradeApi.of].
  final UpgradeApi? source;
  const UpgradeView({super.key, this.source});

  @override
  State<UpgradeView> createState() => _UpgradeViewState();
}

/// The checks' icons on the page.
const _checkIcons = <String, IconData>{
  'apis': Icons.api_outlined,
  'skew': Icons.difference_outlined,
  'drain': Icons.move_down_outlined,
  'webhooks': Icons.webhook_outlined,
  'crds': Icons.schema_outlined,
  'nodes': Icons.dns_outlined,
  'addons': Icons.extension_outlined,
};

/// Findings shown per check before "Show all".
const _rowsPerCheck = 6;

class _UpgradeViewState extends State<UpgradeView> {
  UpgradeApi? _source;
  UpgradeData? _data;
  Object? _error;
  bool _loading = false;
  String? _target;
  DateTime? _updatedAt;
  int _seq = 0;
  bool _started = false;
  bool _showIgnored = false;
  Timer? _poll;
  final _open = <String>{};
  final _showAll = <String>{};

  UpgradeApi get source => _source ??= widget.source ?? UpgradeApi.of(context.read<ApiClient>());

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  static const _quickDelays = [Duration(milliseconds: 700), Duration(milliseconds: 1500), Duration(seconds: 3)];
  int _quickStep = 0;

  Future<void> _refresh() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final data = await source.fetch(target: _target);
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = data;
        _target ??= data.target;
        _error = null;
        _loading = false;
        _updatedAt = DateTime.now();
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// While checks are pending the backend has more on the way: fetch again
  /// soon. Otherwise the page waits for Refresh (nothing here changes fast).
  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (_data?.pending.isNotEmpty ?? false) {
      final delay = _quickDelays[_quickStep.clamp(0, _quickDelays.length - 1)];
      _quickStep++;
      _poll = Timer(delay, () {
        if (mounted && !_loading) _refresh();
      });
      return;
    }
    _quickStep = 0;
  }

  void _setTarget(String t) {
    if (t == _target) return;
    setState(() {
      _target = t;
      _open.clear();
    });
    _refresh();
  }

  Future<void> _ignore(UpgradeFinding f) async {
    final data = _data;
    if (data == null) return;
    final rules = await showIgnoreDialog(context, f.asSecFinding, [for (final v in data.findings) v.asSecFinding]);
    if (rules == null || !mounted) return;
    final at = DateTime.now().toUtc().toIso8601String();
    await _changeIgnores(() => source.addIgnores([
          for (final r in rules) SecIgnoreRule(check: r.check, namespace: r.namespace, kind: r.kind, name: r.name, reason: r.reason, at: at),
        ]));
  }

  Future<void> _changeIgnores(Future<void> Function() change) async {
    try {
      await change();
    } catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      _started = true;
      scheduleMicrotask(() {
        if (mounted) _refresh();
      });
    }
    final data = _data;
    final header = _header(context, data);
    if (data == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        const Divider(),
        Expanded(
          child: _error == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_error!, title: "Couldn't check upgrade readiness", onRetry: _refresh),
        ),
      ]);
    }
    // Switching target: the last target's results stay (dimmed, inert)
    // under a progress line until the new target's first answer arrives.
    final stale = _loading && _target != null && data.target != _target;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      stale ? const LinearProgressIndicator(key: ValueKey('upgrade-switching'), minHeight: 1) : const Divider(),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: ErrorNotice(_error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: _refresh),
        ),
      Expanded(
        child: IgnorePointer(
          ignoring: stale,
          child: AnimatedOpacity(
            opacity: stale ? 0.35 : 1,
            duration: const Duration(milliseconds: 120),
            child: PageScroll(padding: const EdgeInsets.fromLTRB(24, 22, 24, 28), children: _body(context, data)),
          ),
        ),
      ),
    ]);
  }

  Widget _header(BuildContext context, UpgradeData? data) {
    return PageHeader(
      title: 'Upgrade readiness',
      subtitle: data == null || data.targets.isEmpty ? null : _TargetPicker(current: data.serverVersion, targets: data.targets, value: _target ?? data.target, onChanged: _setTarget),
      actions: [
        if (_loading) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        if (_updatedAt != null) AgeText(_updatedAt!.toUtc().toIso8601String(), suffix: ' ago'),
        IconButton(
          tooltip: 'Refresh',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _refresh,
        ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, UpgradeData data) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final withFindings = [for (final c in data.checks) if (c.pending || data.findings.any((f) => f.check == c.id)) c];
    final clear = [for (final c in data.checks) if (c.isClear) c];
    final unavailable = [for (final c in data.checks) if (c.unavailable) c];
    final groups = <Widget>[];
    final weights = <int>[];
    for (final c in withFindings) {
      final fs = [for (final f in data.findings) if (f.check == c.id) f];
      groups.add(_checkGroup(context, c, fs));
      weights.add(fs.length.clamp(0, _rowsPerCheck) + c.notes.length + 2);
    }
    final problems = data.count(UpgradeSeverity.blocker) + data.count(UpgradeSeverity.warning);
    return [
      _Hero(data: data, checkedAt: _updatedAt),
      if (groups.isNotEmpty)
        EditorialSection(
          key: const ValueKey('upgrade-findings'),
          title: 'Before upgrading to ${data.target}',
          collapsible: false,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(problems == 0 ? plural(data.findings.length, 'note') : plural(problems, 'problem'), style: hint),
            if (data.ignored.isNotEmpty) ...[
              const SizedBox(width: 10),
              Hoverable(
                key: const ValueKey('toggle-ignored'),
                onTap: () => setState(() => _showIgnored = !_showIgnored),
                builder: (_) => Text('${data.ignored.length} ignored', style: hint?.copyWith(decoration: _showIgnored ? TextDecoration.underline : null)),
              ),
            ],
          ]),
          child: AttentionList(groups: groups, weights: weights),
        ),
      if (clear.isNotEmpty || unavailable.isNotEmpty)
        EditorialSection(
          key: const ValueKey('upgrade-clear'),
          title: 'All clear',
          collapsible: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (clear.isNotEmpty) HealthyLines(lines: [for (final c in clear) c.clear]),
            for (final c in clear)
              for (final n in c.notes) _NoteLine(n),
            for (final c in unavailable)
              for (final n in c.notes.isEmpty ? ["Couldn't check ${c.title.toLowerCase()}"] : c.notes) _NoteLine(n),
          ]),
        ),
      if (_showIgnored && data.ignored.isNotEmpty)
        EditorialSection(
          title: 'Ignored',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final i in data.ignored)
              AttentionRow(
                severity: Severity.neutral,
                label: i.finding.title,
                detail: '${i.rule.scope}${i.rule.reason.isEmpty ? '' : ' · ${i.rule.reason}'}',
                trailing: TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => _changeIgnores(() => source.unignore(i.finding)),
                  child: const Text('Unignore'),
                ),
              ),
          ]),
        ),
    ];
  }

  Widget _checkGroup(BuildContext context, UpgradeCheck c, List<UpgradeFinding> fs) {
    final theme = Theme.of(context);
    final worst = fs.isEmpty ? null : fs.map((f) => f.severity).reduce((a, b) => a.index <= b.index ? a : b);
    final problems = fs.where((f) => f.severity != UpgradeSeverity.info).length;
    final all = _showAll.contains(c.id);
    final shown = all ? fs : fs.take(_rowsPerCheck).toList();
    final rows = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final f in shown) ...[
        AttentionRow(
          key: ValueKey('finding-${f.id}'),
          severity: f.severity.badge,
          count: f.objects.length > 1 ? '${f.objects.length}' : '',
          label: f.title,
          detail: f.detail,
          selected: _open.contains(f.id),
          onTap: () => setState(() => _open.contains(f.id) ? _open.remove(f.id) : _open.add(f.id)),
          chevron: true,
        ),
        if (_open.contains(f.id)) _FindingDetail(finding: f, onIgnore: () => _ignore(f)),
      ],
      if (fs.length > shown.length || (all && fs.length > _rowsPerCheck))
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => setState(() => all ? _showAll.remove(c.id) : _showAll.add(c.id)),
            child: Text(all ? 'Show fewer' : 'Show all ${fs.length}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ),
      if (c.pending)
        Padding(
          key: ValueKey('pending-check-${c.id}'),
          padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
          child: Row(children: [
            const SkeletonBar(width: 90, height: 10),
            const SizedBox(width: 8),
            Text('Checking…', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
      for (final n in c.notes) _NoteLine(n, inset: 8),
    ]);
    return AttentionGroup(
      key: ValueKey('check-${c.id}'),
      icon: _checkIcons[c.id] ?? Icons.checklist,
      title: c.title,
      count: worst == null ? null : (problems > 0 ? problems : fs.length),
      countColor: worst == null || worst == UpgradeSeverity.info ? null : severityColor(context, worst.badge),
      rows: rows,
    );
  }
}

/// "v1.31.4 → 1.32 1.33 1.34": the server's version, then the targets.
class _TargetPicker extends StatelessWidget {
  final String current;
  final List<String> targets;
  final String value;
  final ValueChanged<String> onChanged;
  const _TargetPicker({required this.current, required this.targets, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(current, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 13, color: theme.hintColor)),
      for (final t in targets)
        Tooltip(
          message: 'Check an upgrade to $t',
          waitDuration: const Duration(milliseconds: 600),
          child: Hoverable(
            key: ValueKey('target-$t'),
            onTap: () => onChanged(t),
            builder: (h) => Container(
              margin: const EdgeInsets.only(right: 2),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: t == value ? colors.selection : (h ? colors.hover : null),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                t,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: tabularFigures,
                  fontWeight: t == value ? FontWeight.w600 : null,
                  color: t == value ? theme.colorScheme.onSurface : theme.hintColor,
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// "Ready for 1.33" / "Not ready for 1.33 · 2 blockers · 5 warnings", over
/// the figures.
class _Hero extends StatelessWidget {
  final UpgradeData data;
  final DateTime? checkedAt;
  const _Hero({required this.data, this.checkedAt});

  @override
  Widget build(BuildContext context) {
    final blockers = data.count(UpgradeSeverity.blocker);
    final warnings = data.count(UpgradeSeverity.warning);
    final info = data.count(UpgradeSeverity.info);
    final checking = data.checking;
    final t = data.target;
    final (headline, mark) = blockers > 0
        ? ('Not ready for $t', Severity.error)
        : checking
            ? ('Checking $t…', Severity.info)
            : warnings > 0
                ? ('Ready for $t, with warnings', Severity.warn)
                : ('Ready for $t', Severity.ok);
    final hint = statusDetailStyle(context);
    final detail = Text.rich(
      TextSpan(children: [
        if (blockers > 0) TextSpan(text: plural(blockers, 'blocker'), style: TextStyle(color: severityColor(context, Severity.error))),
        if (blockers > 0 && warnings > 0) const TextSpan(text: '  ·  '),
        if (warnings > 0) TextSpan(text: plural(warnings, 'warning'), style: TextStyle(color: severityColor(context, Severity.warn))),
        if (blockers + warnings == 0 && !checking) const TextSpan(text: 'nothing in the way'),
        if (checking) TextSpan(text: '${blockers + warnings > 0 ? '  ·  ' : ''}still checking'),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: hint,
    );
    final checks = data.checks.where((c) => !c.pending && !c.unavailable).length;
    final clear = data.checks.where((c) => c.isClear).length;
    final note = [
      'Running ${data.serverVersion}',
      if (data.nodes > 0) plural(data.nodes, 'node'),
      if (data.steps.length > 1) 'upgrades ${[data.current, ...data.steps].join(' → ')}',
    ].join(' · ');
    return Column(key: const ValueKey('upgrade-hero'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      StatusLine(mark: StatusMark(severity: mark), headline: headline, detail: detail, note: note),
      const SizedBox(height: 22),
      StatStrip(minCell: 110, maxCell: 170, items: [
        StatItem('blockers', checking && blockers == 0 ? null : '$blockers', tone: blockers > 0 ? Severity.error : null),
        StatItem('warnings', checking && warnings == 0 ? null : '$warnings', tone: warnings > 0 ? Severity.warn : null),
        StatItem('notes', '$info'),
        StatItem('checks clear', '$clear', of: clear < checks ? '/ $checks' : null),
      ]),
    ]);
  }
}

/// A quiet line saying what a check couldn't look at.
class _NoteLine extends StatelessWidget {
  final String text;
  final double inset;
  const _NoteLine(this.text, {this.inset = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = AppColors.of(context).faint;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 5, 6, 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.remove_circle_outline, size: 12, color: faint)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
      ]),
    );
  }
}

/// Under an opened finding: why it matters, what to do, its objects (each
/// opens in the inspector) and its actions.
class _FindingDetail extends StatelessWidget {
  final UpgradeFinding finding;
  final VoidCallback onIgnore;
  const _FindingDetail({required this.finding, required this.onIgnore});

  static const _maxObjects = 24;

  /// The command worth copying: the finding's own, else `kubectl get` of
  /// its first object.
  String? _kubectl(AppState app) {
    final env = kubectlEnvOf(app);
    final f = finding;
    if (f.kubectl.isNotEmpty) return env.args(f.kubectl);
    final o = f.objects.firstOrNull;
    final t = o == null ? null : app.typeFor(o.group, o.kind);
    if (o == null || t == null) return null;
    return env.get(t, [(namespace: o.namespace, name: o.name)]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final f = finding;
    final body = theme.textTheme.bodySmall;
    final label = body?.copyWith(fontWeight: FontWeight.w600, color: theme.hintColor);
    final kubectl = _kubectl(app);
    final objects = f.objects.take(_maxObjects).toList();
    Widget para(String head, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text.rich(TextSpan(children: [TextSpan(text: '$head  ', style: label), TextSpan(text: text)]), style: body),
        );
    return Container(
      key: ValueKey('finding-detail-${f.id}'),
      margin: const EdgeInsets.fromLTRB(28, 2, 6, 10),
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 2),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: severityColor(context, f.severity.badge).withValues(alpha: 0.5), width: 2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (f.why.isNotEmpty) para('Why it matters', f.why),
        if (f.action.isNotEmpty) para('What to do', f.action),
        if (objects.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final o in objects)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${o.kind} ', style: body?.copyWith(color: theme.hintColor)),
                  RefLink(o, showNamespace: true),
                ]),
              if (f.objects.length > objects.length) Text('+${f.objects.length - objects.length} more', style: body?.copyWith(color: theme.hintColor)),
            ]),
          ),
        Wrap(spacing: 4, children: [
          if (kubectl != null)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              icon: const Icon(Icons.terminal, size: 14),
              label: const Text('Copy kubectl'),
              onPressed: () => copyToClipboard(context, kubectl, label: 'kubectl command'),
            ),
          if (f.docs != null)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('Docs'),
              onPressed: () => openUrl(f.docs!),
            ),
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
            icon: const Icon(Icons.visibility_off_outlined, size: 14),
            label: const Text('Ignore…'),
            onPressed: onIgnore,
          ),
        ]),
      ]),
    );
  }
}
