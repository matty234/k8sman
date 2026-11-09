import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../../../addons/addon_status.dart' show compareChartVersions, latestStable, sameChartVersion;
import '../../../state/app_state.dart';
import '../../../util/k8s.dart';
import '../../editor/yaml_code_editor.dart';
import '../../theme.dart';
import '../../widgets/atoms.dart';
import '../../widgets/common.dart';
import '../../widgets/editorial.dart';
import '../helm_api.dart';
import 'charts_view.dart' show ChartIcon;
import 'market_actions.dart';
import 'market_api.dart';

/// One chart: what it is, where it's installed, its default values (with
/// ⌘F search), README, versions, maintainers and links, with Install and
/// "Upgrade to" through the add-on install dialog.
class HelmChartDetailView extends StatefulWidget {
  final ChartSummary chart;
  final HelmMarketApi api;
  final HelmApi helm;

  /// The cluster's releases (null while unknown), for "installed".
  final List<HelmRelease>? releases;
  final bool remoteIcons;

  /// After an install or upgrade.
  final VoidCallback? onChanged;
  const HelmChartDetailView({super.key, required this.chart, required this.api, required this.helm, this.releases, this.remoteIcons = false, this.onChanged});

  @override
  State<HelmChartDetailView> createState() => _HelmChartDetailViewState();
}

class _HelmChartDetailViewState extends State<HelmChartDetailView> {
  ChartDetail? _d;
  Object? _error;
  String? _version;
  ChartFiles? _files;
  Object? _filesError;
  int _filesSeq = 0;
  final _values = CodeLineEditingController();
  late final _find = CodeFindController(_values);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _find.dispose();
    _values.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.detail(widget.chart);
      if (!mounted) return;
      setState(() => (_d = d, _error = null, _version = d.version));
      _loadFiles();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadFiles() async {
    final d = _d;
    if (d == null) return;
    final seq = ++_filesSeq;
    setState(() => (_files = null, _filesError = null));
    try {
      final f = await widget.api.files(d, version: _version);
      if (!mounted || seq != _filesSeq) return;
      _values.text = f.values;
      setState(() => _files = f);
    } catch (e) {
      if (mounted && seq == _filesSeq) setState(() => _filesError = e);
    }
  }

  void _pickVersion(String v) {
    if (v == _version) return;
    setState(() => _version = v);
    _loadFiles();
  }

  /// Releases of a chart with this name.
  List<HelmRelease> get _installed => [for (final r in widget.releases ?? const <HelmRelease>[]) if (r.chart == widget.chart.name) r];

  Future<void> _install() async {
    final d = _d!;
    final version = _version ?? d.version;
    var values = _files?.version == version ? _files!.values : null;
    if (values == null) {
      try {
        values = (await widget.api.files(d, version: version)).values;
      } catch (_) {
        values = '';
      }
    }
    if (!mounted) return;
    if (await installChart(context, d, version: version, values: values, api: widget.helm)) widget.onChanged?.call();
  }

  Future<void> _upgrade(HelmRelease r, String version) async {
    final d = _d!;
    if (await upgradeReleaseTo(context, r, repoURL: d.repoURL, chart: d.name, version: version, api: widget.helm)) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return _error != null ? LoadFailure(_error!, title: 'Couldn\'t load ${widget.chart.name}', onRetry: _load) : const Center(child: CircularProgressIndicator());
    }
    return DefaultTabController(
      length: 4,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(context, d),
        if (_installed.isNotEmpty) _installedSection(context, d),
        const SizedBox(height: 6),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Values', height: 34),
            const Tab(text: 'README', height: 34),
            Tab(text: 'Versions  ${d.versions.length}', height: 34),
            const Tab(text: 'About', height: 34),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            _valuesTab(context),
            _readmeTab(context),
            _versionsTab(context, d),
            _aboutTab(context, d),
          ]),
        ),
      ]),
    );
  }

  Widget _header(BuildContext context, ChartDetail d) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final version = _version ?? d.version;
    final versions = [for (final v in d.versions) v.version];
    if (!versions.contains(version)) versions.insert(0, version);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: LayoutBuilder(builder: (context, box) {
        final actions = Row(mainAxisSize: MainAxisSize.min, children: [
          MenuSelect<String>(
            key: const ValueKey('chart-version'),
            value: version,
            tooltip: 'Version',
            options: [
              for (final v in versions.take(60))
                (v, Text(v == d.versions.firstOrNull?.version ? '$v · latest' : v, style: monoStyle(context, size: 11.5))),
            ],
            onChanged: _pickVersion,
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: app.readOnly ? 'This context is read-only' : 'Install ${d.name} $version: pick the namespace and edit values, then review a dry run',
            child: FilledButton.icon(
              key: const ValueKey('chart-install'),
              onPressed: app.readOnly ? null : _install,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Install…'),
            ),
          ),
        ]);
        final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(d.name, style: theme.textTheme.titleMedium),
            if (d.deprecated) const StatusBadge('deprecated', severity: Severity.warn, dense: true),
            if (d.official) const StatusBadge('official', severity: Severity.neutral, dense: true),
            if (d.verified) const StatusBadge('verified publisher', severity: Severity.neutral, dense: true),
          ]),
          const SizedBox(height: 2),
          Text(
            [
              version,
              if (d.appVersion.isNotEmpty) 'app ${d.appVersion}',
              d.source == ChartSource.artifactHub ? 'Artifact Hub · ${d.repoLabel}' : 'repository ${d.repo}',
            ].join(' · '),
            style: hint,
          ),
          if (d.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(d.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ],
        ]);
        final icon = ChartIcon(url: d.icon, name: d.name, remote: widget.remoteIcons, size: 40);
        if (box.maxWidth < 640) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [icon, const SizedBox(width: 12), Expanded(child: info)]),
            const SizedBox(height: 8),
            actions,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [icon, const SizedBox(width: 12), Expanded(child: info), const SizedBox(width: 12), actions]);
      }),
    );
  }

  Widget _installedSection(BuildContext context, ChartDetail d) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final target = _version ?? latestStable(d.versions) ?? d.version;
    final rs = _installed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: EditorialSection(
        title: 'Installed in this cluster',
        trailing: Text('${rs.length}'),
        top: 10,
        collapsible: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final r in rs)
            SizedBox(
              height: 30,
              child: Row(children: [
                SizedBox(width: 16, child: Icon(Icons.circle, size: 7, color: severityColor(context, helmStatusSeverity(r.status)))),
                Expanded(
                  child: Row(children: [
                    Flexible(child: Text('${r.namespace}/${r.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
                    const SizedBox(width: 8),
                    Text(r.chartVersion, style: monoStyle(context, size: 11.5, color: theme.hintColor)),
                    if (d.versions.isNotEmpty && !d.versions.any((v) => sameChartVersion(v.version, r.chartVersion)))
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(message: 'This version isn\'t in ${d.repoLabel}: the release may come from another source.', child: Icon(Icons.help_outline, size: 13, color: theme.hintColor)),
                      ),
                  ]),
                ),
                if (_files != null && _files!.version == target)
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => showValuesComparison(context, widget.helm, r, version: target, defaults: _files!.values),
                    child: const Text('Compare values'),
                  ),
                if (compareChartVersions(target, r.chartVersion) > 0)
                  Tooltip(
                    message: app.readOnly ? 'This context is read-only' : 'Upgrade ${r.name} from ${r.chartVersion} to $target, keeping its values',
                    child: OutlinedButton(
                      key: ValueKey('upgrade-${r.name}'),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: app.readOnly ? null : () => _upgrade(r, target),
                      child: Text('Upgrade to $target'),
                    ),
                  )
                else
                  Text(sameChartVersion(target, r.chartVersion) ? 'on this version' : 'newer than $target', style: hint),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _valuesTab(BuildContext context) {
    final f = _files;
    if (f == null) {
      return _filesError != null
          ? LoadFailure(_filesError!, title: 'Couldn\'t load the chart\'s values', onRetry: _loadFiles)
          : const Center(child: CircularProgressIndicator());
    }
    if (f.values.trim().isEmpty) return const Center(child: HintText('This chart has no default values.'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          HintText('Default values.yaml of ${f.version}'),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('values-search'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _find.findMode,
            icon: const Icon(Icons.search, size: 14),
            label: const Text('Search'),
          ),
          CopyIcon(f.values),
        ]),
        const SizedBox(height: 4),
        Expanded(child: YamlCodeEditor(controller: _values, findController: _find, readOnly: true)),
      ]),
    );
  }

  Widget _readmeTab(BuildContext context) {
    final f = _files;
    final readme = f?.readme ?? '';
    if (f == null) {
      return _filesError != null ? LoadFailure(_filesError!, title: 'Couldn\'t load the README', onRetry: _loadFiles) : const Center(child: CircularProgressIndicator());
    }
    if (readme.trim().isEmpty) return const Center(child: HintText('This chart has no README.'));
    return PageScroll(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [SelectableText(readme, style: monoStyle(context, size: 11.5))],
    );
  }

  Widget _versionsTab(BuildContext context, ChartDetail d) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    if (d.versions.isEmpty) return const Center(child: HintText('No versions listed.'));
    final installed = {for (final r in _installed) r.chartVersion};
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: d.versions.length,
      itemExtent: 28,
      itemBuilder: (context, i) {
        final v = d.versions[i];
        final selected = v.version == _version;
        return Hoverable(
          onTap: () => _pickVersion(v.version),
          builder: (h) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: selected ? colors.selection : (h ? colors.hover : null), borderRadius: BorderRadius.circular(5)),
            child: Row(children: [
              SizedBox(width: 160, child: Text(v.version, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12))),
              SizedBox(width: 140, child: Text(v.appVersion.isEmpty ? '' : 'app ${v.appVersion}', maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
              SizedBox(width: 90, child: Text(v.created == null ? '' : '${formatAge(v.created)} ago', style: hint)),
              if (v.prerelease) const StatusBadge('pre-release', severity: Severity.neutral, dense: true),
              if (v.deprecated) const StatusBadge('deprecated', severity: Severity.warn, dense: true),
              if (installed.any((x) => sameChartVersion(x, v.version))) const StatusBadge('installed', severity: Severity.ok, dense: true),
            ]),
          ),
        );
      },
    );
  }

  Widget _aboutTab(BuildContext context, ChartDetail d) {
    final theme = Theme.of(context);
    return PageScroll(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        EditorialSection(
          title: 'Chart',
          collapsible: false,
          top: 12,
          child: KeyValueTable([
            ('Repository', d.source == ChartSource.artifactHub ? '${d.repoLabel} (Artifact Hub)' : d.repo),
            ('Installs from', MonoText(d.repoURL, copy: true)),
            ('Kubernetes', d.kubeVersion),
            ('License', d.license),
            ('Keywords', d.keywords.join(', ')),
          ]),
        ),
        EditorialSection(
          title: 'Maintainers',
          trailing: Text('${d.maintainers.length}'),
          collapsible: false,
          child: d.maintainers.isEmpty
              ? const HintText('None listed.')
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final m in d.maintainers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text([m.name, if (m.email.isNotEmpty) m.email, if (m.url.isNotEmpty) m.url].join(' · '), style: theme.textTheme.bodySmall),
                    ),
                ]),
        ),
        EditorialSection(
          title: 'Links',
          trailing: Text('${d.links.length}'),
          collapsible: false,
          child: d.links.isEmpty
              ? const HintText('None listed.')
              : Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final (name, url) in d.links)
                    Tooltip(
                      message: url,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () => openUrl(url),
                        icon: const Icon(Icons.open_in_new, size: 13),
                        label: Text(name.isEmpty ? url : name),
                      ),
                    ),
                ]),
        ),
      ],
    );
  }
}
