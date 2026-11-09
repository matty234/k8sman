import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/client.dart';
import '../../../util/k8s.dart' show Severity;
import '../../widgets/atoms.dart';
import '../../widgets/common.dart';
import '../../widgets/editorial.dart';
import '../../theme.dart';
import '../helm_api.dart';
import 'chart_detail.dart';
import 'market_api.dart';

/// The charts browser: the charts in the user's repositories (from their
/// cached indexes) or, once enabled, Artifact Hub search. Opening a chart
/// shows its detail in place.
class HelmChartsView extends StatefulWidget {
  /// The Releases / Charts / Repositories switch, compact when narrow.
  final Widget Function(bool compact)? modeSwitch;
  final HelmMarketApi? api;
  final HelmApi? helm;

  /// Opens the repositories view (from the empty state).
  final VoidCallback? onShowRepos;
  const HelmChartsView({super.key, this.modeSwitch, this.api, this.helm, this.onShowRepos});

  @override
  State<HelmChartsView> createState() => _HelmChartsViewState();
}

class _HelmChartsViewState extends State<HelmChartsView> {
  late final HelmMarketApi _api = widget.api ?? HelmMarketApi.of(context);
  late final HelmApi _helm = widget.helm ?? _providedHelm() ?? HelmApi(context.read<ApiClient>());

  HelmApi? _providedHelm() {
    try {
      return Provider.of<HelmApi>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  // Remembered across visits to the page.
  static ChartSource _lastSource = ChartSource.repo;
  late ChartSource _source = _lastSource;
  String _query = '';
  String? _repo; // null = all repositories
  bool _showDeprecated = false;

  RepoChartList? _local;
  Object? _localError;

  bool? _hubEnabled;
  HubSearch? _hub;
  Object? _hubError;
  bool _hubLoading = false;
  int _hubSeq = 0;
  Timer? _debounce;

  bool _remoteIcons = false;
  List<HelmRelease>? _releases;
  ChartSummary? _open;

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _loadHubSetting();
    _helm.releases().then((l) => mounted ? setState(() => _releases = l.releases) : null, onError: (Object _) => null);
    context.read<ApiClient>().getIconSettings().then((s) => mounted ? setState(() => _remoteIcons = s.effective) : null, onError: (Object _) => null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    try {
      final l = await _api.repoCharts();
      if (mounted) setState(() => (_local = l, _localError = null));
    } catch (e) {
      if (mounted) setState(() => _localError = e);
    }
  }

  Future<void> _loadHubSetting() async {
    try {
      final on = await _api.artifactHubEnabled();
      if (!mounted) return;
      setState(() => _hubEnabled = on);
      if (on && _source == ChartSource.artifactHub) _searchHub();
    } catch (_) {
      if (mounted) setState(() => _hubEnabled = false);
    }
  }

  Future<void> _enableHub() async {
    try {
      final on = await _api.setArtifactHub(true);
      if (!mounted) return;
      setState(() => _hubEnabled = on);
      if (on) _searchHub();
    } on ApiException catch (e) {
      if (mounted) setState(() => _hubError = e);
    }
  }

  Future<void> _searchHub({bool more = false}) async {
    final seq = ++_hubSeq;
    setState(() => (_hubLoading = true, _hubError = null));
    try {
      final prev = more ? _hub : null;
      final res = await _api.searchHub(_query, offset: prev?.packages.length ?? 0);
      if (!mounted || seq != _hubSeq) return;
      setState(() {
        _hub = prev == null ? res : HubSearch([...prev.packages, ...res.packages], res.total);
        _hubLoading = false;
      });
    } catch (e) {
      if (mounted && seq == _hubSeq) setState(() => (_hubError = e, _hubLoading = false));
    }
  }

  void _onQuery(String v) {
    setState(() => _query = v.trim());
    if (_source == ChartSource.artifactHub && _hubEnabled == true) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _searchHub);
    }
  }

  void _setSource(ChartSource s) {
    setState(() => _source = _lastSource = s);
    if (s == ChartSource.artifactHub && _hubEnabled == true && _hub == null) _searchHub();
  }

  bool _matches(ChartSummary c) {
    if (_repo != null && c.repo != _repo) return false;
    if (c.deprecated && !_showDeprecated) return false;
    final q = _query.toLowerCase();
    return q.isEmpty ||
        c.name.toLowerCase().contains(q) ||
        c.description.toLowerCase().contains(q) ||
        c.repo.toLowerCase().contains(q) ||
        c.keywords.any((k) => k.toLowerCase().contains(q));
  }

  Set<String> get _installed => {for (final r in _releases ?? const <HelmRelease>[]) r.chart};

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return LayoutBuilder(
        builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(
            leading: IconButton(tooltip: 'Back to charts', iconSize: 18, icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _open = null)),
            title: open.name,
            afterTitle: widget.modeSwitch?.call(box.maxWidth < 760),
          ),
          const Divider(),
          Expanded(
            child: HelmChartDetailView(
              key: ValueKey(open.key),
              chart: open,
              api: _api,
              helm: _helm,
              releases: _releases,
              remoteIcons: open.source == ChartSource.artifactHub || _remoteIcons,
              onChanged: () => _helm.releases().then((l) => mounted ? setState(() => _releases = l.releases) : null, onError: (Object _) => null),
            ),
          ),
        ]),
      );
    }
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      final local = _local;
      final hubOn = _hubEnabled == true;
      final subtitle = _source == ChartSource.repo
          ? (local == null ? null : '${local.charts.length} charts in your repositories')
          : (_hub == null ? null : '${_hub!.total} on Artifact Hub');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Helm',
          afterTitle: widget.modeSwitch?.call(box.maxWidth < 760),
          subtitle: subtitle == null ? null : Text(subtitle),
          actions: [
            SizedBox(
              width: (box.maxWidth * 0.28).clamp(110.0, 240.0),
              height: 26,
              child: TextField(
                key: const ValueKey('chart-search'),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 15), hintText: _source == ChartSource.repo ? 'Filter charts' : 'Search Artifact Hub'),
                style: theme.textTheme.bodyMedium,
                onChanged: _onQuery,
              ),
            ),
          ],
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              height: 24,
              child: SegmentedButton<ChartSource>(
                key: const ValueKey('chart-source'),
                style: ButtonStyle(
                  visualDensity: const VisualDensity(horizontal: -3, vertical: -4),
                  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
                  minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
                  textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ChartSource.repo, label: Text('My repositories')),
                  ButtonSegment(value: ChartSource.artifactHub, label: Text('Artifact Hub')),
                ],
                selected: {_source},
                onSelectionChanged: (s) => _setSource(s.first),
              ),
            ),
            if (_source == ChartSource.repo && local != null && local.charts.isNotEmpty) ...[
              MenuSelect<String>(
                key: const ValueKey('chart-repo-filter'),
                value: _repo ?? '',
                options: [
                  ('', Text('All repositories', style: theme.textTheme.bodySmall)),
                  for (final r in {for (final c in local.charts) c.repo}.toList()..sort()) (r, Text(r, style: theme.textTheme.bodySmall)),
                ],
                onChanged: (v) => setState(() => _repo = v.isEmpty ? null : v),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 24, child: Checkbox(value: _showDeprecated, onChanged: (v) => setState(() => _showDeprecated = v == true))),
                const SizedBox(width: 4),
                HintText('Deprecated'),
              ]),
            ],
          ]),
        ),
        Expanded(child: _source == ChartSource.repo ? _localBody(context) : (hubOn ? _hubBody(context) : _hubOptIn(context))),
      ]);
    });
  }

  Widget _localBody(BuildContext context) {
    final l = _local;
    if (l == null) {
      return _localError == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_localError!, title: 'Couldn\'t read your Helm repositories', onRetry: _loadLocal);
    }
    final notes = <Widget>[
      if (l.notCached.isNotEmpty)
        HintText('${l.notCached.length == 1 ? '${l.notCached.first} has' : '${l.notCached.length} repositories have'} no downloaded index yet: update ${l.notCached.length == 1 ? 'it' : 'them'} under Repositories.'),
      for (final e in l.errors.entries) ErrorNotice(e.value, title: 'Couldn\'t read the index of ${e.key}', severity: Severity.warn),
    ];
    if (l.charts.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.inventory_2_outlined, size: 36, color: Theme.of(context).hintColor),
          const SizedBox(height: 8),
          Text('No charts yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const HintText('Add a Helm repository (or update one) to browse its charts here, or search Artifact Hub.'),
          ...notes,
          if (widget.onShowRepos != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(onPressed: widget.onShowRepos, child: const Text('Repositories…')),
          ],
        ]),
      );
    }
    final visible = l.charts.where(_matches).toList();
    return _ChartList(
      charts: visible,
      title: _repo ?? 'All repositories',
      header: notes,
      emptyText: 'No charts match "$_query"',
      installed: _installed,
      remoteIcons: _remoteIcons,
      onOpen: (c) => setState(() => _open = c),
    );
  }

  Widget _hubOptIn(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Searching Artifact Hub sends your search terms to artifacthub.io.', style: theme.textTheme.bodyMedium),
          FilledButton.tonal(key: const ValueKey('enable-artifacthub'), onPressed: _hubEnabled == null ? null : _enableHub, child: const Text('Enable')),
          if (_hubError != null) ErrorNotice(_hubError!, title: 'Couldn\'t save the setting'),
        ]),
      ),
    );
  }

  Widget _hubBody(BuildContext context) {
    final h = _hub;
    if (h == null) {
      return _hubError != null ? LoadFailure(_hubError!, title: 'Artifact Hub search failed', onRetry: _searchHub) : const Center(child: CircularProgressIndicator());
    }
    return _ChartList(
      charts: h.packages.where((c) => _showDeprecated || !c.deprecated).toList(),
      title: _query.isEmpty ? 'Most starred' : 'Results for "$_query"',
      header: [if (_hubError != null) ErrorNotice(_hubError!, title: 'Search failed', note: 'Showing the last result.', onRetry: _searchHub)],
      emptyText: 'Nothing on Artifact Hub matches "$_query"',
      installed: _installed,
      remoteIcons: true,
      onOpen: (c) => setState(() => _open = c),
      footer: h.packages.length < h.total
          ? Center(
              child: TextButton(
                onPressed: _hubLoading ? null : () => _searchHub(more: true),
                child: Text(_hubLoading ? 'Loading…' : 'Load more (${h.total - h.packages.length} left)'),
              ),
            )
          : null,
    );
  }
}

/// A lazy list of chart rows under a section header.
class _ChartList extends StatelessWidget {
  final List<ChartSummary> charts;
  final String title, emptyText;
  final List<Widget> header;
  final Widget? footer;
  final Set<String> installed;
  final bool remoteIcons;
  final ValueChanged<ChartSummary> onOpen;
  const _ChartList({
    required this.charts,
    required this.title,
    required this.emptyText,
    required this.installed,
    required this.remoteIcons,
    required this.onOpen,
    this.header = const [],
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final extra = footer == null ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: 1 + (charts.isEmpty ? 1 : charts.length) + extra,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final h in header) Padding(padding: const EdgeInsets.only(top: 8), child: h),
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 4),
              child: SectionHeader(title: title, trailing: Text('${charts.length}')),
            ),
          ]);
        }
        if (charts.isEmpty && i == 1) {
          return Padding(padding: const EdgeInsets.all(24), child: Center(child: HintText(emptyText)));
        }
        if (i > charts.length) return footer!;
        final c = charts[i - 1];
        return _ChartRow(chart: c, installed: installed.contains(c.name), remoteIcons: remoteIcons, onTap: () => onOpen(c));
      },
    );
  }
}

class _ChartRow extends StatelessWidget {
  final ChartSummary chart;
  final bool installed, remoteIcons;
  final VoidCallback onTap;
  const _ChartRow({required this.chart, required this.installed, required this.remoteIcons, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final c = chart;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        key: ValueKey('chart-${c.repo}-${c.name}'),
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: h ? colors.hover : null,
          borderRadius: BorderRadius.circular(5),
          border: Border(bottom: BorderSide(color: colors.separator.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          ChartIcon(url: c.icon, name: c.name, remote: remoteIcons),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                const SizedBox(width: 8),
                Text(c.version, style: monoStyle(context, size: 11, color: theme.hintColor)),
                if (c.appVersion.isNotEmpty) ...[const SizedBox(width: 6), Text('app ${c.appVersion}', maxLines: 1, style: hint)],
                if (installed) ...[const SizedBox(width: 8), const StatusBadge('installed', severity: Severity.ok, dense: true)],
                if (c.deprecated) ...[const SizedBox(width: 8), const StatusBadge('deprecated', severity: Severity.warn, dense: true)],
              ]),
              const SizedBox(height: 2),
              Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
            ]),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (c.verified || c.official)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Tooltip(message: c.official ? 'Official' : 'Verified publisher', child: Icon(Icons.verified_outlined, size: 13, color: theme.hintColor)),
                ),
              if (c.stars > 0) ...[Icon(Icons.star_border, size: 13, color: theme.hintColor), Text(' ${c.stars}  ', style: hint)],
              Flexible(child: Text(c.repoDisplay.isNotEmpty ? c.repoDisplay : c.repo, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A chart's icon, or a monogram when remote images aren't allowed (or the
/// image fails, e.g. SVG).
class ChartIcon extends StatelessWidget {
  final String url, name;
  final bool remote;
  final double size;
  const ChartIcon({super.key, required this.url, required this.name, this.remote = false, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(size / 4)),
      child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor, fontSize: size * 0.45)),
    );
    final u = Uri.tryParse(url);
    if (!remote || u == null || u.scheme != 'https' || u.path.toLowerCase().endsWith('.svg')) return mono;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 4),
      child: Image.network(url, width: size, height: size, fit: BoxFit.contain, headers: const {'User-Agent': 'k8sman'}, errorBuilder: (_, _, _) => mono),
    );
  }
}
