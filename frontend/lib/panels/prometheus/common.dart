import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/widgets/atoms.dart';

/// Explains why live state is missing, calmly (no Prometheus vs. an error).
class LiveStateMessage extends StatelessWidget {
  final Object error;
  const LiveStateMessage(this.error, {super.key});

  @override
  Widget build(BuildContext context) {
    final e = error;
    if (e is ApiException && e.status == 404 && e.reason == 'NotFound') {
      return const InlineMessage('Live state needs a reachable Prometheus; none was found.', icon: Icons.cloud_off_outlined);
    }
    return ErrorNotice(e, title: 'Live state unavailable', severity: Severity.warn);
  }
}

/// A LabelSelector as chips, with "everything" / "nothing" wording.
/// For Prometheus CR selectors a missing selector selects nothing and `{}`
/// selects everything.
class SelectorView extends StatelessWidget {
  final dynamic selector;
  final String emptyText;
  final String missingText;
  const SelectorView(this.selector, {super.key, this.emptyText = 'everything', this.missingText = 'nothing'});

  @override
  Widget build(BuildContext context) {
    if (selector == null) return HintText(missingText);
    final sel = asMap(selector);
    final terms = selectorTerms({'matchLabels': sel['matchLabels'], 'matchExpressions': sel['matchExpressions']});
    if (terms.isEmpty) return HintText(emptyText);
    return Wrap(spacing: 4, runSpacing: 4, children: [for (final t in terms) Chipish(text: t)]);
  }
}

/// "Open Alerts" link to the Alerts page.
class OpenAlertsButton extends StatelessWidget {
  final AppState app;
  final String label;
  const OpenAlertsButton(this.app, {super.key, this.label = 'Open Alerts'});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => app.showView(MainView.alerts),
        icon: const Icon(Icons.notifications_none, size: 15),
        label: Text(label),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
      );
}

/// Live state colouring for rules: firing uses the rule's severity colour,
/// pending is amber, inactive is calm.
Severity ruleStateBadge(String? state, String? severityLabel) => switch (state) {
      'firing' => AlertSeverity.parse(severityLabel).badge == Severity.neutral ? Severity.error : AlertSeverity.parse(severityLabel).badge,
      'pending' => Severity.warn,
      'inactive' => Severity.ok,
      _ => Severity.neutral,
    };

Color healthColor(BuildContext context, String health) => switch (health) {
      'up' || 'ok' => severityColor(context, Severity.ok),
      'down' || 'err' => severityColor(context, Severity.error),
      _ => severityColor(context, Severity.neutral),
    };

/// "3 up · 1 down" with coloured counts.
class UpDownCounts extends StatelessWidget {
  final int up, down, unknown;
  const UpDownCounts({super.key, required this.up, required this.down, this.unknown = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall;
    return Text.rich(TextSpan(children: [
      TextSpan(text: '$up up', style: base?.copyWith(color: up > 0 ? severityColor(context, Severity.ok) : theme.hintColor, fontWeight: FontWeight.w600)),
      TextSpan(text: ' · ', style: base?.copyWith(color: theme.hintColor)),
      TextSpan(text: '$down down', style: base?.copyWith(color: down > 0 ? severityColor(context, Severity.error) : theme.hintColor, fontWeight: down > 0 ? FontWeight.w600 : null)),
      if (unknown > 0) ...[
        TextSpan(text: ' · ', style: base?.copyWith(color: theme.hintColor)),
        TextSpan(text: '$unknown unknown', style: base?.copyWith(color: theme.hintColor)),
      ],
    ]));
  }
}

/// A target row: health dot, scrape URL, object link, last scrape, error.
class ScrapeTargetRow extends StatelessWidget {
  final ScrapeTarget target;
  const ScrapeTargetRow(this.target, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = target;
    final c = healthColor(context, t.health);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.scrapeUrl, maxLines: 2, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
            Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (t.target != null) ResourceLink(t.target!, label: '${t.target!.kind} ${t.target!.name}'),
              if (parseTime(t.lastScrape) != null && parseTime(t.lastScrape)!.year > 1)
                AgeText(t.lastScrape, suffix: ' ago', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (t.lastScrapeDuration > 0) HintText('${(t.lastScrapeDuration * 1000).toStringAsFixed(t.lastScrapeDuration < 0.01 ? 1 : 0)} ms'),
            ]),
            if (t.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(t.lastError!, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error))),
              ),
          ]),
        ),
      ]),
    );
  }
}

ObjectRef crRef(String kind, String namespace, String name) => ObjectRef(group: 'monitoring.coreos.com', kind: kind, name: name, namespace: namespace);
