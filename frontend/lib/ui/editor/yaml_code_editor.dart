import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../../util/k8s.dart';
import '../theme.dart';

/// The YAML code editor shared by the inspector's YAML tab and the
/// full-window resource editor: highlighting, line numbers, folding, a ⌘F
/// find bar and optional problem markers in the gutter.
///
/// ⌘S and ⌘↩ aren't handled by the editor itself, so they reach the
/// caller's shortcuts even while the editor has focus.
class YamlCodeEditor extends StatelessWidget {
  final CodeLineEditingController controller;
  final CodeScrollController? scrollController;
  final CodeFindController? findController;
  final bool readOnly;

  /// Accent border and cursor-line highlight while editing.
  final bool editing;

  /// 0-based line indexes to mark with a problem dot.
  final Set<int> problemLines;
  final FocusNode? focusNode;
  final bool autofocus;
  const YamlCodeEditor({
    super.key,
    required this.controller,
    this.scrollController,
    this.findController,
    this.readOnly = false,
    this.editing = false,
    this.problemLines = const {},
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return CodeEditor(
      controller: controller,
      scrollController: scrollController,
      findController: findController,
      focusNode: focusNode,
      autofocus: autofocus,
      readOnly: readOnly,
      wordWrap: false,
      shortcutsActivatorsBuilder: const _EditorShortcuts(),
      style: CodeEditorStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 12,
        fontHeight: 1.45,
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        cursorColor: theme.colorScheme.primary,
        cursorLineColor: editing ? theme.colorScheme.onSurface.withValues(alpha: 0.04) : Colors.transparent,
        codeTheme: CodeHighlightTheme(languages: {'yaml': CodeHighlightThemeMode(mode: langYaml)}, theme: dark ? atomOneDarkTheme : atomOneLightTheme),
      ),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: editing ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      indicatorBuilder: (context, editingController, chunkController, notifier) => Row(children: [
        if (problemLines.isNotEmpty) _ProblemGutter(notifier: notifier, lines: problemLines),
        DefaultCodeLineNumber(controller: editingController, notifier: notifier, textStyle: monoStyle(context, size: 11, color: theme.hintColor)),
        DefaultCodeChunkIndicator(width: 16, controller: chunkController, notifier: notifier),
      ]),
      findBuilder: (context, controller, readOnly) => YamlFindBar(controller: controller),
    );
  }
}

/// re_editor's defaults minus Save (⌘S) and ⌘↩ (a newline by default), so
/// both bubble up to the screen's shortcuts.
class _EditorShortcuts extends CodeShortcutsActivatorsBuilder {
  const _EditorShortcuts();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    if (type == CodeShortcutType.save) return null;
    final base = const DefaultCodeShortcutsActivatorsBuilder().build(type);
    if (type != CodeShortcutType.newLine || base == null) return base;
    return [
      for (final a in base)
        if (!(a is SingleActivator && (a.meta || a.control) && (a.trigger == LogicalKeyboardKey.enter || a.trigger == LogicalKeyboardKey.numpadEnter))) a,
    ];
  }
}

/// A red dot beside each line in [lines], tracking the editor's scroll.
class _ProblemGutter extends StatelessWidget {
  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  const _ProblemGutter({required this.notifier, required this.lines});

  @override
  Widget build(BuildContext context) {
    final color = severityColor(context, Severity.error);
    return SizedBox(
      width: 10,
      child: ValueListenableBuilder<CodeIndicatorValue?>(
        valueListenable: notifier,
        builder: (context, value, _) => Stack(clipBehavior: Clip.hardEdge, children: [
          for (final p in value?.paragraphs ?? const <CodeLineRenderParagraph>[])
            if (lines.contains(p.index))
              Positioned(
                left: 3,
                top: p.top + (p.preferredLineHeight - 6) / 2,
                child: Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              ),
        ]),
      ),
    );
  }
}

/// Minimal ⌘F find bar for the editor.
class YamlFindBar extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  const YamlFindBar({super.key, required this.controller});

  @override
  Size get preferredSize => Size.fromHeight(controller.value == null ? 0 : 40);

  @override
  Widget build(BuildContext context) {
    if (controller.value == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final result = controller.value?.result;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: controller.findInputController,
            focusNode: controller.findInputFocusNode,
            style: monoStyle(context),
            decoration: const InputDecoration(hintText: 'Find', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
          ),
        ),
        const SizedBox(width: 8),
        Text(result == null || result.matches.isEmpty ? 'No results' : '${result.index + 1}/${result.matches.length}', style: theme.textTheme.bodySmall),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.keyboard_arrow_up), onPressed: controller.previousMatch),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.keyboard_arrow_down), onPressed: controller.nextMatch),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.close), onPressed: controller.close),
      ]),
    );
  }
}

/// A tinted message strip with optional detail lines, action and close.
class EditorBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  final List<String> details;
  final Widget? action;
  final VoidCallback? onClose;
  final EdgeInsets margin;
  const EditorBanner(this.color, this.icon, this.message,
      {super.key, this.details = const [], this.action, this.onClose, this.margin = const EdgeInsets.fromLTRB(8, 4, 8, 0)});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(message, style: theme.textTheme.bodySmall),
            for (final d in details) Padding(padding: const EdgeInsets.only(top: 2), child: SelectableText('• $d', style: monoStyle(context, size: 11))),
          ]),
        ),
        ?action,
        if (onClose != null) IconButton(visualDensity: VisualDensity.compact, iconSize: 14, icon: const Icon(Icons.close), onPressed: onClose),
      ]),
    );
  }
}
