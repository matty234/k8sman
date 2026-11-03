import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'ai_summary.dart';
import 'security_api.dart';
import 'security_widgets.dart';

/// Security overview: network exposure, permissive/unused RBAC, workload
/// hardening (Pod Security Standards), best practices and image
/// vulnerabilities, from `GET /api/security`.
class SecurityView extends StatefulWidget {
  /// Override the data source (tests). Defaults to `SecurityApi(ApiClient)`.
  final SecurityApi? source;

  /// While the Trivy Operator is still producing its first reports, the page
  /// re-checks this often.
  final Duration scanningPoll;
  const SecurityView({super.key, this.source, this.scanningPoll = const Duration(seconds: 20)});

  @override
  State<SecurityView> createState() => _SecurityViewState();
}

class _SecurityViewState extends State<SecurityView> {
  SecurityApi? _source;
  SecurityData? _data;
  ScannerStatus? _scanner;
  Object? _error;
  bool _loading = false;
  bool _includeSystem = false;
  String? _filter;
  DateTime? _updatedAt;
  int _seq = 0;
  String? _ns;
  bool _started = false;
  Timer? _poll;

  final _scanning = <String>{};
  final _scanErrors = <String, String>{};
  final _scans = <String, ScanResult>{};

  SecurityApi get source => _source ??= widget.source ?? SecurityApi(context.read<ApiClient>());

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final seq = ++_seq;
    final ns = _ns;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        source.fetch(namespace: ns, includeSystem: _includeSystem),
        source.scanner().then<ScannerStatus?>((s) => s, onError: (_) => null),
      ]);
      if (!mounted || seq != _seq) return;
      final data = results[0] as SecurityData;
      final scanner = results[1] as ScannerStatus?;
      setState(() {
        _data = data;
        _scanner = scanner ?? _scanner;
        _error = null;
        _loading = false;
        _updatedAt = DateTime.now();
        if (_filter != null && !data.categories.any((c) => c.id == _filter)) _filter = null;
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Re-check while the operator is producing its first reports.
  void _schedulePoll() {
    _poll?.cancel();
    if (_scanner?.operatorScanning == true) {
      _poll = Timer(widget.scanningPoll, () {
        if (mounted && !_loading) _refresh();
      });
    }
  }

  Future<void> _scan(String image) async {
    setState(() {
      _scanning.add(image);
      _scanErrors.remove(image);
    });
    try {
      final r = await source.scan(image, force: _scans.containsKey(image));
      if (!mounted) return;
      setState(() => _scans[image] = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanErrors[image] = 'Scan failed: ${_errorText(e)}');
    } finally {
      if (mounted) setState(() => _scanning.remove(image));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!_started || app.namespace != _ns) {
      final changed = _started;
      _started = true;
      _ns = app.namespace;
      if (changed) _data = null;
      scheduleMicrotask(() {
        if (mounted) _refresh();
      });
    }
    final header = _header(context);
    final data = _data;
    if (data == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        const Divider(),
        Expanded(
          child: Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        InlineMessage('Could not load the security overview: ${_errorText(_error!)}', isError: true),
                        const SizedBox(height: 12),
                        FilledButton.tonal(onPressed: _refresh, child: const Text('Retry')),
                      ]),
                    ),
                  ),
          ),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const Divider(),
      Expanded(
        child: Scrollbar(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: _body(context, data),
          ),
        ),
      ),
    ]);
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return PageHeader(
      title: 'Security',
      subtitle: Text(_ns ?? 'All namespaces'),
      actions: [
        if (_loading) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        if (_updatedAt != null) AgeText(_updatedAt!.toUtc().toIso8601String(), suffix: ' ago'),
        Tooltip(
          message: 'Include kube-system and Kubernetes\' default system: roles and bindings',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              setState(() => _includeSystem = !_includeSystem);
              _refresh();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  height: 18,
                  child: Transform.scale(
                    scale: 0.6,
                    child: Switch(
                      value: _includeSystem,
                      onChanged: (v) {
                        setState(() => _includeSystem = v);
                        _refresh();
                      },
                    ),
                  ),
                ),
                Text('System', style: hint),
              ]),
            ),
          ),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          icon: const Icon(Icons.auto_awesome_outlined, size: 15),
          label: const Text('Copy for AI'),
          onPressed: _data == null ? null : _copyForAgent,
        ),
        IconButton(
          tooltip: 'Refresh',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _refresh,
        ),
      ],
    );
  }

  /// Copies the visible findings (respecting the category filter) as a
  /// Markdown brief ready to paste into an AI agent.
  void _copyForAgent() {
    final data = _data;
    if (data == null) return;
    final md = securityReportForAgent(data, kubeContext: context.read<AppState>().currentContext, category: _filter);
    copyToClipboard(context, md, label: 'security summary for an AI agent (${md.split('\n').length} lines of Markdown)');
  }

  List<Widget> _body(BuildContext context, SecurityData data) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final filter = _filter;
    final findings = filter == null ? data.findings : data.findings.where((f) => f.category == filter).toList();
    bool show(String id) => filter == null || filter == id;
    final images = [for (final i in data.images) _scans[i.image] != null ? i.withScan(_scans[i.image]!) : i];
    return [
      SummaryLine(data: data),
      if (_error != null) ...[
        const SizedBox(height: 8),
        InlineMessage('Refresh failed: ${_errorText(_error!)}. Showing the last result.', isError: true),
      ],
      for (final e in data.errors.entries) ...[
        const SizedBox(height: 6),
        InlineMessage('Could not list ${e.key}: ${e.value}', icon: Icons.lock_outline),
      ],
      const SizedBox(height: 14),
      CategoryTiles(categories: data.categories, selected: filter, onSelect: (id) => setState(() => _filter = _filter == id ? null : id)),
      const SizedBox(height: 14),
      DetailSection(
        title: 'Findings',
        trailing: _findingsTrailing(context, data, findings.length),
        child: FindingList(key: ValueKey('findings-$filter'), findings: findings, categories: data.categories, grouped: filter == null, hideNamespace: _ns != null),
      ),
      if (show('network'))
        DetailSection(
          title: 'Network exposure by namespace',
          trailing: Text('${data.network.length}', style: hint),
          child: NetworkMatrix(rows: data.network),
        ),
      if (show('rbac'))
        DetailSection(
          title: 'Most permissive grants',
          trailing: Text(data.includeSystem ? 'including system' : 'excluding system defaults', style: hint),
          child: PermissiveTable(grants: data.permissive),
        ),
      if (show('images')) ...[
        DetailSection(
          title: 'Images',
          trailing: Text(_imagesSummary(images), style: hint),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ScannerSources(status: _scanner, hasOperatorData: data.trivyOperator),
            const SizedBox(height: 10),
            ImageTable(
              images: images,
              canScan: _scanner?.trivyAvailable ?? false,
              scanning: _scanning,
              scanErrors: _scanErrors,
              onScan: _scan,
            ),
          ]),
        ),
        if (data.topCves.isNotEmpty)
          DetailSection(
            title: 'Top CVEs',
            trailing: Text('critical and high, fixable first', style: hint),
            child: CveList(cves: data.topCves.take(10).toList()),
          ),
      ],
    ];
  }

  String _imagesSummary(List<ImageSummary> images) {
    final scanned = images.where((i) => i.scanned).length;
    return '$scanned of ${images.length} scanned';
  }

  Widget _findingsTrailing(BuildContext context, SecurityData data, int shown) {
    final theme = Theme.of(context);
    final filter = _filter;
    if (filter == null) return Text('${data.findings.length}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor));
    final label = data.categories.where((c) => c.id == filter).map((c) => c.title).firstOrNull ?? filter;
    return InputChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: Text('$label · $shown', style: theme.textTheme.labelSmall),
      onDeleted: () => setState(() => _filter = null),
      deleteButtonTooltipMessage: 'Show all findings',
      onPressed: () => setState(() => _filter = null),
    );
  }

  static String _errorText(Object e) => e is ApiException ? e.message : '$e';
}
