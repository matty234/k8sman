import 'package:flutter/material.dart';

import '../util/k8s.dart';

const monoFamily = 'Menlo';
const monoFallback = ['SF Mono', 'Monaco', 'Courier New', 'monospace'];

TextStyle monoStyle(BuildContext context, {double size = 12, Color? color}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      height: 1.4,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );

Color severityColor(BuildContext context, Severity s) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (s) {
    case Severity.ok:
      return dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
    case Severity.warn:
      return dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
    case Severity.error:
      return dark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);
    case Severity.info:
      return dark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    case Severity.neutral:
      return Theme.of(context).hintColor;
  }
}

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF326CE5), brightness: b); // k8s blue
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF111318) : null,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1, thickness: 1),
    inputDecorationTheme: const InputDecorationTheme(isDense: true, border: OutlineInputBorder()),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}
