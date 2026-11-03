import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../prometheus/prom_api.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// Labels that identify *what* an alert is about. Silences prefill these
/// (never volatile ones like instance IPs or uids).
const identifyingLabels = [
  'namespace',
  'pod',
  'container',
  'node',
  'deployment',
  'statefulset',
  'daemonset',
  'job_name',
  'cronjob',
  'persistentvolumeclaim',
  'service',
];

/// Matchers for silencing one alert instance: its alertname plus the
/// identifying labels it carries.
List<SilenceMatcher> matchersForAlert(PromAlert a) => [
      SilenceMatcher(name: 'alertname', value: a.alertname),
      for (final k in identifyingLabels)
        if ((a.labels[k] ?? '').isNotEmpty && !_redundant(k, a.labels)) SilenceMatcher(name: k, value: a.labels[k]!),
    ];

/// `service` on a pod alert is usually the scrape target's Service (e.g.
/// kube-state-metrics), not the subject: leave it out.
bool _redundant(String key, Map<String, String> labels) => key == 'service' && (labels['pod'] ?? '').isNotEmpty;

/// Matchers for a whole group: alertname plus identifying labels every
/// instance shares (e.g. the namespace).
List<SilenceMatcher> matchersForGroup(String alertname, List<PromAlert> alerts) {
  final out = [SilenceMatcher(name: 'alertname', value: alertname)];
  if (alerts.isEmpty) return out;
  for (final k in identifyingLabels) {
    final v = alerts.first.labels[k];
    if (v != null && v.isNotEmpty && !_redundant(k, alerts.first.labels) && alerts.every((a) => a.labels[k] == v)) out.add(SilenceMatcher(name: k, value: v));
  }
  return out;
}

const silenceDurations = <(String, String)>[('1h', '1h'), ('4h', '4h'), ('1d', '1d')];

/// Editable state of the silence form.
class SilenceFormModel extends ChangeNotifier {
  final List<SilenceMatcher> matchers;
  final List<bool> enabled;
  String duration = '1h';
  final TextEditingController comment;

  SilenceFormModel(this.matchers, {String comment = 'Silenced from k8sman'})
      : enabled = List.filled(matchers.length, true),
        comment = TextEditingController(text: comment);

  List<SilenceMatcher> get selected => [for (final (i, m) in matchers.indexed) if (enabled[i]) m];

  void toggle(int i) {
    enabled[i] = !enabled[i];
    notifyListeners();
  }

  void setDuration(String d) {
    duration = d;
    notifyListeners();
  }

  SilenceDraft get draft => SilenceDraft(
        matchers: selected,
        duration: duration,
        comment: comment.text.trim().isEmpty ? 'Silenced from k8sman' : comment.text.trim(),
      );
}

/// Matchers (toggleable), duration presets, comment and a live count of
/// the alerts the silence would match.
class SilenceForm extends StatelessWidget {
  final SilenceFormModel model;
  final List<PromAlert> alerts;
  const SilenceForm({super.key, required this.model, this.alerts = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final sel = model.selected;
        final matching = sel.isEmpty ? 0 : alerts.where((a) => sel.every((m) => m.matches(a.labels))).length;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Matchers', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(6)),
            child: Column(children: [
              for (final (i, m) in model.matchers.indexed)
                InkWell(
                  key: ValueKey('matcher-${m.name}'),
                  onTap: () => model.toggle(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Row(children: [
                      Icon(model.enabled[i] ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 16, color: model.enabled[i] ? theme.colorScheme.primary : theme.hintColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: m.name, style: monoStyle(context, color: theme.hintColor)),
                            TextSpan(text: m.op, style: monoStyle(context, color: theme.hintColor)),
                            TextSpan(text: '"${m.value}"', style: monoStyle(context)),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          Text(
            sel.isEmpty ? 'Select at least one matcher.' : 'Matches $matching current alert${matching == 1 ? '' : 's'}.',
            style: hint?.copyWith(color: sel.isEmpty ? severityColor(context, Severity.warn) : null),
          ),
          const SizedBox(height: 12),
          Text('Duration', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [for (final (v, label) in silenceDurations) ButtonSegment(value: v, label: Text(label))],
            selected: {model.duration},
            onSelectionChanged: (s) => model.setDuration(s.first),
          ),
          const SizedBox(height: 12),
          Text('Comment', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('silence-comment'),
            controller: model.comment,
            minLines: 1,
            maxLines: 3,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(isDense: true, hintText: 'Why is this silenced?'),
          ),
          const SizedBox(height: 4),
          Text('Created by k8sman.', style: hint),
          const SizedBox(height: 14),
        ]);
      },
    );
  }
}

/// The Silence… flow: form + confirmation (with a warning on non-local
/// clusters), then create and report.
Future<bool> showSilenceDialog(
  BuildContext context, {
  required PromApi prom,
  required String alertname,
  required List<SilenceMatcher> matchers,
  String? instance,
  List<PromAlert> alerts = const [],
}) async {
  final app = context.read<AppState>();
  final model = SilenceFormModel(matchers);
  final ok = await confirmAction(
    context,
    title: 'Silence $alertname',
    kubeContext: app.currentContext,
    objectName: alertname,
    destructive: true,
    confirmLabel: 'Silence',
    width: 480,
    extra: SilenceForm(model: model, alerts: alerts),
  );
  if (ok != true || !context.mounted) return false;
  if (model.selected.isEmpty) {
    showActionError(context, 'Select at least one matcher.');
    return false;
  }
  final draft = model.draft;
  try {
    await prom.createSilence(draft, instance: instance);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Silenced $alertname for ${draft.duration}')));
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, 'Could not create the silence: ${e.message}');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not create the silence: $e');
  }
  return false;
}

/// Expire (end) a silence after confirmation.
Future<bool> expireSilenceFlow(BuildContext context, {required PromApi prom, required Silence silence, String? instance}) async {
  final app = context.read<AppState>();
  final name = silence.matchers.where((m) => m.name == 'alertname').map((m) => m.value).firstOrNull ??
      (silence.id.length > 8 ? silence.id.substring(0, 8) : silence.id);
  final ok = await confirmAction(
    context,
    title: 'Expire silence?',
    message: 'Alerts matching ${silence.matchers.join(', ')} will notify again.',
    kubeContext: app.currentContext,
    objectName: name,
    destructive: true,
    confirmLabel: 'Expire',
  );
  if (ok != true || !context.mounted) return false;
  try {
    await prom.expireSilence(silence.id, instance: instance);
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Silence expired')));
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, 'Could not expire the silence: ${e.message}');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not expire the silence: $e');
  }
  return false;
}
