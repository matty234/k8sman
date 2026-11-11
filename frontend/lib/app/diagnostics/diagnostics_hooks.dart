/// Wires [DiagnosticsLog] into Flutter: framework errors
/// ([FlutterError.onError]), uncaught async errors
/// ([PlatformDispatcher.onError]) and the error widget
/// ([ErrorWidget.builder]): the red box in debug builds, a quiet
/// "Couldn't show this section · Report" line in release and profile.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'diagnostics_log.dart';

/// Hooks [log] up, keeping whatever handlers were there (presenting
/// errors on the console, as before). [onReport] opens Diagnostics.
void installDiagnostics(DiagnosticsLog log, {VoidCallback? onReport, bool release = !kDebugMode}) {
  final present = FlutterError.onError;
  FlutterError.onError = (details) {
    log.record(details);
    present?.call(details);
  };
  final async = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    final details = FlutterErrorDetails(exception: error, stack: stack, library: 'k8sman', context: ErrorDescription('an uncaught async error'));
    log.record(details, phase: 'async');
    if (async != null) return async(error, stack);
    FlutterError.presentError(details);
    return true;
  };
  final fallback = ErrorWidget.builder;
  ErrorWidget.builder = (details) => diagnosticsErrorWidget(details, log: log, release: release, onReport: onReport, fallback: fallback);
}

/// The widget shown where a build failed: in [release], a quiet
/// [ErrorPlaceholder]; otherwise [fallback] (Flutter's red box). Either
/// way the failure's place in the app is noted on its diagnostics group.
Widget diagnosticsErrorWidget(
  FlutterErrorDetails details, {
  DiagnosticsLog? log,
  required bool release,
  VoidCallback? onReport,
  ErrorWidgetBuilder? fallback,
}) {
  final child = release ? ErrorPlaceholder(onReport: onReport) : (fallback ?? ErrorWidget.builder)(details);
  if (log == null) return child;
  return Builder(builder: (context) {
    final where = diagnosticsContextOf(context);
    if (where.isNotEmpty) log.attachContext(details, where);
    return child;
  });
}

/// "Couldn't show this section · Report", small and in the theme's
/// colours, for a section whose build failed in a release build. Safe
/// anywhere: it needs no Material, Directionality or bounded width.
class ErrorPlaceholder extends StatelessWidget {
  final VoidCallback? onReport;
  const ErrorPlaceholder({super.key, this.onReport});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final style = (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(color: hint, decoration: TextDecoration.none);
    final body = Container(
      key: const ValueKey('error-placeholder'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Icon(Icons.error_outline, size: 14, color: hint),
        Text("Couldn't show this section", style: style),
        if (onReport != null) ...[
          Text('·', style: style),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onReport,
              child: Text('Report', style: style.copyWith(color: theme.colorScheme.primary)),
            ),
          ),
        ],
      ]),
    );
    final out = Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: body);
    return Directionality.maybeOf(context) == null ? Directionality(textDirection: TextDirection.ltr, child: out) : out;
  }
}
