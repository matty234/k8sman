import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import 'custom_view.dart' show MetricSamplesTable;
import 'metrics_api.dart';
import 'metrics_page.dart' show ApiMissing;

/// Browse external.metrics.k8s.io: pick a metric (discovered, or referenced
/// by an HPA, since adapters like KEDA only advertise a placeholder), with an
/// optional label selector, and see its values.
class ExternalMetricsView extends StatefulWidget {
  final String? namespace;
  final MetricsApiStatus? status;
  const ExternalMetricsView({super.key, required this.namespace, this.status});

  @override
  State<ExternalMetricsView> createState() => _ExternalMetricsViewState();
}

class _ExternalMetricsViewState extends State<ExternalMetricsView> with AutomaticKeepAliveClientMixin {
  List<ExternalMetricRef>? _known;
  Object? _discoverError;
  final _metric = TextEditingController();
  final _selector = TextEditingController();
  String? _queryNamespace;
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
    _metric.dispose();
    _selector.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    try {
      final k = await _api.externalMetricNames(namespace: widget.namespace);
      if (!mounted) return;
      setState(() {
        _known = k;
        _discoverError = null;
      });
      if (k.isNotEmpty && _metric.text.isEmpty) _pick(k.first);
    } catch (e) {
      if (mounted) setState(() => _discoverError = e);
    }
  }

  void _pick(ExternalMetricRef r) {
    _metric.text = r.name;
    _selector.text = r.selector ?? '';
    _queryNamespace = r.namespace;
    _query();
  }

  String get _namespace => _queryNamespace ?? widget.namespace ?? 'default';

  Future<void> _query() async {
    final metric = _metric.text.trim();
    if (metric.isEmpty) return;
    setState(() => _loading = true);
    try {
      final v = await _api.externalMetric(namespace: _namespace, metric: metric, labelSelector: _selector.text.trim().isEmpty ? null : _selector.text.trim());
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
        what: 'external.metrics.k8s.io',
        howTo:
            'No external metrics adapter is registered. KEDA (or an adapter for your cloud provider) serves metrics from '
            'outside the cluster, such as queue lengths, for HPAs to scale on.',
      );
    }
    if (_discoverError != null) return Padding(padding: const EdgeInsets.all(16), child: InlineMessage('$_discoverError', isError: true));
    final known = _known;
    if (known == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    final app = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        if (known.isEmpty)
          Text('No external metrics are advertised or referenced by HPAs here. Enter a metric name to query it.', style: hint)
        else ...[
          Text(
            'Known metrics',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          for (final r in known)
            _KnownMetric(
              r,
              selected: r.name == _metric.text && (r.selector ?? '') == _selector.text,
              onTap: () => _pick(r),
              onHpa: () {
                final t = app.typeFor('autoscaling', 'HorizontalPodAutoscaler');
                if (t != null && r.hpa != null) app.openDetail(DetailTarget(type: t, name: r.hpa!, namespace: r.namespace));
              },
            ),
        ],
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: box.maxWidth.clamp(120.0, 300.0),
                height: 28,
                child: TextField(
                  controller: _metric,
                  style: monoStyle(context, size: 12),
                  decoration: const InputDecoration(hintText: 'metric name', prefixIcon: Icon(Icons.query_stats, size: 14)),
                  onSubmitted: (_) => _query(),
                ),
              ),
              SizedBox(
                width: box.maxWidth.clamp(120.0, 260.0),
                height: 28,
                child: TextField(
                  controller: _selector,
                  style: monoStyle(context, size: 12),
                  decoration: const InputDecoration(hintText: 'label selector (optional)', prefixIcon: Icon(Icons.filter_alt_outlined, size: 14)),
                  onSubmitted: (_) => _query(),
                ),
              ),
              TextButton(onPressed: _query, child: const Text('Query')),
              if (_loading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('Namespace $_namespace', style: hint),
        const SizedBox(height: 10),
        if (_valuesError != null) InlineMessage('$_valuesError', isError: true) else if (_values != null) MetricSamplesTable(samples: _values!, objects: false),
      ],
    );
  }
}

class _KnownMetric extends StatelessWidget {
  final ExternalMetricRef r;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHpa;
  const _KnownMetric(this.r, {required this.selected, required this.onTap, required this.onHpa});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(color: selected ? colors.selection : (h ? colors.hover : null), borderRadius: BorderRadius.circular(4)),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: r.name, style: monoStyle(context, size: 12)),
                    if (r.selector != null && r.selector!.isNotEmpty)
                      TextSpan(
                        text: '  {${r.selector}}',
                        style: monoStyle(context, size: 11, color: theme.hintColor),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (r.hpa != null) ...[
              const SizedBox(width: 8),
              Text('used by ', style: hint),
              ResourceLinkish(label: 'HPA ${r.namespace}/${r.hpa}', onTap: onHpa),
            ] else
              Text(r.source, style: hint),
          ],
        ),
      ),
    );
  }
}

/// A link that opens the inspector (rather than pushing onto it).
class ResourceLinkish extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const ResourceLinkish({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null),
      ),
    );
  }
}
