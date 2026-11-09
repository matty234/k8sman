import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/namespace_picker.dart';
import 'helm_api.dart';
import 'market/market_actions.dart';
import 'market/market_api.dart';
import 'release_detail.dart';
import '../../state/poller.dart';

/// Helm releases: a dense list (problems first) with the selected release's
/// detail beside it on wide windows, or below it on narrow ones.
class HelmView extends StatefulWidget {
  /// Injected in tests; defaults to a [HelmApi] on the app's [ApiClient].
  final HelmApi? api;

  /// Looks up newer chart versions; defaults to one on the app's
  /// [ApiClient] (none when [api] is injected without it, as in tests).
  final HelmMarketApi? market;

  /// The Releases / Charts / Repositories switch (see HelmPage).
  final Widget Function(bool compact)? modeSwitch;
  const HelmView({super.key, this.api, this.market, this.modeSwitch});

  @override
  State<HelmView> createState() => _HelmViewState();
}

class _HelmViewState extends State<HelmView> with PollingState {
  late final HelmApi _api = widget.api ?? _provided() ?? HelmApi(context.read<ApiClient>());

  /// A [HelmApi] from an ancestor Provider (used to inject fakes in app-level tests).
  HelmApi? _provided() {
    try {
      return Provider.of<HelmApi>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }
  late final HelmMarketApi? _market = widget.market ?? _providedMarket() ?? (widget.api == null && _provided() == null ? HelmMarketApi(context.read<ApiClient>()) : null);

  HelmMarketApi? _providedMarket() {
    try {
      return Provider.of<HelmMarketApi>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  HelmReleaseList? _list;

  /// The namespace [_list] was listed for: another namespace's list (maybe
  /// empty) isn't shown while this one loads.
  String? _listNs;
  Object? _error;

  /// Newer chart versions by [chartUpdateKey], kept across visits and
  /// refreshed at most every [_updatesTTL]; never blocks the list.
  static Map<String, ChartUpdate> _updates = const {};
  static String _updatesFor = '';
  static DateTime? _updatesAt;
  static const _updatesTTL = Duration(minutes: 10);
  bool _checkingUpdates = false;
  String _filter = '';
  String? _selected; // namespace/name
  String? _loadedNs;
  bool _loadedOnce = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    poll(const Duration(seconds: 10), () async {
      await _refresh();
      return _error == null;
    });
  }

  Future<void> _refresh() async {
    final ns = context.read<AppState>().namespace;
    final seq = ++_seq;
    try {
      final l = await _api.releases(namespace: ns);
      if (!mounted || seq != _seq) return;
      setState(() {
        _list = l;
        _listNs = ns;
        _error = null;
        _loadedNs = ns;
      });
      _checkUpdates(l.releases);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  Future<void> _checkUpdates(List<HelmRelease> releases, {bool force = false}) async {
    final market = _market;
    if (market == null || _checkingUpdates) return;
    final keys = ({for (final r in releases) chartUpdateKey(r)}.toList()..sort()).join(',');
    final fresh = _updatesAt != null && DateTime.now().difference(_updatesAt!) < _updatesTTL;
    if (!force && fresh && keys == _updatesFor) return;
    _checkingUpdates = true;
    try {
      final u = await market.updates(releases);
      _updates = u;
      _updatesFor = keys;
      _updatesAt = DateTime.now();
      if (mounted) setState(() {});
    } catch (_) {
      // Quiet: the badges are a hint, not part of the list.
    } finally {
      _checkingUpdates = false;
    }
  }

  Future<void> _upgrade(HelmRelease r, ChartUpdate u) async {
    if (await upgradeReleaseTo(context, r, repoURL: u.repoURL, chart: u.chart, version: u.latest, api: _api)) {
      await _refresh();
      final l = _list;
      if (l != null) _checkUpdates(l.releases, force: true);
    }
  }

  ChartUpdate? _updateOf(HelmRelease r) => _updates[chartUpdateKey(r)];

  bool _matches(HelmRelease r) {
    // A namespace set is listed across all namespaces and narrowed here.
    if (!context.read<AppState>().namespaceScope.contains(r.namespace)) return false;
    final q = _filter.toLowerCase();
    return q.isEmpty ||
        r.name.toLowerCase().contains(q) ||
        r.namespace.toLowerCase().contains(q) ||
        r.chart.toLowerCase().contains(q) ||
        r.status.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    // Follow the global namespace filter.
    if (!_loadedOnce || _loadedNs != app.namespace) {
      _loadedOnce = true;
      _loadedNs = app.namespace; // null for all namespaces and for a set
      scheduleMicrotask(_refresh);
    }
    // A release to focus (from Add-ons → View release).
    if (app.pageFocus != null) {
      _selected = app.pageFocus;
      app.pageFocus = null;
    }
    final l = _list != null && _listNs == app.namespace ? _list : null;
    final all = l == null ? null : sortReleases(l.releases);
    final visible = all?.where(_matches).toList();
    HelmRelease? selected;
    if (visible != null && visible.isNotEmpty) {
      selected = visible.firstWhere((r) => r.key == _selected, orElse: () => visible.first);
    }

    final page = LayoutBuilder(builder: (context, box) {
      final filterWidth = (box.maxWidth * 0.28).clamp(110.0, 200.0);
      final nsWidth = (box.maxWidth * 0.2).clamp(100.0, 180.0);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Helm',
          afterTitle: widget.modeSwitch?.call(box.maxWidth < 760),
          subtitle: l == null ? null : _Subtitle(l),
          actions: [
            IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _refresh),
            if (box.maxWidth >= 520) SizedBox(width: nsWidth, child: const NamespacePicker()),
            SizedBox(
              width: filterWidth,
              height: 26,
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Filter releases'),
                style: theme.textTheme.bodyMedium,
                onChanged: (v) => setState(() => _filter = v.trim()),
              ),
            ),
          ],
        ),
        const Divider(),
        if (_error != null && visible != null)
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: ErrorNotice(_error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: _refresh)),
        Expanded(
          child: visible == null
              ? (_error == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_error!, onRetry: _refresh))
              : all!.isEmpty
                  ? _Empty(namespace: app.namespace)
                  : _MasterDetail(
                      wide: box.maxWidth >= 1000,
                      rows: visible.length,
                      list: _ReleaseTable(
                        releases: visible,
                        showNamespace: app.namespace == null,
                        selected: selected?.key,
                        onSelect: (r) => setState(() => _selected = r.key),
                        updateOf: _updateOf,
                        onUpgrade: app.readOnly ? null : _upgrade,
                        emptyText: 'No releases match "$_filter"',
                      ),
                      detail: selected == null
                          ? Center(child: Text('Select a release', style: TextStyle(color: theme.hintColor)))
                          : HelmReleaseDetailPane(
                              key: ValueKey(selected.key),
                              api: _api,
                              release: selected,
                              onChanged: _refresh,
                              badge: _updateOf(selected) == null
                                  ? null
                                  : UpdateBadge(_updateOf(selected)!, onTap: app.readOnly ? null : () => _upgrade(selected!, _updateOf(selected)!)),
                            ),
                    ),
        ),
      ]);
    });
    // Below this the page scrolls sideways instead of squeezing (e.g. a
    // 700px window with the inspector open leaves ~150px for the main area).
    const minWidth = 360.0;
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= minWidth
          ? page
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: minWidth, height: box.maxHeight, child: page),
            ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  final HelmReleaseList l;
  const _Subtitle(this.l);

  @override
  Widget build(BuildContext context) {
    final n = l.releases.length;
    return Text([
      '$n release${n == 1 ? '' : 's'}',
      if (l.failed > 0) '${l.failed} failed',
      if (l.pending > 0) '${l.pending} pending',
    ].join(' · '));
  }
}

class _Empty extends StatelessWidget {
  final String? namespace;
  const _Empty({this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.sailing_outlined, size: 40, color: theme.hintColor),
        const SizedBox(height: 8),
        Text('No Helm releases', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(namespace == null ? 'Nothing installed with Helm in this cluster.' : 'Nothing installed with Helm in $namespace.',
            style: TextStyle(color: theme.hintColor)),
      ]),
    );
  }
}

class _MasterDetail extends StatelessWidget {
  final bool wide;

  /// Visible rows, so the stacked list is no taller than its content.
  final int rows;
  final Widget list;
  final Widget detail;
  const _MasterDetail({required this.wide, required this.rows, required this.list, required this.detail});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return LayoutBuilder(builder: (context, box) {
      if (wide) {
        final w = (box.maxWidth * 0.46).clamp(420.0, 660.0);
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: w, child: list),
          Container(width: 1, color: colors.separator),
          Expanded(child: detail),
        ]);
      }
      final cap = (box.maxHeight * 0.36).clamp(120.0, 300.0);
      final h = (28.0 + rows * 28 + 10).clamp(96.0, cap);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: h, child: list),
        Container(height: 1, color: colors.separator),
        Expanded(child: detail),
      ]);
    });
  }
}

// ---------------------------------------------------------------------------
// Release table
// ---------------------------------------------------------------------------

enum _Col { name, namespace, chart, app, rev, status, updated }

class _ReleaseTable extends StatefulWidget {
  final List<HelmRelease> releases;
  final bool showNamespace;
  final String? selected;
  final ValueChanged<HelmRelease> onSelect;
  final String emptyText;
  final ChartUpdate? Function(HelmRelease) updateOf;
  final void Function(HelmRelease, ChartUpdate)? onUpgrade;
  const _ReleaseTable({
    required this.releases,
    required this.showNamespace,
    required this.selected,
    required this.onSelect,
    required this.emptyText,
    required this.updateOf,
    this.onUpgrade,
  });

  @override
  State<_ReleaseTable> createState() => _ReleaseTableState();
}

class _ReleaseTableState extends State<_ReleaseTable> {
  final _focus = FocusNode(debugLabel: 'helm releases');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final rs = widget.releases;
    if (rs.isEmpty) return;
    final i = rs.indexWhere((r) => r.key == widget.selected);
    widget.onSelect(rs[(i + delta).clamp(0, rs.length - 1)]);
  }

  /// Visible columns and their widths for [w] px. Name takes the slack.
  static Map<_Col, double> _layout(double w, bool showNamespace) {
    final cols = <_Col, double>{_Col.status: 128, _Col.updated: 66};
    if (w >= 380) cols[_Col.rev] = 34;
    if (w >= 500) cols[_Col.chart] = 140;
    if (showNamespace && w >= 600) cols[_Col.namespace] = 100;
    if (w >= 760) cols[_Col.app] = 72;
    final fixed = cols.values.fold<double>(0, (a, b) => a + b) + 24;
    final name = (w - fixed).clamp(80.0, 400.0);
    return {_Col.name: name, ...cols};
  }

  static const _order = [_Col.name, _Col.namespace, _Col.chart, _Col.app, _Col.rev, _Col.status, _Col.updated];
  static const _labels = {
    _Col.name: 'Name',
    _Col.namespace: 'Namespace',
    _Col.chart: 'Chart',
    _Col.app: 'App',
    _Col.rev: 'Rev',
    _Col.status: 'Status',
    _Col.updated: 'Updated',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      final layout = _layout(box.maxWidth, widget.showNamespace);
      final cols = [for (final c in _order) if (layout.containsKey(c)) c];
      final header = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
      return Focus(
        focusNode: _focus,
        onKeyEvent: (node, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
          if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
            _move(1);
            return KeyEventResult.handled;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
            _move(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 28,
            child: Row(children: [
              const SizedBox(width: 12),
              for (final c in cols)
                SizedBox(
                  width: layout[c],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(_labels[c]!, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: c == _Col.rev ? TextAlign.right : null, style: header),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: widget.releases.isEmpty
                ? Center(child: Text(widget.emptyText, style: TextStyle(color: theme.hintColor)))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: widget.releases.length,
                    itemExtent: 28,
                    itemBuilder: (context, i) {
                      final r = widget.releases[i];
                      return _ReleaseRow(
                        r: r,
                        cols: cols,
                        layout: layout,
                        striped: i.isOdd,
                        selected: r.key == widget.selected,
                        update: widget.updateOf(r),
                        onUpgrade: widget.onUpgrade == null ? null : (u) => widget.onUpgrade!(r, u),
                        onTap: () {
                          _focus.requestFocus();
                          widget.onSelect(r);
                        },
                      );
                    },
                  ),
          ),
        ]),
      );
    });
  }
}

class _ReleaseRow extends StatelessWidget {
  final HelmRelease r;
  final List<_Col> cols;
  final Map<_Col, double> layout;
  final bool striped, selected;
  final VoidCallback onTap;
  final ChartUpdate? update;
  final ValueChanged<ChartUpdate>? onUpgrade;
  const _ReleaseRow({required this.r, required this.cols, required this.layout, required this.striped, required this.selected, required this.onTap, this.update, this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final small = theme.textTheme.bodySmall;
    final dim = small?.copyWith(color: theme.hintColor);
    Widget cell(_Col c) => switch (c) {
          _Col.name => Row(children: [
              Flexible(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
              if (update != null) ...[
                const SizedBox(width: 6),
                UpdateBadge(update!, compact: true, onTap: onUpgrade == null ? null : () => onUpgrade!(update!)),
              ],
            ]),
          _Col.namespace => Text(r.namespace, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          _Col.chart => Text(r.chartRef, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          _Col.app => Text(r.appVersion, maxLines: 1, overflow: TextOverflow.ellipsis, style: dim),
          _Col.rev => Text('${r.revision}', textAlign: TextAlign.right, style: small?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          _Col.status => StatusBadge(r.status, severity: helmStatusSeverity(r.status), dense: true),
          _Col.updated => Text(r.updated == null ? '' : formatAge(r.updated), maxLines: 1, style: dim),
        };
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: onTap,
      builder: (hovered) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(
          color: selected
              ? colors.selection
              : hovered
                  ? colors.hover
                  : striped
                      ? colors.stripe
                      : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          for (final c in cols)
            SizedBox(
              width: layout[c],
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Align(alignment: c == _Col.rev ? Alignment.centerRight : Alignment.centerLeft, child: cell(c))),
            ),
        ]),
      ),
    );
  }
}
