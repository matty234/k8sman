import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../addons/addons.dart';
import '../../api/client.dart';
import '../../prometheus/prom_api.dart';
import '../../modules/modules.dart' show moduleEnabled;
import '../../modules/prometheus_module.dart';
import '../../state/app_state.dart';
import '../settings/settings_page.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import 'alerts_widgets.dart';
import 'silence_dialog.dart';
import 'silences_tab.dart';
import '../widgets/namespace_picker.dart';

/// Alertmanager alerts (plus Prometheus' pending ones) grouped by alertname,
/// with filters, silencing, and a Silences tab.
class AlertsView extends StatefulWidget {
  /// Override the data source (tests). Defaults to `PromApi.of(ApiClient)`.
  final PromApi? source;
  final Duration interval;

  /// Start on the Silences tab.
  final bool initialSilences;

  /// Current time (tests).
  final DateTime Function()? clock;

  /// In the bottom dock: a one-line toolbar instead of the page header, and
  /// tighter padding.
  final bool docked;
  const AlertsView({super.key, this.source, this.interval = const Duration(seconds: 15), this.initialSilences = false, this.clock, this.docked = false});

  @override
  State<AlertsView> createState() => _AlertsViewState();
}

class _AlertsViewState extends State<AlertsView> with PollingState {
  PromApi? _source;
  PromApi get prom => _source ??= widget.source ?? PromApi.of(context.read<ApiClient>());

  PromStatus? _status;
  AlertsData? _data;
  List<Silence>? _silences;
  String? _silencesError;
  Object? _error;
  bool _loading = false;
  int _seq = 0;

  /// Selected Alertmanager id (null = default).
  String? _instance;
  late bool _silencesTab = widget.initialSilences;

  final Set<AlertSeverity> _sev = {AlertSeverity.critical, AlertSeverity.warning, AlertSeverity.info};
  final Set<AlertState> _states = {AlertState.firing, AlertState.pending, AlertState.silenced};

  /// The page's own scope (independent of the table's namespace), defaulting
  /// to all namespaces and remembered for the session. Alerts are fetched
  /// cluster-wide and filtered here.
  NamespaceScope _ns = PageScope.of('alerts');
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) _refresh();
    });
    poll(widget.interval, () async {
      if (!_loading && mounted) await _refresh();
      return _error == null;
    });
  }

  Future<void> _refresh({bool rediscover = false}) async {
    if (!moduleEnabled(const PrometheusModule().id, context.read<AppState>().disabledModules)) return;
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        rediscover || _status == null ? prom.status(refresh: rediscover) : Future.value(_status),
        prom.alerts(instance: _instance),
      ]);
      final status = results[0] as PromStatus?;
      final data = results[1] as AlertsData;
      List<Silence>? silences;
      String? silencesError;
      if (data.alertmanager != null) {
        try {
          silences = await prom.silences(instance: data.alertmanager!.id);
        } on ApiException catch (e) {
          silencesError = e.message;
        } catch (e) {
          silencesError = '$e';
        }
      }
      if (!mounted || seq != _seq) return;
      setState(() {
        _status = status;
        _data = data;
        _silences = silences;
        _silencesError = silencesError;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // ---- filtering ----

  bool _stateOn(AlertState s) => _states.contains(s == AlertState.inhibited ? AlertState.silenced : s);

  List<PromAlert> _inNamespace(Iterable<PromAlert> alerts) {
    final ns = _ns;
    if (ns.isAll) return alerts.toList();
    return alerts.where((a) => a.namespace != null && ns.namespaces.contains(a.namespace)).toList();
  }

  List<(AlertGroup, List<PromAlert>)> _visibleGroups(AlertsData data) => [
        for (final g in data.groups)
          if (_inNamespace(g.alerts).where((a) => _sev.contains(a.severity) && _stateOn(a.state)).toList() case final l when l.isNotEmpty) (g, l),
      ];

  // ---- actions ----

  void _setScope(NamespaceScope ns) {
    if (ns == _ns) return;
    PageScope.set('alerts', ns);
    setState(() => _ns = ns);
    _refresh();
  }

  String? get _amId => _data?.alertmanager?.id;

  Future<void> _silence(String alertname, List<SilenceMatcher> matchers) async {
    final all = [for (final g in _data?.groups ?? const <AlertGroup>[]) ...g.alerts];
    final ok = await showSilenceDialog(context, prom: prom, alertname: alertname, matchers: matchers, instance: _amId, alerts: all);
    if (ok && mounted) _refresh();
  }

  Future<void> _expire(Silence s) async {
    final ok = await expireSilenceFlow(context, prom: prom, silence: s, instance: _amId);
    if (ok && mounted) _refresh();
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final data = _data;
    final scoped = data == null ? const <PromAlert>[] : _inNamespace([for (final g in data.groups) ...g.alerts]);
    final firing = scoped.where((a) => a.state == AlertState.firing).length;
    final pending = scoped.where((a) => a.state == AlertState.pending).length;
    final ams = _status?.alertmanager ?? const <PromInstance>[];

    final summary = Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: PageScopePicker(value: _ns, onChanged: _setScope)),
      if (data != null && !data.stackMissing) ...[
        const SizedBox(width: 10),
        Flexible(child: Text('$firing firing · $pending pending', overflow: TextOverflow.ellipsis, style: widget.docked ? Theme.of(context).textTheme.bodySmall : null)),
      ],
    ]);
    final actions = <Widget>[
        if (ams.length > 1)
          MenuButton<String>(
            tooltip: 'Alertmanager instance',
            onSelected: (id) {
              setState(() => _instance = id);
              _refresh();
            },
            items: () => [
              for (final a in ams)
                PopupMenuItem(
                  value: a.id,
                  height: 28,
                  child: Row(children: [
                    SizedBox(width: 18, child: a.id == (_instance ?? data?.alertmanager?.id) ? const Icon(Icons.check, size: 14) : null),
                    Flexible(child: Text(a.id, overflow: TextOverflow.ellipsis)),
                    if (!a.reachable) Text('  unreachable', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
                  ]),
                ),
            ],
            builder: (h) => Container(
              height: 26,
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: h ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(data?.alertmanager?.name ?? 'Alertmanager', overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
                Icon(Icons.unfold_more, size: 14, color: Theme.of(context).hintColor),
              ]),
            ),
          ),
        IconButton(
          tooltip: 'Refresh',
          icon: _loading ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)) : const Icon(Icons.refresh),
          onPressed: _loading ? null : () => _refresh(rediscover: true),
        ),
    ];
    final Widget header = widget.docked
        ? SizedBox(
            height: 34,
            child: Row(children: [
              const SizedBox(width: 10),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: summary)),
              ...actions,
              const SizedBox(width: 6),
            ]),
          )
        : PageHeader(title: 'Alerts', subtitle: summary, actions: actions);

    Widget body;
    if (!moduleEnabled(const PrometheusModule().id, app.disabledModules)) {
      body = Center(
        child: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const InlineMessage('Alerts come from Prometheus, and the Prometheus integration is turned off.'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => openSettings(context, module: const PrometheusModule().id), child: const Text('Integrations…')),
          ]),
        ),
      );
    } else if (data == null) {
      body = Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : SizedBox(
                width: 460,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  InlineMessage('Could not load alerts: ${_errorText(_error!)}', isError: true),
                  const SizedBox(height: 12),
                  FilledButton.tonal(onPressed: _refresh, child: const Text('Retry')),
                ]),
              ),
      );
    } else if (data.stackMissing) {
      body = const _StackMissing();
    } else if (data.alertmanager == null && data.prometheus == null) {
      // The search failed: don't offer to install a stack that may exist.
      body = Center(
        child: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            InlineMessage("Couldn't check for Prometheus and Alertmanager: ${data.discoveryError}", isError: true),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: () => _refresh(rediscover: true), child: const Text('Retry')),
          ]),
        ),
      );
    } else {
      body = _content(context, app, data, scoped);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      widget.docked ? Divider(height: 1, color: AppColors.of(context).separator) : const Divider(),
      Expanded(child: body),
    ]);
  }

  Widget _content(BuildContext context, AppState app, AlertsData data, List<PromAlert> scoped) {
    final theme = Theme.of(context);
    final canSilence = !app.readOnly && data.alertmanager != null && data.alertmanager!.reachable && data.errors['alertmanager'] == null;
    final silences = _silences ?? const <Silence>[];
    final activeSilences = silences.where((s) => s.active).length;
    final allAlerts = [for (final g in data.groups) ...g.alerts];

    final tabs = Row(children: [
      _Tab(label: 'Alerts', count: scoped.where((a) => a.state == AlertState.firing && a.severity != AlertSeverity.none).length, selected: !_silencesTab, onTap: () => setState(() => _silencesTab = false)),
      const SizedBox(width: 4),
      _Tab(label: 'Silences', count: activeSilences, selected: _silencesTab, onTap: () => setState(() => _silencesTab = true)),
    ]);

    final messages = <Widget>[
      if (_error != null) InlineMessage('Refresh failed: ${_errorText(_error!)}. Showing the last result.', isError: true),
      for (final e in data.errors.entries) InlineMessage('${e.key == 'alertmanager' ? 'Alertmanager' : 'Prometheus'}: ${e.value}', isError: true),
      if (data.alertmanager == null && data.prometheus != null)
        const InlineMessage('No Alertmanager found: showing alerts straight from Prometheus. Silences need an Alertmanager.'),
    ];

    final children = <Widget>[
      // The page's headline, as on the Overview (not in the narrow dock).
      if (!widget.docked) ...[_statusLine(context, scoped), const SizedBox(height: 18)],
      tabs,
      const SizedBox(height: 10),
    ];
    for (final m in messages) {
      children.addAll([m, const SizedBox(height: 8)]);
    }

    if (_silencesTab) {
      if (data.alertmanager == null) {
        children.add(const InlineMessage('Silences live in Alertmanager, and none was found.'));
      } else if (_silencesError != null) {
        children.add(InlineMessage('Could not load silences: $_silencesError', isError: true));
      } else if (_silences == null) {
        children.add(const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())));
      } else {
        children.add(SilencesList(silences: silences, alerts: allAlerts, onExpire: app.readOnly ? null : _expire, now: widget.clock?.call()));
      }
    } else {
      children.add(_filters(context, scoped));
      children.add(const SizedBox(height: 6));
      final groups = _visibleGroups(data);
      final hiddenElsewhere = !_ns.isAll ? allAlerts.where((a) => !_ns.namespaces.contains(a.namespace) && a.state == AlertState.firing).length : 0;
      if (groups.isEmpty) {
        children.add(_Empty(
          text: scoped.isEmpty ? 'No alerts${!_ns.isAll ? ' in ${_ns.namespaces.join(', ')}' : ''}.' : 'No alerts match the filters.',
        ));
      } else {
        for (final (i, (g, alerts)) in groups.indexed) {
          if (i > 0) children.add(Divider(height: 1, color: AppColors.of(context).separator));
          children.add(AlertGroupTile(
            key: ValueKey('group-${g.alertname}'),
            group: g,
            alerts: alerts,
            expanded: _expanded.contains(g.alertname),
            onToggle: () => setState(() => _expanded.contains(g.alertname) ? _expanded.remove(g.alertname) : _expanded.add(g.alertname)),
            onSilenceGroup: canSilence ? (name, l) => _silence(name, matchersForGroup(name, l)) : null,
            onSilenceAlert: canSilence ? (a) => _silence(a.alertname, matchersForAlert(a)) : null,
          ));
        }
      }
      if (hiddenElsewhere > 0) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(children: [
            Icon(Icons.filter_alt_outlined, size: 14, color: theme.hintColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text('$hiddenElsewhere firing alert${hiddenElsewhere == 1 ? '' : 's'} in other namespaces or cluster-wide.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ),
            TextButton(onPressed: () => _setScope(NamespaceScope.all), child: const Text('Show all')),
          ]),
        ));
      }
    }

    return PageScroll(padding: widget.docked ? const EdgeInsets.fromLTRB(12, 8, 12, 12) : const EdgeInsets.fromLTRB(20, 12, 20, 24), children: children);
  }

  /// "Firing · 1 critical · 17 warnings", or "Nothing firing", with a mark
  /// in the worst firing severity.
  Widget _statusLine(BuildContext context, List<PromAlert> scoped) {
    final firing = scoped.where((a) => a.state == AlertState.firing).toList();
    int count(AlertSeverity s) => firing.where((a) => a.severity == s).length;
    final crit = count(AlertSeverity.critical), warn = count(AlertSeverity.warning), info = count(AlertSeverity.info);
    final pending = scoped.where((a) => a.state == AlertState.pending).length;
    final mark = crit > 0 ? Severity.error : (warn > 0 ? Severity.warn : Severity.ok);
    final parts = <InlineSpan>[
      if (crit > 0) TextSpan(text: '$crit critical', style: TextStyle(color: alertSeverityColor(context, AlertSeverity.critical))),
      if (warn > 0) TextSpan(text: '$warn warning${warn == 1 ? '' : 's'}', style: TextStyle(color: alertSeverityColor(context, AlertSeverity.warning))),
      if (info > 0) TextSpan(text: '$info info'),
      if (pending > 0) TextSpan(text: '$pending about to fire'),
    ];
    return StatusLine(
      key: const ValueKey('alerts-status'),
      mark: StatusMark(severity: mark),
      headline: crit + warn > 0 ? 'Firing' : 'Nothing serious firing',
      detail: parts.isEmpty
          ? null
          : Text.rich(TextSpan(children: [
              for (final (i, p) in parts.indexed) ...[if (i > 0) const TextSpan(text: '  ·  '), p],
            ])),
    );
  }

  Widget _filters(BuildContext context, List<PromAlert> scoped) {
    final theme = Theme.of(context);
    int sevCount(AlertSeverity s) => scoped.where((a) => a.severity == s && _stateOn(a.state)).length;
    int stateCount(AlertState s) => scoped.where((a) => (a.state == s || (s == AlertState.silenced && a.state == AlertState.inhibited)) && _sev.contains(a.severity)).length;
    void toggle<T>(Set<T> set, T v) => setState(() => set.contains(v) ? set.remove(v) : set.add(v));

    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final s in AlertSeverity.values)
        FilterPill(
          key: ValueKey('sev-${s.name}'),
          label: s == AlertSeverity.none ? 'None' : '${s.name[0].toUpperCase()}${s.name.substring(1)}',
          count: sevCount(s),
          dot: s == AlertSeverity.none ? theme.hintColor : alertSeverityColor(context, s),
          selected: _sev.contains(s),
          onTap: () => toggle(_sev, s),
        ),
      Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 4), color: AppColors.of(context).separator),
      for (final s in const [AlertState.firing, AlertState.pending, AlertState.silenced])
        FilterPill(
          key: ValueKey('state-${s.name}'),
          label: alertStateLabel(s),
          count: stateCount(s),
          selected: _states.contains(s),
          onTap: () => toggle(_states, s),
        ),
    ]);
  }

  static String _errorText(Object e) => e is ApiException ? e.message : '$e';
}

class _Tab extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: selected ? colors.selection : (h ? colors.hover : null), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(children: [
        Icon(Icons.check_circle_outline, size: 28, color: severityColor(context, Severity.ok)),
        const SizedBox(height: 8),
        Text(text, style: theme.textTheme.bodyMedium),
      ]),
    );
  }
}

class _StackMissing extends StatelessWidget {
  const _StackMissing();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.notifications_off_outlined, size: 36, color: theme.hintColor),
            const SizedBox(height: 12),
            Text('No Alertmanager found', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'k8sman looks for Prometheus and Alertmanager through the Prometheus Operator, '
              'or by their usual Service names. Install the Prometheus stack to see alerts, '
              'silence them, and chart metrics history.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: () => requestAddon(context, AddonIds.prometheus), child: const Text('Install Prometheus stack…')),
          ]),
        ),
      ),
    );
  }
}
