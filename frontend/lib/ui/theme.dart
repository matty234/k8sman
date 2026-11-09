import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../util/k8s.dart';

/// The macOS system font (SF Pro). On macOS the engine resolves this name to
/// the system UI font; tests register SFNS.ttf under the same family name.
const uiFamily = '.AppleSystemUIFont';

/// Resolves glyphs SF lacks (arrows such as ↻ ⇄, box drawing, misc symbols).
/// The Segoe fonts are the Windows equivalents (absent on macOS), then
/// common Linux UI fonts.
const uiFallback = [
  'Apple Symbols', 'Menlo', 'Apple Color Emoji', 'Segoe UI', 'Segoe UI Symbol', 'Segoe UI Emoji', //
  'Inter', 'Cantarell', 'Ubuntu', 'Noto Sans', 'DejaVu Sans', 'Noto Color Emoji',
];

const monoFamily = 'Menlo';

/// Cascadia Mono / Consolas stand in for Menlo on Windows (before Courier
/// New, which Windows also has), then common Linux monospace fonts.
const monoFallback = [
  'SF Mono', 'Monaco', 'Apple Symbols', '.AppleSystemUIFont', 'Cascadia Mono', 'Consolas', //
  'JetBrains Mono', 'Ubuntu Mono', 'DejaVu Sans Mono', 'Noto Sans Mono', 'Liberation Mono', 'Courier New', 'monospace',
];

/// True when running as the real macOS app, where the window has a
/// transparent unified titlebar and a vibrant sidebar (see
/// `macos/Runner/MainFlutterWindow.swift`).
bool get nativeMacChrome => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Height of the unified titlebar/toolbar row. Traffic lights sit in the
/// first [titlebarHeight] px of the nav column.
const titlebarHeight = 52.0;

TextStyle monoStyle(BuildContext context, {double size = 12, Color? color}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      height: 1.4,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );

/// The outline icon callouts use for [s].
IconData severityIcon(Severity s) => switch (s) {
  Severity.error => Icons.error_outline,
  Severity.warn => Icons.warning_amber_rounded,
  Severity.ok => Icons.check_circle_outline,
  _ => Icons.info_outline,
};

Color severityColor(BuildContext context, Severity s) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (s) {
    case Severity.ok:
      return dark ? const Color(0xFF4CC38A) : const Color(0xFF1E8E4E);
    case Severity.warn:
      return dark ? const Color(0xFFE9B04A) : const Color(0xFFB26A00);
    case Severity.error:
      return dark ? const Color(0xFFFF6B61) : const Color(0xFFD1342B);
    case Severity.info:
      return dark ? const Color(0xFF5AA9FF) : const Color(0xFF1767D2);
    case Severity.neutral:
      return Theme.of(context).hintColor;
  }
}

/// Extra surface colours that have no ColorScheme slot.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  /// Left navigation (source list) background.
  final Color sidebar;

  /// Detail inspector background.
  final Color inspector;

  /// Row hover highlight.
  final Color hover;

  /// Table / list selection (macOS source-list style).
  final Color selection;

  /// Subtle alternating-row tint.
  final Color stripe;

  /// Hairline separators.
  final Color separator;

  /// Tertiary (dimmest) text.
  final Color faint;

  const AppColors({
    required this.sidebar,
    required this.inspector,
    required this.hover,
    required this.selection,
    required this.stripe,
    required this.separator,
    required this.faint,
  });

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({Color? sidebar, Color? inspector, Color? hover, Color? selection, Color? stripe, Color? separator, Color? faint}) => AppColors(
        sidebar: sidebar ?? this.sidebar,
        inspector: inspector ?? this.inspector,
        hover: hover ?? this.hover,
        selection: selection ?? this.selection,
        stripe: stripe ?? this.stripe,
        separator: separator ?? this.separator,
        faint: faint ?? this.faint,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      inspector: Color.lerp(inspector, other.inspector, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      stripe: Color.lerp(stripe, other.stripe, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
    );
  }
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;

  // One accent (macOS system blue) on calm, slightly cool neutrals.
  final accent = dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  final canvas = dark ? const Color(0xFF1B1C1F) : const Color(0xFFFFFFFF);
  final text = dark ? const Color(0xFFE6E6E9) : const Color(0xFF1D1D1F);
  final secondaryText = dark ? const Color(0xFF9A9BA2) : const Color(0xFF6E6E73);
  final separator = dark ? const Color(0xFF2C2D31) : const Color(0xFFE4E4E7);

  final colors = AppColors(
    sidebar: dark ? const Color(0xFF232428) : const Color(0xFFF1F1F3),
    inspector: dark ? const Color(0xFF1F2023) : const Color(0xFFFBFBFC),
    hover: dark ? const Color(0x0DFFFFFF) : const Color(0x0A000000),
    selection: accent.withValues(alpha: dark ? 0.30 : 0.16),
    stripe: dark ? const Color(0x06FFFFFF) : const Color(0x05000000),
    separator: separator,
    faint: dark ? const Color(0xFF6B6C73) : const Color(0xFFA1A1A6),
  );

  final scheme = ColorScheme(
    brightness: b,
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF16365A) : const Color(0xFFDCEAFF),
    onPrimaryContainer: dark ? const Color(0xFFCFE4FF) : const Color(0xFF0A3A7A),
    secondary: accent,
    onSecondary: Colors.white,
    secondaryContainer: dark ? const Color(0xFF34353B) : const Color(0xFFEBEBEF),
    onSecondaryContainer: text,
    tertiary: dark ? const Color(0xFFC89CFF) : const Color(0xFF8040C8),
    onTertiary: Colors.white,
    error: dark ? const Color(0xFFFF6B61) : const Color(0xFFD1342B),
    onError: Colors.white,
    errorContainer: dark ? const Color(0xFF4A1F1D) : const Color(0xFFFDE7E5),
    onErrorContainer: dark ? const Color(0xFFFFD9D5) : const Color(0xFF6E1410),
    surface: canvas,
    onSurface: text,
    onSurfaceVariant: secondaryText,
    surfaceContainerLowest: colors.sidebar,
    surfaceContainerLow: dark ? const Color(0xFF222327) : const Color(0xFFF7F7F8),
    surfaceContainer: dark ? const Color(0xFF26272B) : const Color(0xFFF2F2F4),
    surfaceContainerHigh: dark ? const Color(0xFF2C2D32) : const Color(0xFFECECEF),
    surfaceContainerHighest: dark ? const Color(0xFF323338) : const Color(0xFFE6E6EA),
    outline: dark ? const Color(0xFF4A4B52) : const Color(0xFFC7C7CC),
    outlineVariant: separator,
    shadow: Colors.black,
    inverseSurface: dark ? const Color(0xFFE6E6E9) : const Color(0xFF2A2B2F),
    onInverseSurface: dark ? const Color(0xFF1B1C1F) : const Color(0xFFF2F2F4),
    inversePrimary: dark ? const Color(0xFF0060DF) : const Color(0xFF5AA9FF),
    surfaceTint: Colors.transparent,
  );

  // macOS type scale: 13 body, 11–12 secondary. No Material tracking.
  TextStyle t(double size, [FontWeight w = FontWeight.w400, double? height]) =>
      TextStyle(fontFamily: uiFamily, fontFamilyFallback: uiFallback, fontSize: size, fontWeight: w, height: height, letterSpacing: 0, color: text);
  final textTheme = TextTheme(
    displayLarge: t(34, FontWeight.w600),
    displayMedium: t(28, FontWeight.w600),
    displaySmall: t(24, FontWeight.w600),
    headlineLarge: t(22, FontWeight.w600),
    headlineMedium: t(20, FontWeight.w600),
    headlineSmall: t(18, FontWeight.w600),
    titleLarge: t(15, FontWeight.w600, 1.25),
    titleMedium: t(14, FontWeight.w600, 1.3),
    titleSmall: t(13, FontWeight.w600, 1.3),
    bodyLarge: t(14, FontWeight.w400, 1.4),
    bodyMedium: t(13, FontWeight.w400, 1.38),
    bodySmall: t(12, FontWeight.w400, 1.38),
    labelLarge: t(13, FontWeight.w500),
    labelMedium: t(12, FontWeight.w500),
    labelSmall: t(11, FontWeight.w500),
  );

  final radius6 = BorderRadius.circular(6);
  final fieldBorder = OutlineInputBorder(borderRadius: radius6, borderSide: BorderSide.none);
  final compactButton = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius6)),
    textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
    iconSize: const WidgetStatePropertyAll(15),
    splashFactory: NoSplash.splashFactory,
    overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
        ? text.withValues(alpha: 0.10)
        : s.contains(WidgetState.hovered)
            ? text.withValues(alpha: 0.06)
            : null),
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: b,
    fontFamily: uiFamily,
    fontFamilyFallback: uiFallback,
    textTheme: textTheme,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: colors.hover,
    focusColor: accent.withValues(alpha: 0.18),
    hintColor: secondaryText,
    dividerColor: separator,
    canvasColor: canvas,
    scaffoldBackgroundColor: canvas,
    extensions: [colors],
    dividerTheme: DividerThemeData(color: separator, space: 1, thickness: 1),
    iconTheme: IconThemeData(size: 16, color: secondaryText),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? const Color(0x14FFFFFF) : const Color(0x0D000000),
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      hintStyle: textTheme.bodyMedium?.copyWith(color: colors.faint),
      labelStyle: textTheme.bodySmall?.copyWith(color: secondaryText),
      floatingLabelStyle: textTheme.bodySmall?.copyWith(color: secondaryText),
      prefixIconColor: secondaryText,
      prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 26),
      suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 26),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      // macOS-style focus ring.
      focusedBorder: OutlineInputBorder(borderRadius: radius6, borderSide: BorderSide(color: accent.withValues(alpha: 0.7), width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: radius6, borderSide: BorderSide(color: scheme.error.withValues(alpha: 0.7))),
      focusedErrorBorder: OutlineInputBorder(borderRadius: radius6, borderSide: BorderSide(color: scheme.error, width: 2)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.35),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        // A fixed square, whatever density a call site asks for: compact
        // density squashed the height (26×18) into a flat hover rectangle.
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        iconSize: const WidgetStatePropertyAll(16),
        minimumSize: const WidgetStatePropertyAll(Size(26, 26)),
        fixedSize: const WidgetStatePropertyAll(Size.square(26)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius6)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? colors.faint : secondaryText),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
            ? text.withValues(alpha: 0.12)
            : s.contains(WidgetState.hovered)
                ? text.withValues(alpha: 0.07)
                : null),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: compactButton.copyWith(
        foregroundColor: WidgetStatePropertyAll(accent),
        backgroundBuilder: _pushButton(dark, _Push.secondary),
        foregroundBuilder: _pushLabel(text),
      ),
    ),
    // Toolbars and panels: quiet tinted fills, no borders. Dialog footers:
    // native push buttons (see [_pushButton]).
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: compactButton.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? colors.faint : text),
        backgroundColor: _tint(text, dark, rest: (0.05, 0.07), hover: (0.08, 0.11), press: (0.12, 0.16)),
        side: const WidgetStatePropertyAll(BorderSide.none),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundBuilder: _pushButton(dark, _Push.secondary),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: compactButton.copyWith(
        backgroundColor: _tint(accent, dark, rest: (0.13, 0.20), hover: (0.19, 0.27), press: (0.25, 0.34)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => _tintText(accent, dark).withValues(alpha: s.contains(WidgetState.disabled) ? 0.45 : 1)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundBuilder: _pushButton(dark, _Push.primary),
        foregroundBuilder: _pushLabel(Colors.white),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: compactButton.copyWith(elevation: const WidgetStatePropertyAll(0))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: compactButton.copyWith(
        side: WidgetStatePropertyAll(BorderSide(color: separator)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.surfaceContainerHighest : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? text : secondaryText),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: text,
      unselectedLabelColor: secondaryText,
      labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: textTheme.labelLarge,
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(borderSide: BorderSide(color: accent, width: 2), borderRadius: BorderRadius.circular(1)),
      dividerColor: separator,
      dividerHeight: 1,
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tabAlignment: TabAlignment.start,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle: textTheme.labelSmall?.copyWith(color: dark ? const Color(0xFFE6E6E9) : const Color(0xFF1D1D1F), fontWeight: FontWeight.w400),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2E2F34) : const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: dark ? const Color(0x24FFFFFF) : const Color(0x1F000000), width: 0.5),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF2A2B30) : const Color(0xFFFBFBFC),
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: dark ? const Color(0x1FFFFFFF) : const Color(0x1A000000), width: 0.5),
      ),
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(dark ? const Color(0xFF2A2B30) : const Color(0xFFFBFBFC)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: textTheme.bodyMedium),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF232428) : const Color(0xFFFBFBFC),
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: dark ? const Color(0x1FFFFFFF) : const Color(0x14000000), width: 0.5),
      ),
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: separator)),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      minLeadingWidth: 20,
      horizontalTitleGap: 8,
      shape: RoundedRectangleBorder(borderRadius: radius6),
      titleTextStyle: textTheme.bodyMedium,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: secondaryText),
      selectedColor: text,
      selectedTileColor: colors.selection,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.secondaryContainer,
      side: BorderSide.none,
      labelStyle: textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : scheme.surfaceContainerHighest),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      splashRadius: 0,
    ),
    checkboxTheme: CheckboxThemeData(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      splashRadius: 0,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
      strokeWidth: 2,
      linearMinHeight: 4,
      borderRadius: BorderRadius.circular(2),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(text.withValues(alpha: 0.25)),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF34353B) : const Color(0xFF2A2B2F),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      width: 360,
      elevation: 6,
    ),
    badgeTheme: BadgeThemeData(backgroundColor: accent),
  );
}

/// App-wide scrolling: no rubber-band bounce or overscroll glow/stretch, and
/// views whose content fits don't scroll at all (macOS defaults to bouncing,
/// always-scrollable physics, which feels jarring in a dense desktop tool).
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const ClampingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// A tinted fill per state, with (light, dark) alphas.
WidgetStateProperty<Color> _tint(Color c, bool dark, {required (double, double) rest, required (double, double) hover, required (double, double) press}) =>
    WidgetStateProperty.resolveWith((s) {
      final a = s.contains(WidgetState.disabled)
          ? rest
          : s.contains(WidgetState.pressed)
              ? press
              : s.contains(WidgetState.hovered)
                  ? hover
                  : rest;
      return c.withValues(alpha: (dark ? a.$2 : a.$1) * (s.contains(WidgetState.disabled) ? 0.6 : 1));
    });

/// Text on a tinted fill: the colour, a step darker (light) or lighter (dark).
Color _tintText(Color c, bool dark) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness + (dark ? 0.16 : -0.09)).clamp(0.0, 1.0)).toColor();
}

enum _Push { secondary, primary, destructive }

/// Whether a button sits in a dialog's action row (AlertDialog lays its
/// actions out in an [OverflowBar]).
bool _inDialogActions(BuildContext context) =>
    context.findAncestorWidgetOfExactType<OverflowBar>() != null && context.findAncestorWidgetOfExactType<Dialog>() != null;

/// In dialog footers, paints a macOS push button over the tinted fill: a
/// soft shadow ring for secondary buttons, a gently graded fill for the
/// default (and destructive) one. Elsewhere the tinted fill shows as is.
ButtonLayerBuilder _pushButton(bool dark, _Push kind) => (context, states, child) {
      if (child == null || !_inDialogActions(context)) return child ?? const SizedBox.shrink();
      final pressed = states.contains(WidgetState.pressed);
      final disabled = states.contains(WidgetState.disabled);
      final List<Color> fill;
      final Color ring;
      switch (kind) {
        case _Push.secondary:
          final c = dark ? (pressed ? const Color(0xFF6A6B70) : const Color(0xFF5A5B60)) : (pressed ? const Color(0xFFEDEDED) : Colors.white);
          fill = [c, c];
          ring = Colors.black.withValues(alpha: dark ? 0.5 : 0.18);
        case _Push.primary:
          fill = pressed ? const [Color(0xFF2A88EE), Color(0xFF0068D6)] : const [Color(0xFF3B9BFF), Color(0xFF0A7CF4)];
          ring = const Color(0x59003CA0);
        case _Push.destructive:
          fill = pressed ? const [Color(0xFFEE5249), Color(0xFFD92B22)] : const [Color(0xFFFF6259), Color(0xFFF13A30)];
          ring = const Color(0x59961408);
      }
      final a = disabled ? 0.45 : 1.0;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [for (final c in fill) c.withValues(alpha: c.a * a)]),
          border: Border.all(color: ring.withValues(alpha: ring.a * a), width: 0.5),
          boxShadow: disabled ? null : [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.3 : 0.14), offset: const Offset(0, 0.5), blurRadius: 1.5)],
        ),
        child: child,
      );
    };

/// The label colour of a push button in a dialog footer: white on filled
/// ones, the text colour on secondary ones (text buttons become push buttons).
ButtonLayerBuilder _pushLabel(Color base) => (context, states, child) {
      if (child == null || !_inDialogActions(context)) return child ?? const SizedBox.shrink();
      final color = base.withValues(alpha: states.contains(WidgetState.disabled) ? 0.6 : 1);
      return IconTheme.merge(data: IconThemeData(color: color), child: DefaultTextStyle.merge(style: TextStyle(color: color), child: child));
    };

/// For a destructive [FilledButton] (Delete, Drain…): a soft red tint, or a
/// red push button in a dialog footer.
ButtonStyle destructiveButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  final red = theme.colorScheme.error;
  return ButtonStyle(
    backgroundColor: _tint(red, dark, rest: (0.10, 0.15), hover: (0.15, 0.21), press: (0.21, 0.28)),
    foregroundColor: WidgetStateProperty.resolveWith((s) => _tintText(red, dark).withValues(alpha: s.contains(WidgetState.disabled) ? 0.45 : 1)),
    backgroundBuilder: _pushButton(dark, _Push.destructive),
    foregroundBuilder: _pushLabel(Colors.white),
  );
}
