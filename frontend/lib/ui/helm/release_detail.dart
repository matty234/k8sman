import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show PageScroll;
import 'helm_actions.dart';
import 'helm_api.dart';
import 'yaml_view.dart';
import '../inspector/inspector.dart' show Callout;

/// Detail for one release: header with actions, a stuck/failed banner, and
/// Overview / Values / Manifest / History / Hooks tabs.
class HelmReleaseDetailPane extends StatefulWidget {
  final HelmApi api;
  final HelmRelease release;

  /// Called after a mutation so the list refreshes.
  final VoidCallback onChanged;
  const HelmReleaseDetailPane({super.key, required this.api, required this.release, required this.onChanged});

  @override
  State<HelmReleaseDetailPane> createState() => _HelmReleaseDetailPaneState();
}

class _HelmReleaseDetailPaneState extends State<HelmReleaseDetailPane> {
  HelmReleaseDetail? _detail;
  List<HelmRelease>? _history;
  Object? _error;
  bool _computed = false;

  HelmRelease get _r => widget.release;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HelmReleaseDetailPane old) {
    super.didUpdateWidget(old);
    final o = old.release, n = widget.release;
    if (o.key != n.key) {
      setState(() => (_detail = null, _history = null, _error = null));
      _load();
    } else if (o.revision != n.revision || o.status != n.status) {
      _load();
    }
  }

  Future<void> _load() async {
    final key = _r.key;
    try {
      final results = await Future.wait([widget.api.release(_r.namespace, _r.name), widget.api.history(_r.namespace, _r.name)]);
      if (!mounted || key != _r.key) return;
      setState(() {
        _detail = results[0] as HelmReleaseDetail;
        _history = results[1] as List<HelmRelease>;
        _error = null;
      });
    } catch (e) {
      if (mounted && key == _r.key) setState(() => _error = e);
    }
  }

  void _changed(HelmResult? res) {
    if (res == null) return;
    widget.onChanged();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (d == null) {
      return _error != null ? LoadFailure(_error!, title: "Couldn't load release ${widget.release.name}", onRetry: _load) : const Center(child: CircularProgressIndicator());
    }
    final history = _history ?? const <HelmRelease>[];
    return DefaultTabController(
      length: 5,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(detail: d, history: history, api: widget.api, onChanged: _changed),
        if (d.stuck != null) _StuckBanner(detail: d, api: widget.api, onChanged: _changed),
        if (d.stuck == null && d.release.failed) _FailedBanner(detail: d),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Overview', height: 34),
            const Tab(text: 'Values', height: 34),
            const Tab(text: 'Manifest', height: 34),
            Tab(text: 'History  ${history.length}', height: 34),
            Tab(text: 'Hooks  ${d.hooks.length}', height: 34),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            _OverviewTab(detail: d),
            _ValuesTab(detail: d, computed: _computed, onComputed: (v) => setState(() => _computed = v)),
            Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 12), child: HelmYamlView(text: d.manifest)),
            _HistoryTab(detail: d, history: history, api: widget.api, onChanged: _changed),
            _HooksTab(detail: d),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Header and banners
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  final HelmReleaseDetail detail;
  final List<HelmRelease> history;
  final HelmApi api;
  final void Function(HelmResult?) onChanged;
  const _Header({required this.detail, required this.history, required this.api, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final r = detail.release;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final targets = [for (final h in history) if (h.revision != detail.latestRevision) h];
    final actions = app.readOnly
        ? const <Widget>[]
        : <Widget>[
            Tooltip(
              message: detail.upgradeBlocked.isNotEmpty
                  ? 'Can\'t upgrade from here: ${detail.upgradeBlocked}.'
                  : detail.stuck != null
                      ? 'Recover the stuck release first'
                      : 'Edit user values, review the rendered diff, then upgrade',
              child: FilledButton.tonalIcon(
                // Make "unavailable" unmistakable (the theme only dims the accent).
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: theme.colorScheme.surfaceContainerHigh,
                  disabledForegroundColor: theme.hintColor,
                ),
                onPressed: detail.upgradeBlocked.isNotEmpty || detail.stuck != null
                    ? null
                    : () async => onChanged(await upgradeReleaseValues(context, api, detail, kubeContext: app.currentContext)),
                icon: const Icon(Icons.tune),
                label: const Text('Edit values'),
              ),
            ),
            if (targets.isEmpty)
              OutlinedButton.icon(onPressed: null, icon: const Icon(Icons.history), label: const Text('Roll back'))
            else
            MenuButton<int>(
              tooltip: 'Roll back to a revision',
              items: () => [
                for (final h in targets)
                  PopupMenuItem(
                    value: h.revision,
                    height: 30,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Row(children: [
                        SizedBox(width: 30, child: Text('${h.revision}', style: monoStyle(context, size: 12))),
                        SizedBox(width: 92, child: StatusBadge(h.status, severity: helmStatusSeverity(h.status), dense: true)),
                        Flexible(child: Text(h.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
                      ]),
                    ),
                  ),
              ],
              onSelected: (rev) async =>
                  onChanged(await rollbackRelease(context, api, r, current: detail.latestRevision, target: rev, kubeContext: app.currentContext)),
              builder: (h) => IgnorePointer(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.history),
                  label: const Text('Roll back'),
                ),
              ),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
              ),
              onPressed: () async => onChanged(await uninstallRelease(context, api, detail, kubeContext: app.currentContext)),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Uninstall'),
            ),
          ];

    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Flexible(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium)),
        const SizedBox(width: 8),
        Flexible(child: StatusBadge(r.status, severity: helmStatusSeverity(r.status))),
      ]),
      const SizedBox(height: 2),
      Text(
        [
          'rev ${r.revision}',
          r.chartRef,
          if (r.appVersion.isNotEmpty) 'app ${r.appVersion}',
          r.namespace,
          if (r.updated != null) 'updated ${formatAge(r.updated)} ago',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: hint,
      ),
    ]);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
      child: LayoutBuilder(builder: (context, box) {
        if (actions.isEmpty) return title;
        if (box.maxWidth >= 700) {
          return Row(children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            for (final a in actions) ...[const SizedBox(width: 6), a],
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          title,
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: actions),
        ]);
      }),
    );
  }
}

class _Banner extends StatelessWidget {
  final Severity severity;
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  const _Banner({required this.severity, required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Callout(severity: severity, icon: icon, title: title, body: body, action: action),
      );
}

class _StuckBanner extends StatelessWidget {
  final HelmReleaseDetail detail;
  final HelmApi api;
  final void Function(HelmResult?) onChanged;
  const _StuckBanner({required this.detail, required this.api, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = detail.stuck!;
    final r = detail.release;
    Widget? action;
    if (!app.readOnly) {
      action = s.rollbackTo > 0
          ? FilledButton(
              onPressed: () async => onChanged(await rollbackRelease(
                context,
                api,
                r,
                current: detail.latestRevision,
                target: s.rollbackTo,
                kubeContext: app.currentContext,
                title: 'Recover ${r.name} by rolling back to revision ${s.rollbackTo}?',
                message: 'Revision ${s.revision} is stuck in ${s.status}. Rolling back to the last deployed revision (${s.rollbackTo}) '
                    'clears the lock so the release can be upgraded again. Below: the change compared with the stuck revision.',
              )),
              child: Text('Roll back to ${s.rollbackTo}'),
            )
          : OutlinedButton(
              onPressed: () async => onChanged(await uninstallRelease(context, api, detail, kubeContext: app.currentContext)),
              child: const Text('Uninstall…'),
            );
    }
    return _Banner(
      severity: Severity.warn,
      icon: Icons.lock_clock,
      title: 'Stuck in ${s.status} (revision ${s.revision})',
      body: 'A previous Helm operation was interrupted, and Helm refuses further upgrades until this is resolved. ${s.remedy}',
      action: action,
    );
  }
}

class _FailedBanner extends StatelessWidget {
  final HelmReleaseDetail detail;
  const _FailedBanner({required this.detail});

  @override
  Widget build(BuildContext context) => _Banner(
        severity: Severity.error,
        icon: Icons.error_outline,
        title: 'Revision ${detail.release.revision} failed',
        body: detail.release.description.isEmpty ? 'No description recorded.' : detail.release.description,
      );
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

class _OverviewTab extends StatelessWidget {
  final HelmReleaseDetail detail;
  const _OverviewTab({required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = detail.release;
    final c = detail.chart;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final byKind = <String, List<ObjectRef>>{};
    for (final o in detail.resources) {
      byKind.putIfAbsent(o.kind, () => []).add(o);
    }
    return PageScroll(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      DetailSection(
        title: 'Release',
        divider: false,
        child: KeyValueTable([
          ('Status', StatusBadge(r.status, severity: helmStatusSeverity(r.status), dense: true)),
          ('Revision', detail.isLatest ? '${r.revision}' : '${r.revision} (latest ${detail.latestRevision})'),
          ('Namespace', r.namespace),
          ('First deployed', detail.firstDeployed == null ? null : '${formatAge(detail.firstDeployed)} ago · ${_ts(detail.firstDeployed!)}'),
          ('Last deployed', detail.lastDeployed == null ? null : '${formatAge(detail.lastDeployed)} ago · ${_ts(detail.lastDeployed!)}'),
          ('Description', r.description.isEmpty ? null : Text(r.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
        ]),
      ),
      DetailSection(
        title: 'Resources',
        trailing: Text('${detail.resources.length}'),
        child: detail.resources.isEmpty
            ? Text('No resources in the manifest', style: hint)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final e in byKind.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 140, child: Text(e.key, overflow: TextOverflow.ellipsis, style: hint)),
                      Expanded(
                        child: Wrap(spacing: 12, runSpacing: 2, children: [
                          for (final o in e.value) ResourceLink(o, label: o.namespace != null && o.namespace != r.namespace ? '${o.namespace}/${o.name}' : o.name),
                        ]),
                      ),
                    ]),
                  ),
              ]),
      ),
      if (detail.notes.trim().isNotEmpty) DetailSection(title: 'Notes', child: CodeBlock(detail.notes.trimRight())),
      DetailSection(
        title: 'Chart',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            ('Name', c.name),
            ('Version', c.deprecated ? '${c.version} (deprecated)' : c.version),
            ('App version', c.appVersion),
            ('Description', c.description),
            ('Type', c.type),
            ('Home', c.home.isEmpty ? null : SelectableText(c.home, style: theme.textTheme.bodySmall)),
            ('Sources', c.sources.isEmpty ? null : SelectableText(c.sources.join('\n'), style: theme.textTheme.bodySmall)),
            ('Icon', c.icon.isEmpty ? null : SelectableText(c.icon, style: theme.textTheme.bodySmall)),
            ('Kubernetes', c.kubeVersion),
            ('Keywords', c.keywords.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final k in c.keywords) Chipish(text: k)])),
          ]),
          if (c.dependencies.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Dependencies', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 4),
            for (final dep in c.dependencies)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(dep.alias.isNotEmpty ? '${dep.name} (as ${dep.alias})' : dep.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  if (dep.version.isNotEmpty) Text(dep.version, style: monoStyle(context, size: 11)),
                  if (dep.condition.isNotEmpty) Chipish(text: 'if ${dep.condition}'),
                  if (dep.repository.isNotEmpty) Text(dep.repository, style: hint),
                ]),
              ),
          ],
          if (detail.upgradeBlocked.isNotEmpty) ...[
            const SizedBox(height: 8),
            InlineMessage('Editing values isn\'t available: ${detail.upgradeBlocked}.'),
          ],
        ]),
      ),
    ]);
  }
}

String _ts(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class _ValuesTab extends StatelessWidget {
  final HelmReleaseDetail detail;
  final bool computed;
  final ValueChanged<bool> onComputed;
  const _ValuesTab({required this.detail, required this.computed, required this.onComputed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = computed ? detail.computedValues : detail.values;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('User-supplied')), ButtonSegment(value: true, label: Text('Computed'))],
            selected: {computed},
            onSelectionChanged: (s) => onComputed(s.first),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              computed ? 'Chart defaults merged with user values' : 'Values passed with --values / --set',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
          IconButton(tooltip: 'Copy', iconSize: 16, icon: const Icon(Icons.copy), onPressed: () => copyToClipboard(context, text, label: 'values')),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: text.trim().isEmpty
              ? Center(child: Text(computed ? 'No values' : 'No user-supplied values (chart defaults only)', style: TextStyle(color: theme.hintColor)))
              : HelmYamlView(key: ValueKey(computed), text: text),
        ),
      ]),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  final HelmReleaseDetail detail;
  final List<HelmRelease> history;
  final HelmApi api;
  final void Function(HelmResult?) onChanged;
  const _HistoryTab({required this.detail, required this.history, required this.api, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final app = context.watch<AppState>();
    final hint = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    final latest = detail.latestRevision;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 620;
      return ListView(padding: const EdgeInsets.fromLTRB(6, 6, 6, 16), children: [
        SizedBox(
          height: 26,
          child: Row(children: [
            const SizedBox(width: 10),
            SizedBox(width: 40, child: Text('Rev', style: hint)),
            SizedBox(width: 120, child: Text('Status', style: hint)),
            if (wide) SizedBox(width: 150, child: Text('Chart', style: hint)),
            SizedBox(width: 64, child: Text('Updated', style: hint)),
            Expanded(child: Text('Description', style: hint)),
          ]),
        ),
        for (var i = 0; i < history.length; i++)
          _HistoryRow(
            h: history[i],
            striped: i.isOdd,
            current: history[i].revision == latest,
            wide: wide,
            colors: colors,
            onDiff: history[i].revision == latest ? null : () => showRevisionDiff(context, api, history[i], from: history[i].revision, to: latest),
            onRollback: history[i].revision == latest || app.readOnly
                ? null
                : () async => onChanged(await rollbackRelease(context, api, history[i], current: latest, target: history[i].revision, kubeContext: app.currentContext)),
          ),
      ]);
    });
  }
}

class _HistoryRow extends StatelessWidget {
  final HelmRelease h;
  final bool striped, current, wide;
  final AppColors colors;
  final VoidCallback? onDiff, onRollback;
  const _HistoryRow({required this.h, required this.striped, required this.current, required this.wide, required this.colors, this.onDiff, this.onRollback});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      builder: (hovered) => Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(color: hovered ? colors.hover : (striped ? colors.stripe : null), borderRadius: BorderRadius.circular(5)),
        child: Row(children: [
          SizedBox(width: 40, child: Text('${h.revision}', style: monoStyle(context, size: 12).copyWith(fontWeight: current ? FontWeight.w700 : null))),
          SizedBox(width: 120, child: StatusBadge(h.status, severity: helmStatusSeverity(h.status), dense: true)),
          if (wide) SizedBox(width: 150, child: Text(h.chartRef, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
          SizedBox(width: 64, child: Text(h.updated == null ? '' : formatAge(h.updated), style: small?.copyWith(color: theme.hintColor))),
          Expanded(
            child: Tooltip(
              message: h.description.length > 80 ? h.description : '',
              child: Text(h.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
            ),
          ),
          if (current)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('current', style: small?.copyWith(color: theme.hintColor)))
          else ...[
            IconButton(tooltip: 'Diff with current', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.difference_outlined), onPressed: onDiff),
            if (onRollback != null)
              IconButton(tooltip: 'Roll back to this revision', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.history), onPressed: onRollback),
          ],
        ]),
      ),
    );
  }
}

class _HooksTab extends StatelessWidget {
  final HelmReleaseDetail detail;
  const _HooksTab({required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    if (detail.hooks.isEmpty) return Center(child: Text('This chart has no hooks', style: TextStyle(color: theme.hintColor)));
    return PageScroll(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      for (final h in detail.hooks)
        DetailSection(
          title: '${h.kind} ${h.name}',
          divider: h != detail.hooks.first,
          trailing: StatusBadge(h.phase.isEmpty ? 'not run' : h.phase, severity: switch (h.phase) {
            'Succeeded' => Severity.ok,
            'Failed' => Severity.error,
            'Running' => Severity.warn,
            _ => Severity.neutral,
          }, dense: true),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KeyValueTable([
              ('Object', ResourceLink(ObjectRef(group: h.group, kind: h.kind, name: h.name, namespace: detail.release.namespace))),
              ('Events', Wrap(spacing: 4, runSpacing: 4, children: [for (final e in h.events) Chipish(text: e)])),
              ('Weight', '${h.weight}'),
              ('Delete policy', h.deletePolicies.join(', ')),
              ('Last run', h.startedAt == null ? 'never' : '${formatAge(h.startedAt)} ago'),
              ('Took', h.startedAt != null && h.completedAt != null ? formatDuration(h.completedAt!.difference(h.startedAt!)) : null),
              ('Template', h.path),
            ]),
            if (h.manifest.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Manifest', style: hint),
              const SizedBox(height: 4),
              CodeBlock(h.manifest.trim()),
            ],
          ]),
        ),
    ]);
  }
}
