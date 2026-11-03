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
import 'release_detail.dart';

/// Helm releases: a dense list (problems first) with the selected release's
/// detail beside it on wide windows, or below it on narrow ones.
class HelmView extends StatefulWidget {
  /// Injected in tests; defaults to a [HelmApi] on the app's [ApiClient].
  final HelmApi? api;
  const HelmView({super.key, this.api});

  @override
  State<HelmView> createState() => _HelmViewState();
}

class _HelmViewState extends State<HelmView> {
  late final HelmApi _api = widget.api ?? _provided() ?? HelmApi(context.read<ApiClient>());

  /// A [HelmApi] from an ancestor Provider (used to inject fakes in app-level tests).
  HelmApi? _provided() {
    try {
      return Provider.of<HelmApi>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }
  HelmReleaseList? _list;
  String? _error;
  String _filter = '';
  String? _selected; // namespace/name
  String? _loadedNs;
  bool _loadedOnce = false;
  Timer? _poll;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final ns = context.read<AppState>().namespace;
    final seq = ++_seq;
    try {
      final l = await _api.releases(namespace: ns);
      if (!mounted || seq != _seq) return;
      setState(() {
        _list = l;
        _error = null;
        _loadedNs = ns;
      });
    } on ApiException catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e.message);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = '$e');
    }
  }

  bool _matches(HelmRelease r) {
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
      _loadedNs = app.namespace;
      scheduleMicrotask(_refresh);
    }
    // A release to focus (from Add-ons → View release).
    if (app.helmFocus != null) {
      _selected = app.helmFocus;
      app.helmFocus = null;
    }
    final l = _list;
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
        if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: InlineMessage(_error!, isError: true)),
        Expanded(
          child: visible == null
              ? Center(child: _error == null ? const CircularProgressIndicator() : const SizedBox.shrink())
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
                        emptyText: 'No releases match "$_filter"',
                      ),
                      detail: selected == null
                          ? Center(child: Text('Select a release', style: TextStyle(color: theme.hintColor)))
                          : HelmReleaseDetailPane(key: ValueKey(selected.key), api: _api, release: selected, onChanged: _refresh),
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
  const _ReleaseTable({required this.releases, required this.showNamespace, required this.selected, required this.onSelect, required this.emptyText});

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
  const _ReleaseRow({required this.r, required this.cols, required this.layout, required this.striped, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final small = theme.textTheme.bodySmall;
    final dim = small?.copyWith(color: theme.hintColor);
    Widget cell(_Col c) => switch (c) {
          _Col.name => Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
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
