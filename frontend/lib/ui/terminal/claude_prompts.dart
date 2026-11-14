import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../prometheus/prom_api.dart';
import '../../state/app_state.dart';
import '../overview/overview_api.dart';
import '../security/security_api.dart';
import 'open_terminal.dart';

// "Ask Claude" from where problems are shown (Overview, the Issues and
// Alerts panes): a Claude Code tab whose prompt already holds what the row
// knows, so Claude starts from the symptom rather than rediscovering it.
// `claude` submits the prompt as the session starts (it has no way to
// pre-fill the input), so the prompt carries cluster text as data.

const _ask = 'Using the k8sman tools, investigate';
const _fix = 'Find the root cause and suggest a fix.';

/// Whether to offer Ask Claude: Claude Code access is on and local shells
/// work here. Rebuilds when the setting changes.
bool claudeAvailable(BuildContext context) => localShellSupported && context.select<AppState?, bool>((a) => a?.claudeCode ?? false);

String _clip(String s, [int max = 600]) {
  s = s.trim();
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

String _obj(String kind, String name, String? ns) => ns == null || ns.isEmpty ? '$kind $name' : '$kind $name in namespace $ns';

/// An Overview issue row: one object, or several under one owner.
String issuePrompt(IssueGroup g) {
  final i = g.first;
  if (g.issues.length == 1) {
    final facts = [
      if (i.since != null) 'since ${i.since}',
      if (i.count > 0) '${i.count} restarts',
      if (i.owner != null) 'owned by ${i.owner!.kind} ${i.owner!.name}',
    ];
    final msg = i.message.isEmpty ? '' : ': "${_clip(i.message)}"';
    final extra = facts.isEmpty ? '' : ' (${facts.join(', ')})';
    return '$_ask why ${_obj(i.kind, i.name, i.namespace)} is ${i.reason}$msg$extra. $_fix';
  }
  final s = g.subject;
  final names = g.issues.take(5).map((x) => x.name).join(', ');
  final more = g.issues.length > 5 ? ' and ${g.issues.length - 5} more' : '';
  final msg = i.message.isEmpty ? '' : ' One says: "${_clip(i.message)}".';
  return '$_ask why ${g.issues.length} objects of ${_obj(s.kind, s.name, g.namespace)} have problems '
      '(${i.reason}: $names$more).$msg Look at the ${s.kind} as a whole, not one pod. $_fix';
}

/// A row of the Overview's Warning events (grouped by reason).
String warningPrompt(WarningReason r) {
  final ex = r.example;
  final on = ex == null ? '' : ', for example on ${_obj(ex.kind, ex.name, ex.namespace)}';
  final objects = r.objects > 1 ? ' across ${r.objects} objects' : '';
  return '$_ask the Kubernetes Warning events with reason ${r.reason} '
      '(${r.count} in the last hour$objects$on). Latest message: "${_clip(r.latestMessage)}". $_fix';
}

/// A Prometheus / Alertmanager alert.
String alertPrompt(PromAlert a) {
  final t = a.target;
  final on = t == null ? '' : ' on ${_obj(t.kind, t.name, t.namespace)}';
  final sev = a.severityLabel.isEmpty ? '' : ' (severity ${a.severityLabel})';
  final text = [?a.summary, if (a.description != a.summary) ?a.description].map(_clip).join(' ');
  final labels = a.labels.entries.where((e) => e.key != 'alertname').take(12).map((e) => '${e.key}=${e.value}').join(', ');
  return '$_ask the ${a.state.name} alert ${a.alertname}$sev$on${a.startsAt == null ? '' : ', active since ${a.startsAt}'}. '
      '${text.isEmpty ? '' : '$text '}${labels.isEmpty ? '' : 'Labels: $labels. '}'
      'Map it to the objects in the cluster. $_fix';
}

/// Security findings (one, a category's, or a selection). Ids let Claude
/// look each up with get_security_finding and ignore it with
/// ignore_security_findings. Stays under the backend's prompt cap: past
/// [budget] characters the rest are named by id only, then counted.
String securityPrompt(List<SecFinding> findings, {String? group, int budget = 4000}) {
  final fs = [...findings]..sort((a, b) => a.severity.index.compareTo(b.severity.index));
  final what = group != null
      ? 'the ${fs.length} $group security ${fs.length == 1 ? 'finding' : 'findings'}'
      : fs.length == 1
          ? 'this security finding'
          : 'these ${fs.length} security findings';
  final b = StringBuffer('Using the k8sman tools, review $what from k8sman\'s Security page '
      '(get_security_finding has the details of each id).\n');
  final idsOnly = <String>[];
  for (final f in fs) {
    final objs = f.objects.take(3).map((o) => _obj(o.kind, o.name, o.namespace == f.namespace ? null : o.namespace)).join(', ');
    final more = f.objects.length > 3 ? ' +${f.objects.length - 3} more' : '';
    final line = '- ${f.id} [${f.severity.label}] ${_clip(f.title, 160)}'
        '${f.namespace == null ? '' : ' (namespace ${f.namespace})'}${objs.isEmpty ? '' : ': $objs$more'}\n';
    b.length + line.length > budget ? idsOnly.add(f.id) : b.write(line);
  }
  if (idsOnly.isNotEmpty) {
    final ids = StringBuffer();
    for (final id in idsOnly) {
      if (b.length + ids.length + id.length > budget + 500) break;
      ids.write(ids.isEmpty ? id : ', $id');
    }
    final named = ids.isEmpty ? 0 : ids.toString().split(', ').length;
    b.write('- also: $ids${idsOnly.length > named ? ' and ${idsOnly.length - named} more (list_security_findings)' : ''}\n');
  }
  b.write('${fs.length == 1 ? 'E' : 'For each, e'}xplain the risk briefly, then either propose a minimal fix (a YAML patch or kubectl command for me to review; '
      'flag anything that could break workloads) or, if it looks intended, say why and offer to ignore it with '
      'ignore_security_findings and that reason. Ask me before changing the cluster or ignoring anything.');
  return b.toString();
}

/// A small ✦ button that opens Claude Code with [prompt].
class AskClaudeButton extends StatelessWidget {
  final String prompt;
  final double size;
  const AskClaudeButton({super.key, required this.prompt, this.size = 15});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Ask Claude about this (opens Claude Code in the bottom panel)',
      icon: Icon(Icons.auto_awesome_outlined, size: size, color: Theme.of(context).colorScheme.primary),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      onPressed: () => openClaudeCode(context, prompt: prompt),
    );
  }
}
