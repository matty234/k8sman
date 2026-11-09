/// The insight model, widget-free so pure logic (e.g. `pod_logic.dart`)
/// can derive insights.
library;

import 'package:flutter/widgets.dart' show Widget;

import '../../util/k8s.dart';

/// A derived, human explanation of a problem (or a notable state) under a
/// status header: "Last run failed: BackoffLimitExceeded" over a quieter
/// detail.
class Insight {
  final Severity severity;
  final String text;
  final String? detail;

  /// Replaces [text] (e.g. a line with a link in it).
  final Widget? title;

  /// A small control under the text (a button, a link).
  final Widget? action;
  const Insight(this.severity, this.text, [this.detail])
      : title = null,
        action = null;

  /// With a [title] widget in place of the text and/or an [action].
  const Insight.rich(this.severity, this.text, {this.detail, this.title, this.action});

  @override
  String toString() => detail == null ? text : '$text — $detail';
}

/// The worst of [insights] (null when there are none or only info).
Severity? worstOf(Iterable<Insight> insights) {
  if (insights.any((i) => i.severity == Severity.error)) return Severity.error;
  if (insights.any((i) => i.severity == Severity.warn)) return Severity.warn;
  return null;
}

