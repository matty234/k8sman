/// Install / upgrade dialog for catalog add-ons: release, namespace,
/// version and values → optional dry run (rendered objects by kind) →
/// confirmation naming the context → install with `wait` and a progress
/// bar → result with notes and what's next.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../../actions/actions.dart';
import '../../addons/addon_status.dart';
import '../../addons/addons.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../helm/helm_actions.dart' show HelmDiffPane;
import '../helm/helm_api.dart';
import '../helm/yaml_view.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// How long the backend waits for an install/upgrade to become ready.
const addonWaitSeconds = 300;

/// The [HelmApi] to use from [context]: an injected one (tests) or one on
/// the app's [ApiClient].
HelmApi helmApiOf(BuildContext context) {
  try {
    return Provider.of<HelmApi>(context, listen: false);
  } on ProviderNotFoundException {
    return HelmApi(context.read<ApiClient>());
  }
}

/// Opens where an add-on shows up in k8sman.
Future<void> openAddonLink(BuildContext context, AddonLink link) async {
  final app = context.read<AppState>();
  final view = link.view;
  if (view != null) return app.showView(view);
  var t = app.typeFor(link.group, link.kind);
  if (t == null) {
    // Freshly installed CRDs aren't discovered yet.
    await app.refreshTypes();
    t = app.typeFor(link.group, link.kind);
  }
  if (t != null) {
    app.selectType(t);
  } else if (context.mounted) {
    showActionError(context, '${link.kind} (${link.group}) isn\'t served by this cluster yet.');
  }
}

/// Install [addon] (or, with [upgrade], upgrade its release). Returns true
/// if the cluster changed. In read-only mode, explains why it can't.
Future<bool> showAddonInstallDialog(BuildContext context, Addon addon, {HelmApi? api, AddonStatus? upgrade}) async {
  final app = context.read<AppState>();
  if (app.readOnly) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Install ${addon.name}'),
        content: SizedBox(
          width: 420,
          child: Text('k8sman is running in read-only mode, so it can\'t install add-ons. '
              '${addon.name} enables: ${addon.enables.toLowerCase()}.'),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
    return false;
  }
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AddonInstallDialog(addon: addon, api: api ?? helmApiOf(context), app: app, upgrade: upgrade),
  );
  return changed == true;
}

enum _Phase { edit, rendering, running, done, failed }

class AddonInstallDialog extends StatefulWidget {
  final Addon addon;
  final HelmApi api;
  final AppState app;

  /// Upgrade this (installed via Helm) add-on instead of installing.
  final AddonStatus? upgrade;
  const AddonInstallDialog({super.key, required this.addon, required this.api, required this.app, this.upgrade});

  @override
  State<AddonInstallDialog> createState() => _AddonInstallDialogState();
}

class _AddonInstallDialogState extends State<AddonInstallDialog> {
  Addon get a => widget.addon;
  HelmRelease? get _release => widget.upgrade?.release;
  bool get _upgrading => _release != null;

  late final _name = TextEditingController(text: _release?.name ?? a.releaseName);
  late final _namespace = TextEditingController(text: _release?.namespace ?? a.namespace);
  late final _values = CodeLineEditingController.fromText(_upgrading ? '' : a.values);

  List<HelmChartVersion>? _versions;
  String? _versionsError;
  String? _version;

  _Phase _phase = _Phase.edit;
  HelmResult? _dry;

  /// Inputs the dry run was rendered from; stale once they change.
  String? _dryKey;
  HelmResult? _result;
  String? _error;
  String? _hint;

  /// The release's current user values (upgrade), for the diff.
  String _currentValues = '';

  @override
  void initState() {
    super.initState();
    _version = widget.upgrade?.targetVersion ?? a.version;
    _values.addListener(_onValuesChanged);
    _loadVersions();
    if (_upgrading) _loadCurrentValues();
  }

  String _lastValues = '';

  /// Rebuild only when the text changes (not on cursor moves).
  void _onValuesChanged() {
    if (_values.text == _lastValues) return;
    _lastValues = _values.text;
    // The editor can notify while it builds; rebuild after the frame then.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _namespace.dispose();
    _values.dispose();
    super.dispose();
  }

  Future<void> _loadVersions() async {
    try {
      final v = await widget.api.chartVersions(a.repo, a.chart);
      if (!mounted) return;
      setState(() {
        _versions = v;
        _version ??= latestStable(v);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _versionsError = e.message);
    } catch (e) {
      if (mounted) setState(() => _versionsError = '$e');
    }
  }

  Future<void> _loadCurrentValues() async {
    final r = _release!;
    try {
      final d = await widget.api.release(r.namespace, r.name);
      if (!mounted) return;
      _currentValues = d.values;
      _values.text = d.values.trim().isEmpty || d.values.trim() == '{}' ? a.values : d.values;
    } catch (_) {
      if (mounted) _values.text = a.values;
    }
  }

  String get _inputsKey => [_name.text.trim(), _namespace.text.trim(), _version ?? '', _values.text].join('\u0000');

  Future<HelmResult> _call({required bool dryRun}) {
    final r = _release;
    final version = (_version ?? '').isEmpty ? null : _version;
    if (r != null) {
      return widget.api.upgradeChart(r.namespace, r.name,
          repo: a.repo, chart: a.chart, version: version, values: _values.text, dryRun: dryRun, wait: !dryRun, timeoutSeconds: dryRun ? null : addonWaitSeconds);
    }
    return widget.api.install(
      namespace: _namespace.text.trim(),
      releaseName: _name.text.trim(),
      repo: a.repo,
      chart: a.chart,
      version: version,
      values: _values.text,
      dryRun: dryRun,
      wait: !dryRun,
      timeoutSeconds: dryRun ? null : addonWaitSeconds,
    );
  }

  /// Renders without changing anything. Returns false on error.
  Future<bool> _dryRun() async {
    if (_name.text.trim().isEmpty || _namespace.text.trim().isEmpty) {
      setState(() => _error = 'Release name and namespace are required.');
      return false;
    }
    setState(() => (_phase = _Phase.rendering, _error = null, _hint = null));
    try {
      final res = await _call(dryRun: true);
      if (!mounted) return false;
      setState(() => (_dry = res, _dryKey = _inputsKey, _phase = _Phase.edit));
      return true;
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.message, _phase = _Phase.edit));
    } catch (e) {
      if (mounted) setState(() => (_error = '$e', _phase = _Phase.edit));
    }
    return false;
  }

  Future<void> _apply() async {
    // Always confirm against a fresh render, so the confirmation can say what it creates.
    if (_dry == null || _dryKey != _inputsKey) {
      if (!await _dryRun() || !mounted) return;
    }
    final ok = await _confirm(_dry!);
    if (ok != true || !mounted) return;
    setState(() => (_phase = _Phase.running, _error = null));
    try {
      final res = await _call(dryRun: false);
      if (mounted) setState(() => (_result = res, _phase = _Phase.done));
    } on ApiException catch (e) {
      await _failed(e.message);
    } catch (e) {
      await _failed('$e');
    }
  }

  Future<void> _failed(String message) async {
    String? hint;
    final m = message.toLowerCase();
    if (a.compatibility.isNotEmpty || m.contains('kubeversion') || m.contains('kubernetes version') || m.contains('no matches for kind')) {
      final v = await _clusterVersion();
      hint = [
        if (v != null) 'This cluster runs Kubernetes $v.',
        if (a.compatibility.isNotEmpty) a.compatibility else 'The chart may not support this Kubernetes version; try an older chart version.',
      ].join(' ');
    }
    if (mounted) setState(() => (_error = message, _hint = hint, _phase = _Phase.failed));
  }

  Future<String?> _clusterVersion() async {
    try {
      final nodes = await widget.app.api.items(const ResourceRef(resource: 'nodes'));
      return nodes.isEmpty ? null : dig<String>(nodes.first, ['status', 'nodeInfo', 'kubeletVersion']);
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _confirm(HelmResult dry) {
    final theme = Theme.of(context);
    final kinds = manifestKinds(dry.manifest);
    final total = kinds.fold<int>(0, (n, k) => n + k.$2);
    final wide = [for (final k in kinds) if (clusterWideKinds.contains(k.$1)) k];
    final ctx = widget.app.currentContext;
    final version = _version ?? 'latest';
    final r = _release;
    final warn = severityColor(context, Severity.warn);
    final clusterNote = Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: warn.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: warn.withValues(alpha: 0.35))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.public, size: 15, color: warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [
              if (a.clusterWide.isNotEmpty) 'Creates cluster-wide resources: ${a.clusterWide}.',
              if (wide.isNotEmpty) 'Rendered: ${wide.map((k) => '${k.$2} ${k.$1}').join(', ')}.',
            ].join(' '),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]),
    );
    if (r != null) {
      final stats = diffStats(diffLines(dry.currentManifest, dry.manifest));
      return confirmAction(
        context,
        title: 'Upgrade ${r.name} to ${a.chart} $version?',
        message: 'Upgrades ${r.namespace}/${r.name} from ${r.chartRef} to ${a.chart}-$version and waits up to ${addonWaitSeconds ~/ 60} minutes for it to become ready. '
            'Manifest +${stats.added} −${stats.removed} lines, validated by a dry run.',
        kubeContext: ctx,
        objectName: r.name,
        destructive: true,
        confirmLabel: 'Upgrade',
        width: 720,
        extra: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wide.any((k) => k.$1 == 'CustomResourceDefinition')) clusterNote,
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              height: 300,
              child: HelmDiffPane(oldManifest: dry.currentManifest, newManifest: dry.manifest, oldValues: _currentValues, newValues: _values.text),
            ),
          ),
        ]),
      );
    }
    return confirmAction(
      context,
      title: 'Install ${a.name}?',
      message: 'Installs ${a.chart} $version as release ${_name.text.trim()} in namespace ${_namespace.text.trim()} (created if missing): '
          '$total object${total == 1 ? '' : 's'}. k8sman waits up to ${addonWaitSeconds ~/ 60} minutes for them to become ready.',
      kubeContext: ctx,
      objectName: _name.text.trim(),
      // confirmAction itself warns prominently on non-local contexts.
      destructive: false,
      confirmLabel: 'Install',
      width: 520,
      extra: a.clusterWide.isNotEmpty || wide.isNotEmpty ? clusterNote : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 80).clamp(300.0, 760.0);
    final height = (size.height - 220).clamp(260.0, 620.0);
    final busy = _phase == _Phase.rendering || _phase == _Phase.running;
    final finished = _phase == _Phase.done;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => busy || finished ? null : _apply()},
      child: PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(finished
              ? (_upgrading ? 'Upgraded ${a.name}' : 'Installed ${a.name}')
              : _upgrading
                  ? 'Upgrade ${a.name}'
                  : 'Install ${a.name}'),
          content: SizedBox(
            width: width,
            height: height,
            child: switch (_phase) {
              _Phase.done => _Done(addon: a, result: _result!),
              _Phase.running => _Running(addon: a, upgrading: _upgrading, release: _name.text.trim(), namespace: _namespace.text.trim()),
              _ => _form(context),
            },
          ),
          actions: finished
              ? [
                  for (final l in a.links.take(1))
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context, true);
                        openAddonLink(context, l);
                      },
                      child: Text('Open ${l.label}'),
                    ),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
                ]
              : [
                  TextButton(onPressed: busy ? null : () => Navigator.pop(context, _phase == _Phase.failed ? true : null), child: Text(_phase == _Phase.failed ? 'Close' : 'Cancel')),
                  OutlinedButton(onPressed: busy ? null : _dryRun, child: Text(_phase == _Phase.rendering ? 'Rendering…' : 'Dry run')),
                  FilledButton(
                    onPressed: busy ? null : _apply,
                    child: Text(_phase == _Phase.failed ? 'Try again' : (_upgrading ? 'Upgrade…' : 'Install…')),
                  ),
                ],
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget field(String label, Widget child, {double width = 200}) => SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: hint),
            const SizedBox(height: 4),
            SizedBox(height: 28, child: child),
          ]),
        );
    final r = _release;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(a.enables, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(
        r == null ? '${a.description} Chart ${a.chart} from ${a.repo}.' : 'Currently ${r.chartRef} (${r.status}). Chart ${a.chart} from ${a.repo}.',
        style: hint,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 8, children: [
        field('Release name', TextField(key: const ValueKey('addon-release'), controller: _name, enabled: r == null, style: monoStyle(context), onChanged: (_) => setState(() {}))),
        field('Namespace', TextField(key: const ValueKey('addon-namespace'), controller: _namespace, enabled: r == null, style: monoStyle(context), onChanged: (_) => setState(() {}))),
        field('Chart version', _versionPicker(context), width: 220),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Text('Values', style: hint),
        const Spacer(),
        if (!_upgrading && _values.text != a.values)
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: () => setState(() => _values.text = a.values),
            child: const Text('Reset to defaults'),
          ),
      ]),
      const SizedBox(height: 4),
      Expanded(child: HelmYamlView(controller: _values, readOnly: _phase != _Phase.edit && _phase != _Phase.failed)),
      if (_error != null || _dry != null || _phase == _Phase.rendering)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 10),
            child: _error != null
                ? _ErrorBox(message: _error!, hint: _hint)
                : _phase == _Phase.rendering
                    ? const LinearProgressIndicator(minHeight: 2)
                    : _DryRunSummary(result: _dry!, stale: _dryKey != _inputsKey),
          ),
        ),
    ]);
  }

  Widget _versionPicker(BuildContext context) {
    final theme = Theme.of(context);
    final vs = _versions;
    final pinned = a.version;
    final installed = _release?.chartVersion;
    String label(String v) => [
          v,
          if (pinned != null && sameChartVersion(v, pinned)) 'pinned',
          if (installed != null && sameChartVersion(v, installed)) 'installed',
        ].join(' · ');
    final options = <String>[
      if (pinned != null && !(vs ?? const []).any((x) => sameChartVersion(x.version, pinned))) pinned,
      for (final v in vs ?? const <HelmChartVersion>[]) v.version,
    ];
    if (_version != null && !options.contains(_version)) options.insert(0, _version!);
    final box = BoxDecoration(color: theme.inputDecorationTheme.fillColor, borderRadius: BorderRadius.circular(6));
    if (vs == null && _versionsError == null) {
      return Container(
        decoration: box,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Expanded(child: Text(_version ?? 'latest', style: monoStyle(context))),
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        ]),
      );
    }
    return Tooltip(
      message: _versionsError ?? '${vs!.length} versions; newest first',
      child: Container(
        decoration: box,
        alignment: Alignment.centerLeft,
        child: MenuSelect<String>(
          value: _version,
          hint: Text('latest', style: monoStyle(context)),
          options: [for (final v in options.take(40)) (v, Text(label(v), style: monoStyle(context), overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _version = v),
        ),
      ),
    );
  }
}

class _DryRunSummary extends StatelessWidget {
  final HelmResult result;
  final bool stale;
  const _DryRunSummary({required this.result, required this.stale});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kinds = manifestKinds(result.manifest);
    final total = kinds.fold<int>(0, (n, k) => n + k.$2);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(stale ? Icons.history : Icons.check_circle_outline, size: 14, color: stale ? theme.hintColor : severityColor(context, Severity.ok)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            stale ? 'Dry run is out of date: inputs changed since it rendered $total objects.' : 'Dry run OK: renders $total object${total == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 4, runSpacing: 4, children: [
        for (final (k, n) in kinds) Chipish(text: '$n $k', color: clusterWideKinds.contains(k) ? severityColor(context, Severity.warn) : null),
      ]),
      if (result.notes.trim().isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Notes', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 4),
        CodeBlock(result.notes.trim(), maxLines: 8),
      ],
    ]);
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final String? hint;
  const _ErrorBox({required this.message, this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = severityColor(context, Severity.error);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SelectableText(message, style: theme.textTheme.bodySmall),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lightbulb_outline, size: 14, color: theme.hintColor),
            const SizedBox(width: 6),
            Expanded(child: Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
          ]),
        ],
      ]),
    );
  }
}

class _Running extends StatelessWidget {
  final Addon addon;
  final bool upgrading;
  final String release, namespace;
  const _Running({required this.addon, required this.upgrading, required this.release, required this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${upgrading ? 'Upgrading' : 'Installing'} $release in $namespace…', style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 10),
          Text(
            'Helm is applying the chart and waiting for its workloads to become ready (up to ${addonWaitSeconds ~/ 60} minutes). '
            'Closing k8sman doesn\'t cancel it.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ]),
      ),
    );
  }
}

class _Done extends StatelessWidget {
  final Addon addon;
  final HelmResult result;
  const _Done({required this.addon, required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_circle, size: 18, color: severityColor(context, Severity.ok)),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(result.message, style: theme.textTheme.bodyMedium)),
        ]),
        if (addon.nextSteps.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('What\'s next', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(addon.nextSteps, style: theme.textTheme.bodyMedium),
          if (addon.links.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final l in addon.links)
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                  icon: const Icon(Icons.arrow_forward, size: 14),
                  label: Text(l.label),
                  onPressed: () {
                    Navigator.pop(context, true);
                    openAddonLink(context, l);
                  },
                ),
            ]),
          ],
        ],
        if (result.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Chart notes', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          CodeBlock(result.notes.trim()),
        ],
      ]),
    );
  }
}
