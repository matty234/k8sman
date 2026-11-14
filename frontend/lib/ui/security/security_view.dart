import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../access/access_view.dart';
import '../terminal/claude_prompts.dart';
import '../terminal/open_terminal.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show PageScroll;
import 'ai_summary.dart';
import 'ignore_ui.dart';
import 'security_api.dart';
import 'security_widgets.dart';
import '../widgets/namespace_picker.dart';
import '../widgets/partial_banner.dart';

/// A request to open the Security page on one workload (its namespace,
/// and only the findings and images that name it), e.g. from the
/// inspector's Security tab.
abstract final class SecurityFocus {
  static final request = ValueNotifier<ObjectRef?>(null);

  static void open(AppState app, ObjectRef target) {
    request.value = target;
    app.showView(MainView.security);
  }
}

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
  bool _showIgnored = false;
  String? _filter;

  /// Findings picked for Ask Claude (ids).
  final _selected = <String>{};

  /// The ignore rules last seen, to notice the ones Claude Code adds
  /// through the MCP server (null: take the next as the baseline).
  List<SecIgnoreRule>? _knownRules;
  Timer? _ignoreWatch;

  /// Only what names this object (see [SecurityFocus]).
  ObjectRef? _object;
  DateTime? _updatedAt;
  int _seq = 0;
  NamespaceScope _ns = NamespaceScope.all;
  bool _started = false;
  Timer? _poll;

  final _scanning = <String>{};
  final _scanErrors = <String, String>{};
  final _scans = <String, ScanResult>{};

  SecurityApi get source => _source ??= widget.source ?? SecurityApi(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    SecurityFocus.request.addListener(_onFocus);
    _ignoreWatch = Timer.periodic(const Duration(seconds: 4), (_) => _checkIgnores());
  }

  @override
  void dispose() {
    SecurityFocus.request.removeListener(_onFocus);
    _poll?.cancel();
    _ignoreWatch?.cancel();
    super.dispose();
  }

  /// While Claude Code access is on, Claude can ignore findings through
  /// the MCP server: when the rules change, refresh, and say what Claude
  /// ignored.
  Future<void> _checkIgnores() async {
    if (!mounted || _data == null || !(context.read<AppState?>()?.claudeCode ?? false)) return;
    final List<SecIgnoreRule> rules;
    try {
      rules = await source.ignores();
    } catch (_) {
      return;
    }
    final known = _knownRules;
    _knownRules = rules;
    if (!mounted || known == null) return;
    String sig(List<SecIgnoreRule> rs) => [for (final r in rs) '${r.check}|${r.namespace}|${r.kind}|${r.name}|${r.at}'].join(';');
    if (sig(known) == sig(rules)) return;
    final byClaude = rules.where((r) => r.byClaude && !known.any((k) => k.sameTarget(r) && k.at == r.at)).length;
    await _refresh();
    if (!mounted || byClaude == 0) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(byClaude == 1 ? 'Claude Code ignored a finding' : 'Claude Code added $byClaude ignore rules'),
      action: SnackBarAction(label: 'Show', onPressed: () => setState(() => _showIgnored = true)),
      // An action would otherwise keep it open until dismissed.
      persist: false,
    ));
  }

  /// Takes a pending [SecurityFocus] request: its object, scoped to its
  /// namespace. Returns the scope to use, or null when there is none.
  NamespaceScope? _takeFocus() {
    final ref = SecurityFocus.request.value;
    if (ref == null) return null;
    SecurityFocus.request.value = null;
    _object = ref;
    _filter = null;
    return NamespaceScope.single(ref.namespace);
  }

  void _onFocus() {
    if (!_started) return; // taken on the first build
    final scope = _takeFocus();
    if (scope == null) return;
    setState(() {});
    _setScope(scope);
  }

  bool _names(List<ObjectRef> refs) {
    final o = _object;
    return o == null || refs.any((r) => r.kind == o.kind && r.name == o.name && r.namespace == o.namespace);
  }

  Future<void> _refresh() async {
    final seq = ++_seq;
    final ns = _ns;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        source.fetch(scope: ns, includeSystem: _includeSystem),
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
        _selected.retainAll({for (final f in data.findings) f.id});
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

  /// The backend answers early with the categories it has and lists the
  /// rest in `pending`; while something is pending, fetch again after these
  /// delays (the last repeats) instead of waiting for the normal poll.
  static const _quickDelays = [Duration(milliseconds: 700), Duration(milliseconds: 1500), Duration(seconds: 3)];
  int _quickStep = 0;

  /// Re-fetch quickly while categories are pending, else re-check while the
  /// operator is producing its first reports.
  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (_data?.pending.isNotEmpty ?? false) {
      final delay = _quickDelays[_quickStep.clamp(0, _quickDelays.length - 1)];
      _quickStep++;
      _poll = Timer(delay, () {
        if (mounted && !_loading) _refresh();
      });
      return;
    }
    _quickStep = 0;
    if (_scanner?.operatorScanning == true) {
      _poll = Timer(widget.scanningPoll, () {
        if (mounted && !_loading) _refresh();
      });
    }
  }

  void _setScope(NamespaceScope ns) {
    if (ns == _ns) return;
    PageScope.set('security', ns);
    setState(() {
      _ns = ns;
      _data = null; // don't show another scope's numbers
      _quickStep = 0;
    });
    _refresh();
  }

  Future<void> _ignore(SecFinding f) async {
    final data = _data;
    if (data == null) return;
    final rules = await showIgnoreDialog(context, f, data.findings);
    if (rules == null || !mounted) return;
    await _changeIgnores(() => source.addIgnores([for (final r in rules) SecIgnoreRule(check: r.check, namespace: r.namespace, kind: r.kind, name: r.name, reason: r.reason, at: DateTime.now().toUtc().toIso8601String())]));
  }

  Future<void> _ignoreSelected(List<SecFinding> picked) async {
    final data = _data;
    if (data == null) return;
    final rules = await showBulkIgnoreDialog(context, picked, data.findings);
    if (rules == null || !mounted) return;
    final at = DateTime.now().toUtc().toIso8601String();
    await _changeIgnores(() => source.addIgnores([for (final r in rules) SecIgnoreRule(check: r.check, namespace: r.namespace, kind: r.kind, name: r.name, reason: r.reason, at: at)]));
    if (mounted) setState(_selected.clear);
  }

  Future<void> _unignore(SecFinding f) => _changeIgnores(() => source.unignore(f));

  Future<void> _changeIgnores(Future<void> Function() change) async {
    _knownRules = null; // the user's own change: no notice
    try {
      await change();
    } catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    if (mounted) await _refresh();
  }

  void _askClaude(List<SecFinding> findings, String? group) {
    if (findings.isEmpty) return;
    openClaudeCode(context, prompt: securityPrompt(findings, group: group));
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
      setState(() => _scanErrors[image] = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning.remove(image));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      // Security has its own scope (independent of the table's namespace),
      // defaulting to all namespaces and remembered for the session.
      _started = true;
      _ns = PageScope.of('security');
      final focus = _takeFocus();
      if (focus != null) {
        _ns = focus;
        PageScope.set('security', focus);
      }
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
        Expanded(child: _error == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_error!, onRetry: _refresh)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const Divider(),
      if (data.partialErrors.isNotEmpty) PartialBanner(errors: data.partialErrors),
      // Page-level failures: under the header, in the content's inset.
      if (_error != null || data.errors.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_error != null) ErrorNotice(_error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: _refresh),
            if (_error != null && data.errors.isNotEmpty) const SizedBox(height: 10),
            if (data.errors.isNotEmpty)
              ErrorNotice.parts(
                data.errors,
                title: data.errors.length == 1 ? "Couldn't list ${data.errors.keys.single}" : "Couldn't list ${data.errors.length} kinds",
                note: 'Findings cover the rest.',
                onRetry: _refresh,
              ),
          ]),
        ),
      Expanded(
        child: PageScroll(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: _body(context, data)),
      ),
    ]);
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return PageHeader(
      title: 'Security',
      subtitle: PageScopePicker(value: _ns, onChanged: _setScope),
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
    final findings = [for (final f in data.findings) if ((filter == null || f.category == filter) && _names(f.objects)) f];
    bool show(String id) => filter == null || filter == id;
    final pending = data.pending;
    final ignored = [for (final i in data.ignored) if ((filter == null || i.finding.category == filter) && _names(i.finding.objects)) i];
    final claude = claudeAvailable(context);
    final picked = [for (final f in findings) if (_selected.contains(f.id)) f];
    // A section whose category is still loading keeps its place with
    // placeholder rows rather than reading as empty.
    Widget pendingSection(String id, String title) => DetailSection(
          key: ValueKey('pending-section-$id'),
          title: title,
          child: const PendingSecurityRows(rows: 3),
        );
    final images = [for (final i in data.images) if (_names(i.workloads)) _scans[i.image] != null ? i.withScan(_scans[i.image]!) : i];
    return [
      SummaryLine(data: data),
      const SizedBox(height: 14),
      CategoryTiles(categories: data.categories, pending: pending, selected: filter, onSelect: (id) => setState(() => _filter = _filter == id ? null : id)),
      const SizedBox(height: 14),
      DetailSection(
        title: 'Findings',
        trailing: _findingsTrailing(context, data, findings.length, ignored.length),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (picked.isNotEmpty) _selectionBar(context, picked, claude: claude),
          FindingList(
            key: ValueKey('findings-$filter'),
            findings: findings,
            categories: data.categories,
            grouped: filter == null,
            hideNamespace: _ns.single != null,
            pending: {for (final p in pending) if (show(p)) p},
            onIgnore: _ignore,
            onAskClaude: claude ? _askClaude : null,
            selected: _selected,
            onSelect: (ids, on) => setState(() => on ? _selected.addAll(ids) : _selected.removeAll(ids)),
          ),
          if (claude && filter != null && findings.isNotEmpty && picked.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AskClaudeLink(
                  key: const ValueKey('ask-claude-filtered'),
                  label: findings.length == 1 ? 'Ask Claude about this finding' : 'Ask Claude about these ${findings.length}',
                  onTap: () => _askClaude(findings, data.categories.where((c) => c.id == filter).map((c) => c.title).firstOrNull),
                ),
              ),
            ),
        ]),
      ),
      if (_showIgnored && ignored.isNotEmpty)
        DetailSection(
          title: 'Ignored',
          child: IgnoredList(
            items: ignored,
            coveredBy: (r) => data.ignored.where((i) => i.rule.sameTarget(r)).length,
            onUnignore: _unignore,
          ),
        ),
      if (show('network') && data.isPending('network'))
        pendingSection('network', 'Network exposure by namespace')
      else if (show('network'))
        DetailSection(
          title: 'Network exposure by namespace',
          trailing: Text('${data.network.length}', style: hint),
          child: NetworkMatrix(rows: data.network),
        ),
      if (show('rbac') && data.isPending('rbac'))
        pendingSection('rbac', 'Most permissive grants')
      else if (show('rbac'))
        DetailSection(
          title: 'Most permissive grants',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(data.includeSystem ? 'including system' : 'excluding system defaults', maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => AccessFocus.open(context.read<AppState>()),
              child: const Text('Explore in Access'),
            ),
          ]),
          child: PermissiveTable(grants: data.permissive),
        ),
      if (show('images') && data.isPending('images'))
        pendingSection('images', 'Images')
      else if (show('images')) ...[
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

  /// "3 selected · Ask Claude · Ignore… · Clear" above the findings.
  Widget _selectionBar(BuildContext context, List<SecFinding> picked, {required bool claude}) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('security-selection-bar'),
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Text('${picked.length} selected', style: theme.textTheme.bodySmall),
        const Spacer(),
        if (claude) ...[
          FilledButton.tonalIcon(
            key: const ValueKey('ask-claude-selected'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
            icon: const Icon(Icons.auto_awesome_outlined, size: 15),
            label: const Text('Ask Claude'),
            onPressed: () => _askClaude(picked, null),
          ),
          const SizedBox(width: 6),
        ],
        OutlinedButton.icon(
          key: const ValueKey('ignore-selected'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
          icon: const Icon(Icons.visibility_off_outlined, size: 15),
          label: const Text('Ignore…'),
          onPressed: () => _ignoreSelected(picked),
        ),
        const SizedBox(width: 6),
        TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => setState(_selected.clear),
          child: const Text('Clear'),
        ),
      ]),
    );
  }

  String _imagesSummary(List<ImageSummary> images) {
    final scanned = images.where((i) => i.scanned).length;
    return '$scanned of ${images.length} scanned';
  }

  Widget _findingsTrailing(BuildContext context, SecurityData data, int shown, int ignored) {
    final o = _object;
    if (o == null) return _categoryTrailing(context, data, shown, ignored);
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      InputChip(
        key: const ValueKey('security-object-filter'),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text('${o.kind} ${o.name} · $shown', style: theme.textTheme.labelSmall),
        onDeleted: () => setState(() => _object = null),
        deleteButtonTooltipMessage: 'Show every object',
        onPressed: () => setState(() => _object = null),
      ),
      const SizedBox(width: 6),
      Flexible(child: _categoryTrailing(context, data, shown, ignored)),
    ]);
  }

  /// "N ignored", and how many of all of them Claude ignored.
  String _ignoredLabel(SecurityData data, int n, {required bool all}) {
    final claude = all ? data.ignored.where((i) => i.rule.byClaude).length : 0;
    return claude == 0 ? '$n ignored' : '$n ignored · $claude by Claude';
  }

  Widget _categoryTrailing(BuildContext context, SecurityData data, int shown, int ignored) {
    final theme = Theme.of(context);
    final filter = _filter;
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    // Never silent: the ignored count shows whenever it is not zero.
    final allIgnored = filter == null && _object == null;
    final toggle = (allIgnored ? data.ignored.length : ignored) == 0
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: 6),
            child: FilterChip(
              key: const ValueKey('toggle-ignored'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              showCheckmark: false,
              selected: _showIgnored,
              tooltip: _showIgnored ? 'Hide the ignored findings' : 'Show the ignored findings, who ignored them and why',
              avatar: Icon(Icons.visibility_off_outlined, size: 14, color: theme.hintColor),
              label: Text(_ignoredLabel(data, allIgnored ? data.ignored.length : ignored, all: allIgnored), style: hint),
              onSelected: (v) => setState(() => _showIgnored = v),
            ),
          );
    if (filter == null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [if (_object == null) Text('${data.findings.length}', style: hint), ?toggle]);
    }
    final label = data.categories.where((c) => c.id == filter).map((c) => c.title).firstOrNull ?? filter;
    final chip = InputChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: Text('$label · $shown', style: theme.textTheme.labelSmall),
      onDeleted: () => setState(() => _filter = null),
      deleteButtonTooltipMessage: 'Show all findings',
      onPressed: () => setState(() => _filter = null),
    );
    return toggle == null ? chip : Row(mainAxisSize: MainAxisSize.min, children: [chip, toggle]);
  }

}
