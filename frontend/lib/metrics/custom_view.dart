import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'metrics_api.dart';
import 'metrics_page.dart' show ApiMissing;
import 'sortable_table.dart';

/// Browse custom.metrics.k8s.io: pick a resource type and metric, optionally
/// a label selector, and see the value per object.
class CustomMetricsView extends StatefulWidget {
  final String? namespace;
  final MetricsApiStatus? status;
  const CustomMetricsView({super.key, required this.namespace, this.status});

  @override
  State<CustomMetricsView> createState() => _CustomMetricsViewState();
}

class _CustomMetricsViewState extends State<CustomMetricsView> with AutomaticKeepAliveClientMixin {
  List<CustomMetricResource>? _resources;
  Object? _discoverError;
  CustomMetricResource? _resource;
  String? _metric;
  final _selector = TextEditingController();
  List<MetricSample>? _values;
  Object? _valuesError;
  bool _loading = false;

  ApiClient get _api => context.read<ApiClient>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _selector.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CustomMetricsView old) {
    super.didUpdateWidget(old);
    if (old.namespace != widget.namespace && _metric != null) _query();
  }

  Future<void> _discover() async {
    try {
      final r = await _api.customMetricResources();
      if (!mounted) return;
      setState(() {
        _resources = r;
        _discoverError = null;
        // Pods first: the most common target.
        _resource = r.where((x) => x.resource == 'pods' && x.group.isEmpty).firstOrNull ?? r.firstOrNull;
        _metric = _resource?.metrics.firstOrNull;
      });
      if (_metric != null) _query();
    } catch (e) {
      if (mounted) setState(() => _discoverError = e);
    }
  }

  Future<void> _query() async {
    final res = _resource, metric = _metric;
    if (res == null || metric == null) return;
    setState(() => _loading = true);
    try {
      final v = await _api.customMetric(
        group: res.group,
        resource: res.resource,
        namespace: res.namespaced ? widget.namespace : null,
        selector: _selector.text.trim().isEmpty ? null : _selector.text.trim(),
        metric: metric,
      );
      if (!mounted) return;
      setState(() {
        _values = v;
        _valuesError = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _values = null;
          _valuesError = e;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final st = widget.status;
    if (st != null && !st.available) {
      return ApiMissing(
        status: st,
        what: 'custom.metrics.k8s.io',
        howTo:
            'No custom metrics adapter is registered. Install one such as prometheus-adapter (which reads from Prometheus) '
            'to expose per-object application metrics, e.g. pods/http_requests_per_second.',
      );
    }
    if (_discoverError != null) {
      return Padding(padding: const EdgeInsets.all(16), child: InlineMessage('$_discoverError', isError: true));
    }
    final resources = _resources;
    if (resources == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    if (resources.isEmpty) {
      return Padding(padding: const EdgeInsets.all(16), child: Text('The adapter advertises no metrics.', style: hint));
    }
    final res = _resource;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Picker<CustomMetricResource>(
                label: 'Resource',
                value: res,
                items: resources,
                text: (r) => r.key,
                onChanged: (r) {
                  setState(() {
                    _resource = r;
                    _metric = r.metrics.firstOrNull;
                    _values = null;
                  });
                  _query();
                },
              ),
              if (res != null)
                _MetricField(
                  key: ValueKey('metric-${res.key}'),
                  metrics: res.metrics,
                  initial: _metric,
                  width: (box.maxWidth - 60).clamp(120.0, 300.0),
                  onSelected: (m) {
                    setState(() => _metric = m);
                    _query();
                  },
                ),
              SizedBox(
                width: box.maxWidth.clamp(120.0, 220.0),
                height: 28,
                child: TextField(
                  controller: _selector,
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(hintText: 'label selector (optional)', prefixIcon: Icon(Icons.filter_alt_outlined, size: 14)),
                  onSubmitted: (_) => _query(),
                ),
              ),
              if (_loading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          res == null
              ? ''
              : '${res.namespaced ? (widget.namespace == null ? 'All namespaces' : 'Namespace ${widget.namespace}') : 'Cluster-scoped'} · ${res.metrics.length} metric${res.metrics.length == 1 ? '' : 's'} on ${res.key}',
          style: hint,
        ),
        const SizedBox(height: 10),
        if (_valuesError != null) InlineMessage('$_valuesError', isError: true) else if (_values != null) MetricSamplesTable(samples: _values!, objects: true),
      ],
    );
  }
}

/// Values per object (custom) or per series (external).
class MetricSamplesTable extends StatelessWidget {
  final List<MetricSample> samples;

  /// Custom metrics: one row per described object (clickable).
  final bool objects;
  const MetricSamplesTable({super.key, required this.samples, required this.objects});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    if (samples.isEmpty) return Text('No values', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    Widget mono(String s, {Color? color}) => Text(
      s,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(context, size: 11.5, color: color),
    );
    String labels(MetricSample s) => s.labels.entries.map((e) => '${e.key}=${e.value}').join(', ');
    return SortableTable<MetricSample>(
      rows: samples,
      initialSort: objects ? 0 : 1,
      onTap: objects
          ? (s) {
              final o = s.object;
              final t = o == null ? null : app.typeFor(o.group, o.kind);
              if (o != null && t != null) app.openDetail(DetailTarget(type: t, name: o.name, namespace: t.namespaced ? o.namespace : null));
            }
          : null,
      selected: objects ? (s) => app.detail?.name == s.object?.name && app.detail?.type.kind == s.object?.kind : null,
      columns: [
        if (objects)
          MetricColumn(
            label: 'Object',
            sortKey: (s) => '${s.object?.namespace ?? ''}/${s.object?.name ?? ''}',
            cell: (c, s) => Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${s.object?.kind ?? ''} ',
                    style: TextStyle(color: theme.hintColor),
                  ),
                  if (s.object?.namespace != null)
                    TextSpan(
                      text: '${s.object!.namespace}/',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  TextSpan(text: s.object?.name ?? ''),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          MetricColumn(
            label: 'Series',
            sortKey: labels,
            cell: (c, s) => Text(
              s.labels.isEmpty ? s.metric : labels(s),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 11, color: theme.hintColor),
            ),
          ),
        MetricColumn(label: 'Value', width: 110, numeric: true, sortKey: (s) => s.number, cell: (c, s) => mono(s.value)),
        MetricColumn(
          label: 'Number',
          width: 90,
          numeric: true,
          hideBelow: 520,
          sortKey: (s) => s.number,
          cell: (c, s) => mono(_num(s.number), color: theme.hintColor),
        ),
        MetricColumn(
          label: 'Window',
          width: 70,
          numeric: true,
          hideBelow: 440,
          sortKey: (s) => s.windowSeconds,
          cell: (c, s) => mono(s.windowSeconds == null ? '—' : '${s.windowSeconds}s', color: theme.hintColor),
        ),
        MetricColumn(
          label: 'Age',
          width: 60,
          numeric: true,
          hideBelow: 380,
          sortKey: (s) => s.timestamp,
          cell: (c, s) => mono(formatAge(parseTime(s.timestamp)), color: theme.hintColor),
        ),
      ],
    );
  }

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(v.abs() < 10 ? 3 : 1);
}

/// A compact dropdown with a leading label.
class _Picker<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<T> items;
  final String Function(T) text;
  final ValueChanged<T> onChanged;
  const _Picker({super.key, required this.label, required this.value, required this.items, required this.text, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            isExpanded: false,
            underline: const SizedBox(),
            style: monoStyle(context, size: 12),
            items: [
              for (final i in items)
                DropdownMenuItem(
                  value: i,
                  child: Text(text(i), overflow: TextOverflow.ellipsis),
                ),
            ],
            selectedItemBuilder: (_) => [
              for (final i in items)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(text(i), overflow: TextOverflow.ellipsis, maxLines: 1),
                ),
            ],
            onChanged: (v) => v == null ? null : onChanged(v),
          ),
        ),
      ],
    );
  }
}

/// Type-to-search metric picker (adapters often expose thousands of metrics).
class _MetricField extends StatelessWidget {
  final List<String> metrics;
  final String? initial;
  final ValueChanged<String> onSelected;
  final double width;
  const _MetricField({super.key, required this.metrics, this.initial, required this.onSelected, this.width = 300});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Metric ', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        SizedBox(
          width: width,
          height: 28,
          child: Autocomplete<String>(
            initialValue: TextEditingValue(text: initial ?? ''),
            optionsBuilder: (v) {
              final q = v.text.trim().toLowerCase();
              return metrics.where((m) => q.isEmpty || m.toLowerCase().contains(q)).take(80);
            },
            onSelected: onSelected,
            fieldViewBuilder: (context, controller, focus, submit) => TextField(
              controller: controller,
              focusNode: focus,
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(hintText: '${metrics.length} metrics', prefixIcon: const Icon(Icons.search, size: 14)),
              onSubmitted: (v) {
                if (metrics.contains(v.trim())) onSelected(v.trim());
              },
            ),
            optionsViewBuilder: (context, select, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420, maxHeight: 280),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    children: [
                      for (final o in options)
                        InkWell(
                          onTap: () => select(o),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            child: Text(o, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
