import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../addons/addon_status.dart';
import '../../addons/addons.dart';
import '../../api/client.dart';
import '../../modules/helm_module.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../helm/helm_api.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/group_icon.dart';
import 'addon_install_dialog.dart';

/// Add-ons: the catalog as cards, each with its detected state on this
/// cluster and one-click install / upgrade / uninstall through Helm.
class AddonsView extends StatefulWidget {
  /// Injected in tests; defaults to [helmApiOf].
  final HelmApi? api;
  const AddonsView({super.key, this.api});

  @override
  State<AddonsView> createState() => _AddonsViewState();
}

/// Latest stable chart versions for unpinned add-ons, per repo/chart, kept
/// for the app session (the backend caches indexes for 10 minutes too).
final _latestCache = <String, String?>{};

class _AddonsViewState extends State<AddonsView> {
  late final HelmApi _helm = widget.api ?? helmApiOf(context);
  List<AddonStatus>? _statuses;
  String? _error;
  bool _scanning = false;
  int _seq = 0;
  String? _context;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_scan);
  }

  Future<void> _scan({bool rediscover = false}) async {
    final app = context.read<AppState>();
    final seq = ++_seq;
    _context = app.currentContext;
    setState(() => _scanning = true);
    try {
      if (rediscover) await app.refreshTypes().catchError((Object _) {});
      final s = await scanAddons(app.api, _helm, app.types);
      if (!mounted || seq != _seq) return;
      setState(() => (_statuses = [for (final x in s) x.addon.version == null ? x.withTarget(_latestCache[_key(x.addon)]) : x], _error = null, _scanning = false));
      unawaited(_loadLatest(seq));
    } on ApiException catch (e) {
      if (mounted && seq == _seq) setState(() => (_error = e.message, _scanning = false));
    } catch (e) {
      if (mounted && seq == _seq) setState(() => (_error = '$e', _scanning = false));
    }
  }

  static String _key(Addon a) => '${a.repo}|${a.chart}';

  /// Upgrade targets for installed, unpinned add-ons (in the background).
  Future<void> _loadLatest(int seq) async {
    final need = [
      for (final s in _statuses ?? const <AddonStatus>[])
        if (s.viaHelm && s.addon.version == null && !_latestCache.containsKey(_key(s.addon))) s.addon,
    ];
    if (need.isEmpty) return;
    await Future.wait([
      for (final a in need)
        _helm.chartVersions(a.repo, a.chart).then((v) => _latestCache[_key(a)] = latestStable(v), onError: (Object _) => null),
    ]);
    if (!mounted || seq != _seq) return;
    setState(() => _statuses = [for (final s in _statuses!) s.addon.version == null ? s.withTarget(_latestCache[_key(s.addon)]) : s]);
  }

  Future<void> _install(AddonStatus s) async {
    if (await showAddonInstallDialog(context, s.addon, api: _helm) && mounted) await _scan(rediscover: true);
  }

  Future<void> _upgrade(AddonStatus s) async {
    if (await showAddonInstallDialog(context, s.addon, api: _helm, upgrade: s) && mounted) await _scan(rediscover: true);
  }

  Future<void> _uninstall(AddonStatus s) async {
    final r = s.release!;
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final warn = severityColor(context, Severity.warn);
    final ok = await confirmAction(
      context,
      title: 'Uninstall ${s.addon.name}?',
      message: 'Deletes Helm release ${r.name} from ${r.namespace} and every object it created. '
          'k8sman features that rely on it (${s.addon.enables.toLowerCase()}) stop working.',
      kubeContext: app.currentContext,
      objectName: r.name,
      destructive: true,
      confirmLabel: 'Uninstall',
      width: 520,
      extra: Container(
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: warn.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: warn.withValues(alpha: 0.35))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                'CRDs, and with them every custom resource of those kinds in the cluster, may stay or be deleted depending on the chart.',
                if (s.addon.uninstallNote.isNotEmpty) s.addon.uninstallNote,
              ].join(' '),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Uninstalling ${r.name}…'),
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 3),
            ]),
          ),
        ),
      ),
    );
    try {
      final res = await _helm.uninstall(r.namespace, r.name);
      nav.pop();
      messenger?.showSnackBar(SnackBar(content: Text(res.message)));
    } on ApiException catch (e) {
      nav.pop();
      if (mounted) showActionError(context, e.message);
    } catch (e) {
      nav.pop();
      if (mounted) showActionError(context, '$e');
    }
    if (mounted) await _scan(rediscover: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    if (_context != null && _context != app.currentContext && !_scanning) scheduleMicrotask(_scan);
    final st = _statuses;
    final installed = st?.where((s) => s.installed).length ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Add-ons',
        subtitle: st == null ? null : Text('$installed installed · ${st.length - installed} available'),
        actions: [
          if (_scanning && st != null) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
          IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _scanning ? null : () => _scan(rediscover: true)),
        ],
      ),
      const Divider(),
      Expanded(
        child: st == null
            ? Center(child: _error == null ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(16), child: InlineMessage(_error!, isError: true)))
            : LayoutBuilder(builder: (context, box) {
                const pad = 16.0, gap = 12.0;
                final cols = ((box.maxWidth - 2 * pad + gap) / (360 + gap)).floor().clamp(1, 4);
                final rows = <List<AddonStatus>>[for (var i = 0; i < st.length; i += cols) st.sublist(i, (i + cols).clamp(0, st.length))];
                return ListView(padding: const EdgeInsets.all(pad), children: [
                  if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: InlineMessage(_error!, isError: true)),
                  if (app.readOnly)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: InlineMessage('Read-only mode: k8sman was started with --read-only, so add-ons can\'t be installed, upgraded or removed here.',
                          icon: Icons.lock_outline),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('Cluster tools k8sman builds on, installed with Helm on ${app.currentContext}.',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                    ),
                  for (final (i, row) in rows.indexed) ...[
                    if (i > 0) const SizedBox(height: gap),
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (var c = 0; c < cols; c++) ...[
                          if (c > 0) const SizedBox(width: gap),
                          Expanded(
                            child: c < row.length
                                ? AddonCard(
                                    key: ValueKey('addon-${row[c].addon.id}'),
                                    status: row[c],
                                    readOnly: app.readOnly,
                                    onInstall: () => _install(row[c]),
                                    onUpgrade: () => _upgrade(row[c]),
                                    onUninstall: () => _uninstall(row[c]),
                                  )
                                : const SizedBox(),
                          ),
                        ],
                      ]),
                    ),
                  ],
                ]);
              }),
      ),
    ]);
  }
}

/// The API group whose icon represents an add-on (all bundled with GroupIcon).
String addonIconGroup(String id) => switch (id) {
      AddonIds.metricsServer => 'metrics.k8s.io',
      AddonIds.prometheus => 'monitoring.coreos.com',
      AddonIds.trivyOperator => 'aquasecurity.github.io',
      AddonIds.argoCd => 'argoproj.io',
      AddonIds.envoyGateway => 'gateway.envoyproxy.io',
      AddonIds.certManager => 'cert-manager.io',
      _ => id,
    };

/// One add-on: what it enables, its state here and the actions.
class AddonCard extends StatelessWidget {
  final AddonStatus status;
  final bool readOnly;
  final VoidCallback onInstall, onUpgrade, onUninstall;
  const AddonCard({super.key, required this.status, required this.readOnly, required this.onInstall, required this.onUpgrade, required this.onUninstall});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final s = status;
    final a = s.addon;
    final r = s.release;
    final dim = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final (pill, sev) = switch (s.state) {
      AddonState.notInstalled => ('Not installed', Severity.neutral),
      AddonState.installed => ('Installed', Severity.ok),
      AddonState.external => ('Installed · not via Helm', Severity.info),
      AddonState.unhealthy => ('Unhealthy', Severity.error),
    };
    final ready = s.deployments.where((d) => d.healthy).length;
    final meta = <(String, String)>[
      if (r != null) ...[
        ('Release', '${r.name} · ${r.namespace}${s.customRelease ? ' (custom)' : ''}'),
        ('Chart', '${r.chartVersion}${r.appVersion.isEmpty ? '' : ' · app ${r.appVersion}'} · ${r.status}'),
      ] else if (s.installed)
        ('Detected', s.crdServed ? '${a.detectCrds.first} served' : 'Deployment ${a.detectDeployments.first}')
      else ...[
        ('Chart', '${a.chart} · ${a.version == null ? 'latest' : '${a.version} (pinned)'}'),
        ('Namespace', a.namespace),
      ],
      if (s.deployments.isNotEmpty) ('Workloads', '$ready/${s.deployments.length} deployment${s.deployments.length == 1 ? '' : 's'} available'),
    ];
    final problem = s.state == AddonState.unhealthy ? s.problem : '';
    final border = s.state == AddonState.unhealthy ? severityColor(context, Severity.error).withValues(alpha: 0.5) : colors.separator;
    final app = context.read<AppState>();
    final compact = TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8));

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GroupIcon(group: addonIconGroup(a.id), size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Wrap(spacing: 4, runSpacing: 4, children: [
                StatusBadge(pill, severity: sev),
                if (s.upgradeAvailable) StatusBadge('Upgrade available: ${s.targetVersion}', severity: Severity.info),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(a.enables, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(a.description, style: dim),
        const SizedBox(height: 10),
        for (final (k, v) in meta)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 72, child: Text(k, style: dim)),
              Expanded(child: Text(v, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
            ]),
          ),
        if (problem.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.error_outline, size: 13, color: severityColor(context, Severity.error)),
              const SizedBox(width: 6),
              Expanded(child: Text(problem, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error)))),
            ]),
          ),
        if (s.leftoverCrds)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Its CRDs are still served (left from an earlier install, or it runs in another namespace).', style: dim),
          ),
        if (s.state == AddonState.external)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Installed outside Helm (for example from manifests), so k8sman can\'t upgrade or remove it.', style: dim),
          ),
        if (a.links.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Used by', style: dim),
              for (final l in a.links) _Link(label: l.label, enabled: s.installed, onTap: () => openAddonLink(context, l)),
            ]),
          ),
        const Spacer(),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end, children: [
          if (r != null)
            TextButton(style: compact, onPressed: () => showHelmRelease(app, r.namespace, r.name), child: const Text('View release')),
          if (!readOnly && r != null)
            TextButton(
              style: compact.copyWith(foregroundColor: WidgetStatePropertyAll(theme.colorScheme.error)),
              onPressed: onUninstall,
              child: const Text('Uninstall…'),
            ),
          if (!readOnly && r != null && (s.upgradeAvailable || s.state == AddonState.unhealthy))
            FilledButton.tonal(style: FilledButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: onUpgrade, child: Text(s.upgradeAvailable ? 'Upgrade…' : 'Repair…')),
          if (!readOnly && !s.installed)
            FilledButton.tonal(style: FilledButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: onInstall, child: const Text('Install…')),
        ]),
      ]),
    );
  }
}

class _Link extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _Link({required this.label, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!enabled) return Text(label, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint));
    return Hoverable(
      onTap: onTap,
      builder: (h) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              decoration: h ? TextDecoration.underline : null,
              decorationColor: theme.colorScheme.primary.withValues(alpha: 0.6),
            )),
        Icon(Icons.chevron_right, size: 13, color: theme.colorScheme.primary),
      ]),
    );
  }
}
