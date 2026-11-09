import '../../api/models.dart';
import 'security_api.dart';

/// Renders a security report as a self-contained Markdown brief that can be
/// pasted into an AI agent: instructions, context, a summary, then findings
/// (most severe first) with affected objects and remediation, plus the most
/// permissive RBAC grants and the most vulnerable images.
///
/// [category] limits findings to one category (the page's current filter).
/// Output is capped ([maxFindings], [maxObjects] per finding) so it fits in a
/// prompt; truncation is stated explicitly so the agent knows.
String securityReportForAgent(
  SecurityData d, {
  required String kubeContext,
  String? category,
  int maxFindings = 40,
  int maxObjects = 8,
}) {
  final b = StringBuffer();
  final scope = d.namespace.isEmpty ? 'all namespaces' : 'namespace `${d.namespace}`';
  final catTitle = category == null ? null : d.categories.where((c) => c.id == category).map((c) => c.title).firstOrNull ?? category;

  b
    ..writeln('# Kubernetes security findings${catTitle != null ? ' — $catTitle' : ''}')
    ..writeln()
    ..writeln('> Context for an AI assistant: these findings come from a read-only scan by k8sman. '
        'Help me remediate them. Prioritise critical and high severity. For each item, explain the risk briefly, '
        'then propose concrete fixes as minimal YAML patches (or Helm values / kubectl commands) that I can review. '
        'Call out fixes that could break workloads (e.g. default-deny NetworkPolicies, dropping privileges) and suggest how to roll them out safely. '
        'Do not assume access to the cluster; ask me for any manifests you need.')
    ..writeln()
    ..writeln('- **Cluster context:** `$kubeContext`')
    ..writeln('- **Scope:** $scope${d.includeSystem ? ' (including system namespaces and roles)' : ' (system namespaces and default roles excluded)'}')
    ..writeln('- **Score:** ${d.score}/100')
    ..writeln('- **Generated:** ${d.generatedAt}');
  if (d.pending.isNotEmpty) {
    b.writeln('- **Partial:** ${d.pending.join(', ')} still loading; the score and findings leave them out.');
  }
  if (d.ignored.isNotEmpty) {
    b.writeln('- **Ignored:** ${d.ignored.length} findings the user chose to ignore are left out of the score and this list.');
  }
  if (d.errors.isNotEmpty) {
    b.writeln('- **Incomplete data:** could not list ${d.errors.keys.join(', ')} (permissions?), so some checks are missing.');
  }
  b.writeln();

  // Summary table.
  b
    ..writeln('## Summary')
    ..writeln()
    ..writeln('| Category | Critical | High | Medium | Low | Info |')
    ..writeln('|---|---:|---:|---:|---:|---:|');
  for (final c in d.categories) {
    if (category != null && c.id != category) continue;
    int n(SecSeverity s) => c.counts[s] ?? 0;
    b.writeln('| ${c.title} | ${n(SecSeverity.critical)} | ${n(SecSeverity.high)} | ${n(SecSeverity.medium)} | ${n(SecSeverity.low)} | ${n(SecSeverity.info)} |');
  }
  b.writeln();

  // Findings, most severe first (info only if nothing else).
  final all = d.findings.where((f) => category == null || f.category == category).toList()
    ..sort((a, c) => a.severity.index.compareTo(c.severity.index));
  final actionable = all.where((f) => f.severity != SecSeverity.info).toList();
  final findings = (actionable.isEmpty ? all : actionable).take(maxFindings).toList();
  b
    ..writeln('## Findings')
    ..writeln();
  if (findings.isEmpty) b.writeln('No findings.');
  for (final f in findings) {
    b.writeln('### [${f.severity.label}] ${f.title}');
    final meta = [
      'category: ${f.category}',
      if (f.namespace != null && f.namespace!.isNotEmpty) 'namespace: `${f.namespace}`',
      if (f.checks.isNotEmpty) 'checks: ${f.checks.map((c) => '`$c`').join(', ')}' else if (f.check.isNotEmpty) 'check: `${f.check}`',
    ];
    b.writeln('_${meta.join(' · ')}_');
    b.writeln();
    if (f.detail.trim().isNotEmpty) b.writeln(f.detail.trim());
    if (f.objects.isNotEmpty) {
      b.writeln();
      b.writeln('Affected:');
      for (final o in f.objects.take(maxObjects)) {
        b.writeln('- ${_ref(o)}');
      }
      if (f.objects.length > maxObjects) b.writeln('- …and ${f.objects.length - maxObjects} more');
    }
    if (f.remediation.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('Suggested remediation: ${f.remediation.trim()}');
    }
    b.writeln();
  }
  final omitted = (actionable.isEmpty ? all : actionable).length - findings.length;
  final infoCount = actionable.isEmpty ? 0 : all.length - actionable.length;
  if (omitted > 0 || infoCount > 0) {
    b.writeln('_Not included: ${[
      if (omitted > 0) '$omitted more findings (lower severity)',
      if (infoCount > 0) '$infoCount informational findings',
    ].join(' and ')}._');
    b.writeln();
  }

  // RBAC: most permissive grants.
  if (category == null || category == 'rbac') {
    final grants = d.permissive.take(10).toList();
    if (grants.isNotEmpty) {
      b
        ..writeln('## Most permissive RBAC grants')
        ..writeln()
        ..writeln('| Risk | Binding → Role | Scope | Subjects | Why |')
        ..writeln('|---:|---|---|---|---|');
      for (final g in grants) {
        final subjects = g.subjects
            .map((s) => '${s.kind} ${s.namespace != null ? '${s.namespace}/' : ''}${s.name}${s.exists == false ? ' (missing)' : ''}${s.used == false ? ' (unused)' : ''}')
            .join('; ');
        b.writeln('| ${g.score} | ${_ref(g.binding)} → ${_ref(g.role)}${g.roleMissing ? ' (role missing)' : ''}${g.unused ? ' **unused**' : ''} '
            '| ${g.scope} | ${_cell(subjects)} | ${_cell(g.reasons.join('; '))} |');
      }
      b.writeln();
    }
  }

  // Images with fixable vulnerabilities.
  if (category == null || category == 'images') {
    final imgs = d.images.where((i) => i.scanned && (i.counts.critical + i.counts.high) > 0).toList()
      ..sort((a, c) => (c.counts.fixableCritical * 10 + c.counts.fixableHigh).compareTo(a.counts.fixableCritical * 10 + a.counts.fixableHigh));
    if (imgs.isNotEmpty) {
      b
        ..writeln('## Vulnerable images')
        ..writeln()
        ..writeln('| Image | Critical (fixable) | High (fixable) | Used by | Top CVEs |')
        ..writeln('|---|---:|---:|---|---|');
      for (final i in imgs.take(10)) {
        final cves = i.topCves.take(3).map((c) => '${c.id} (${c.package} ${c.installed}${c.fixed != null ? ' → ${c.fixed}' : ''})').join('; ');
        b.writeln('| `${i.image}` | ${i.counts.critical} (${i.counts.fixableCritical}) | ${i.counts.high} (${i.counts.fixableHigh}) '
            '| ${_cell(i.workloads.take(3).map(_ref).join(', '))} | ${_cell(cves)} |');
      }
      b.writeln();
    } else if (!d.trivyOperator && category == 'images') {
      b.writeln('_No image scan data: the Trivy Operator is not installed._');
      b.writeln();
    }
  }

  return b.toString().trimRight();
}

String _ref(ObjectRef o) => '${o.kind} `${o.namespace != null && o.namespace!.isNotEmpty ? '${o.namespace}/' : ''}${o.name}`';

/// Keep table cells on one line and pipe-safe.
String _cell(String s) => s.replaceAll('|', '\\|').replaceAll('\n', ' ');
