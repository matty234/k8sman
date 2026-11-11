import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../../util/k8s.dart';
import '../keys.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'yaml_outline.dart';

/// The YAML code editor shared by the inspector's YAML tab, the
/// full-window resource editor and chart values: highlighting, line
/// numbers, a ⌘F find bar, ⌘/ to toggle comments and optional problem
/// markers in the gutter. Also, as in VS Code:
///
/// * Folding by indentation. Chevrons show in the gutter on hover (always
///   on folded lines); ⌥-click folds or unfolds a block and everything in
///   it. ⌥⌘[ / ⌥⌘] fold and unfold at the cursor. Folds are view state
///   only: the text, copy and find always see every line.
/// * A sticky header of the keys enclosing the top line (up to five);
///   click one to scroll to it.
/// * ⌥⌘C copies the key path at the cursor (`spec.containers[0].image`).
///
/// ⌘S and ⌘↩ aren't handled by the editor itself, so they reach the
/// caller's shortcuts even while the editor has focus.
class YamlCodeEditor extends StatefulWidget {
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

  /// Highlight template placeholders (`${name}`, `${name:default}`).
  final bool placeholders;
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
    this.placeholders = false,
  });

  @override
  State<YamlCodeEditor> createState() => YamlCodeEditorState();
}

class YamlCodeEditorState extends State<YamlCodeEditor> {
  static const _maxSticky = 5;
  static const _foldGutterWidth = 16.0;
  static const _problemGutterWidth = 10.0;
  static const _minNumberCount = 3;

  /// re_editor's default padding inside the border, and its scrollbar.
  static const _editorPadding = 5.0;
  static const _scrollbarWidth = 8.0;
  static final _comments = DefaultCodeCommentFormatter(singleLinePrefix: '#');

  CodeFindController? _ownFind;
  CodeScrollController? _ownScroll;
  CodeFindController get _find => widget.findController ?? (_ownFind ??= CodeFindController(widget.controller));
  CodeScrollController get _scroll => widget.scrollController ?? (_ownScroll ??= CodeScrollController());

  final _gutterHover = ValueNotifier(false);

  /// The editor's line layout. It reports during layout, too late to
  /// rebuild widgets in that frame, so the sticky header takes only the line
  /// height from it (once) and otherwise works from the scroll offset in
  /// the same frame as the editor: line 0 starts at the editor's top padding
  /// (plus the find bar while it is open).
  CodeIndicatorValueNotifier? _layout;
  double? _lineHeight;
  final _geometry = ValueNotifier(0);

  void _onLayout() {
    final ps = _layout?.value?.paragraphs;
    if (ps == null || ps.isEmpty || ps.first.height == _lineHeight) return;
    _lineHeight = ps.first.height;
    SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? _geometry.value++ : null);
  }

  double get _line0 => _editorPadding + _findBarHeight;

  CodeLines? _outlineOf;
  YamlOutline? _outlineCache;

  /// The outline of the visible lines (a folded block is one line),
  /// rebuilt lazily when the text or the folds change.
  YamlOutline get _outline {
    final lines = widget.controller.codeLines;
    if (!identical(lines, _outlineOf) || _outlineCache == null) {
      _outlineOf = lines;
      _outlineCache = YamlOutline.of([for (final l in lines.toList()) l.text]);
    }
    return _outlineCache!;
  }

  @override
  void didUpdateWidget(covariant YamlCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _ownFind?.dispose();
      _ownFind = null;
    }
  }

  @override
  void dispose() {
    _ownFind?.dispose();
    final s = _ownScroll;
    if (s != null) {
      s.dispose();
      // CodeScrollController.dispose() leaves its own two undisposed.
      s.verticalScroller.dispose();
      s.horizontalScroller.dispose();
    }
    _gutterHover.dispose();
    _layout?.removeListener(_onLayout);
    _geometry.dispose();
    super.dispose();
  }

  // ---- Folding ----

  void foldAll() => _refold((o, texts, folded) => folded.addAll([for (var k = 0; k < o.length; k++) if (o.canFold(k)) k]));

  void unfoldAll() => _refold((o, texts, folded) => folded.clear());

  /// Runs [replaceText] (a reload that replaces the whole text) and folds
  /// the same keys again where they still exist.
  void preservingFolds(VoidCallback replaceText) {
    final before = flattenFolds(widget.controller.codeLines);
    if (before.folded.isEmpty) return replaceText();
    final texts = [for (final l in before.lines) l.text];
    final o = YamlOutline.of(texts);
    final paths = {for (final r in before.folded) o.path(texts, r)};
    replaceText();
    _refold((o, texts, folded) {
      for (var k = 0; k < o.length; k++) {
        if (o.canFold(k) && paths.contains(o.path(texts, k))) folded.add(k);
      }
    });
  }

  /// Rewrites the folds in one change: [update] edits the set of folded
  /// real line indexes, given the unfolded text and its outline.
  void _refold(void Function(YamlOutline o, List<String> texts, Set<int> folded) update) {
    final c = widget.controller;
    final flat = flattenFolds(c.codeLines);
    final texts = [for (final l in flat.lines) l.text];
    final o = YamlOutline.of(texts);
    final folded = {...flat.folded};
    update(o, texts, folded);
    if (setEquals(folded, flat.folded)) return;
    applyFolds(c, flat.lines, o, folded);
  }

  /// Folds or unfolds the block [index] (a visible line) opens; with
  /// [recursive], every block inside it too.
  void toggleFold(int index, {bool recursive = false}) {
    final c = widget.controller;
    if (index < 0 || index >= c.codeLines.length) return;
    final folded = c.codeLines[index].chunkParent;
    if (recursive) {
      final r = c.index2lineIndex(index);
      _refold((o, texts, set) {
        for (var k = r; k < o.end[r]; k++) {
          if (folded) {
            set.remove(k);
          } else if (o.canFold(k)) {
            set.add(k);
          }
        }
      });
    } else if (folded) {
      c.expandChunk(index);
    } else if (_outline.canFold(index)) {
      c.collapseChunk(index, _outline.end[index]);
    }
  }

  /// ⌥⌘[: folds the block at the cursor (the line's own, else the one it
  /// sits in).
  void _foldAtCursor() {
    final line = widget.controller.selection.extentIndex;
    final o = _outline;
    if (line < 0 || line >= o.length) return;
    if (o.canFold(line)) return toggleFold(line);
    final up = o.ancestors(line);
    if (up.isNotEmpty) toggleFold(up.last);
  }

  void _unfoldAtCursor() {
    final c = widget.controller;
    final line = c.selection.extentIndex;
    if (line >= 0 && line < c.codeLines.length && c.codeLines[line].chunkParent) c.expandChunk(line);
  }

  void _copyPathAtCursor() {
    final c = widget.controller;
    final line = c.selection.extentIndex;
    final o = _outline;
    if (line < 0 || line >= o.length) return;
    final path = o.path([for (final l in c.codeLines.toList()) l.text], line);
    if (path.isNotEmpty) copyToClipboard(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    SingleActivator alt(LogicalKeyboardKey k) => SingleActivator(k, alt: true, meta: !useCtrlShortcuts, control: useCtrlShortcuts);
    final editor = CodeEditor(
      controller: widget.controller,
      scrollController: _scroll,
      findController: _find,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      wordWrap: false,
      chunkAnalyzer: const YamlChunkAnalyzer(),
      commentFormatter: _comments,
      shortcutsActivatorsBuilder: const _EditorShortcuts(),
      style: CodeEditorStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 12,
        fontHeight: 1.45,
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        cursorColor: theme.colorScheme.primary,
        cursorLineColor: widget.editing ? theme.colorScheme.onSurface.withValues(alpha: 0.04) : Colors.transparent,
        codeTheme: widget.placeholders
            ? CodeHighlightTheme(languages: {'yaml': CodeHighlightThemeMode(mode: _yamlWithPlaceholders)}, theme: {
                ...(dark ? atomOneDarkTheme : atomOneLightTheme),
                'template-variable': TextStyle(
                    color: theme.colorScheme.tertiary, backgroundColor: theme.colorScheme.tertiary.withValues(alpha: 0.16), fontWeight: FontWeight.w600),
              })
            : CodeHighlightTheme(languages: {'yaml': CodeHighlightThemeMode(mode: langYaml)}, theme: dark ? atomOneDarkTheme : atomOneLightTheme),
      ),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: widget.editing ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      indicatorBuilder: (context, editingController, chunkController, notifier) {
        if (!identical(_layout, notifier)) {
          _layout?.removeListener(_onLayout);
          _layout = notifier..addListener(_onLayout);
        }
        return MouseRegion(
          onEnter: (_) => _gutterHover.value = true,
          onExit: (_) => _gutterHover.value = false,
          child: Row(children: [
            if (widget.problemLines.isNotEmpty) _ProblemGutter(controller: editingController, notifier: notifier, lines: widget.problemLines),
            DefaultCodeLineNumber(controller: editingController, notifier: notifier, minNumberCount: _minNumberCount, textStyle: _numberStyle(context)),
            _FoldGutter(
              width: _foldGutterWidth,
              notifier: notifier,
              hover: _gutterHover,
              outline: () => _outline,
              onToggle: (i) => toggleFold(i, recursive: HardwareKeyboard.instance.isAltPressed),
            ),
          ]),
        );
      },
      findBuilder: (context, controller, readOnly) => YamlFindBar(controller: controller),
    );
    return CallbackShortcuts(
      bindings: {
        alt(LogicalKeyboardKey.bracketLeft): _foldAtCursor,
        alt(LogicalKeyboardKey.bracketRight): _unfoldAtCursor,
        alt(LogicalKeyboardKey.keyC): _copyPathAtCursor,
      },
      child: Stack(fit: StackFit.passthrough, children: [
        editor,
        ListenableBuilder(
          listenable: Listenable.merge([_scroll.verticalScroller, _scroll.horizontalScroller, widget.controller, _find, _geometry]),
          builder: (context, _) => _stickyHeader(context),
        ),
      ]),
    );
  }

  TextStyle _numberStyle(BuildContext context) => monoStyle(context, size: 11, color: Theme.of(context).hintColor);

  double get _findBarHeight => _find.value == null ? 0 : YamlFindBar.barHeight;

  /// The enclosing keys of the top line, pinned over the editor's first
  /// rows: one row per level, outermost first (see [YamlOutline.stickyRows]).
  Widget _stickyHeader(BuildContext context) {
    const none = Positioned(left: 0, top: 0, child: SizedBox.shrink());
    final h = _lineHeight;
    if (h == null) return none;
    final v = _scroll.verticalScroller;
    final top0 = _findBarHeight;
    final rows = _outline.stickyRows(scrollY: v.hasClients ? v.offset : 0, lineHeight: h, line0: _line0, top: top0, max: _maxSticky);
    if (rows.isEmpty) return none;

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final c = widget.controller;
    final numStyle = _numberStyle(context);
    final digits = c.lineCount.toString().length;
    final numWidth = (TextPainter(text: TextSpan(text: '0' * (digits < _minNumberCount ? _minNumberCount : digits), style: numStyle), textDirection: TextDirection.ltr)..layout()).width;
    final numbers = (widget.problemLines.isNotEmpty ? _problemGutterWidth : 0) + numWidth;
    final scrollX = _scroll.horizontalScroller.hasClients ? _scroll.horizontalScroller.offset : 0.0;
    final code = dark ? atomOneDarkTheme : atomOneLightTheme;
    final textStyle = TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 12, height: 1.45, color: theme.textTheme.bodyLarge?.color);
    Widget row(int depth, int line) {
      final text = c.codeLines[line].text;
      final trimmed = text.trimLeft();
      final indent = text.substring(0, text.length - trimmed.length);
      final dash = trimmed.startsWith('- ') ? '- ' : '';
      final rest = trimmed.substring(dash.length);
      final keyEnd = YamlOutline.yamlKey(rest) == null ? 0 : rest.indexOf(':') + 1;
      return GestureDetector(
        key: ValueKey('sticky-$line'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _reveal(line, depth),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: h,
            color: theme.colorScheme.surfaceContainerLowest,
            child: Row(children: [
              SizedBox(width: numbers, child: Text('${c.index2lineIndex(line) + 1}', textAlign: TextAlign.right, style: numStyle, textScaler: TextScaler.noScaling)),
              const SizedBox(width: _foldGutterWidth),
              Expanded(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    maxWidth: double.infinity,
                    child: Transform.translate(
                      offset: Offset(_editorPadding - scrollX, 0),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: indent),
                          if (dash.isNotEmpty) TextSpan(text: dash, style: code['bullet']),
                          TextSpan(text: rest.substring(0, keyEnd), style: code['attr']),
                          TextSpan(text: rest.substring(keyEnd)),
                        ]),
                        style: textStyle,
                        maxLines: 1,
                        softWrap: false,
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    // Each row sits in its slot, less its slide; deeper rows are painted
    // first so a sliding row passes behind the one above it.
    return Positioned(
      top: 1 + top0,
      left: 1,
      right: 1 + _scrollbarWidth,
      height: rows.length * h + rows.last.shift,
      // A visual copy of lines the editor already exposes.
      child: ExcludeSemantics(child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08), blurRadius: 4, offset: const Offset(0, 1))],
        ),
        child: ClipRect(
          child: Stack(children: [
            for (var d = rows.length - 1; d >= 0; d--)
              Positioned(left: 0, right: 0, top: d * h + rows[d].shift, height: h, child: row(d, rows[d].line)),
          ]),
        ),
      )),
    );
  }

  /// Scrolls [line] to just under its [depth] sticky ancestors and puts the
  /// cursor on it.
  void _reveal(int line, int depth) {
    final v = _scroll.verticalScroller;
    final h = _lineHeight;
    if (!v.hasClients || h == null) return;
    v.jumpTo((_line0 + (line - depth) * h - _findBarHeight).clamp(0.0, v.position.maxScrollExtent));
    final text = widget.controller.codeLines[line].text;
    widget.controller.selection = CodeLineSelection.collapsed(index: line, offset: text.length - text.trimLeft().length);
  }
}

/// Fold chevrons: on every foldable line while the pointer is over the
/// gutter, and always on folded lines. Painted, not built: the line layout
/// arrives mid-frame. A click anywhere on a foldable line's row toggles it.
class _FoldGutter extends StatelessWidget {
  final double width;
  final CodeIndicatorValueNotifier notifier;
  final ValueListenable<bool> hover;
  final YamlOutline Function() outline;
  final ValueChanged<int> onToggle;
  const _FoldGutter({required this.width, required this.notifier, required this.hover, required this.outline, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final y = d.localPosition.dy;
        for (final p in notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
          if (y >= p.top && y < p.bottom) {
            final o = outline();
            if (p.chunkParent || (p.index < o.length && o.canFold(p.index))) onToggle(p.index);
            return;
          }
        }
      },
      child: CustomPaint(
        size: Size(width, double.infinity),
        painter: _FoldPainter(notifier: notifier, hover: hover, outline: outline, color: Theme.of(context).hintColor),
      ),
    );
  }
}

class _FoldPainter extends CustomPainter {
  final CodeIndicatorValueNotifier notifier;
  final ValueListenable<bool> hover;
  final YamlOutline Function() outline;
  final Color color;
  _FoldPainter({required this.notifier, required this.hover, required this.outline, required this.color}) : super(repaint: Listenable.merge([notifier, hover]));

  @override
  void paint(Canvas canvas, Size size) {
    final ps = notifier.value?.paragraphs;
    if (ps == null) return;
    final o = outline();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final p in ps) {
      final folded = p.chunkParent;
      if (!folded && !(hover.value && p.index < o.length && o.canFold(p.index))) continue;
      final c = Offset(size.width / 2, p.top + p.height / 2);
      const r = 3.0;
      final path = folded
          ? (Path()
            ..moveTo(c.dx - r / 2, c.dy - r)
            ..lineTo(c.dx + r / 2, c.dy)
            ..lineTo(c.dx - r / 2, c.dy + r))
          : (Path()
            ..moveTo(c.dx - r, c.dy - r / 2)
            ..lineTo(c.dx, c.dy + r / 2)
            ..lineTo(c.dx + r, c.dy - r / 2));
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FoldPainter old) => old.color != color || old.notifier != notifier || old.hover != hover;
}

/// re_editor's default shortcuts plus ⌘] / ⌘[ to indent and outdent (Ctrl
/// on other platforms), as in VS Code and Xcode. Unbound, those keys reach
/// text input and type a bracket or quote.
class IndentShortcuts extends CodeShortcutsActivatorsBuilder {
  const IndentShortcuts();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final base = const DefaultCodeShortcutsActivatorsBuilder().build(type);
    if (type != CodeShortcutType.indent && type != CodeShortcutType.outdent) return base;
    final key = type == CodeShortcutType.indent ? LogicalKeyboardKey.bracketRight : LogicalKeyboardKey.bracketLeft;
    return [...?base, SingleActivator(key, meta: !useCtrlShortcuts, control: useCtrlShortcuts)];
  }
}

/// YAML with template placeholders (`${name}`, `${name:default}`, see
/// resource_templates.dart) as template variables. Listed first, the rule
/// wins over a plain value starting at the same `$`; placeholders inside a
/// quoted or block string aren't marked.
final _yamlWithPlaceholders = Mode(
  refs: langYaml.refs,
  name: 'YAML',
  caseInsensitive: true,
  aliases: const ['yml'],
  contains: <Mode>[
    Mode(className: 'template-variable', begin: r'\$\{[A-Za-z_][A-Za-z0-9_-]*(?::[^}\n]*)?\}'),
    ...(langYaml.contains as List).cast<Mode>(),
  ],
);

/// [IndentShortcuts] minus Save (⌘S) and ⌘↩ (a newline by default), so both
/// bubble up to the full-window editor's own shortcuts.
class _EditorShortcuts extends CodeShortcutsActivatorsBuilder {
  const _EditorShortcuts();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    if (type == CodeShortcutType.save) return null;
    final base = const IndentShortcuts().build(type);
    if (type != CodeShortcutType.newLine || base == null) return base;
    return [
      for (final a in base)
        if (!(a is SingleActivator && (a.meta || a.control) && (a.trigger == LogicalKeyboardKey.enter || a.trigger == LogicalKeyboardKey.numpadEnter))) a,
    ];
  }
}

/// A red dot beside each line in [lines], tracking the editor's scroll.
class _ProblemGutter extends StatelessWidget {
  final CodeLineEditingController controller;
  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  const _ProblemGutter({required this.controller, required this.notifier, required this.lines});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(YamlCodeEditorState._problemGutterWidth, double.infinity),
        painter: _ProblemPainter(controller: controller, notifier: notifier, lines: lines, color: severityColor(context, Severity.error)),
      );
}

/// Painted, as the line layout arrives mid-frame. A folded line gets the
/// dot when any line inside it has a problem.
class _ProblemPainter extends CustomPainter {
  final CodeLineEditingController controller;
  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  final Color color;
  _ProblemPainter({required this.controller, required this.notifier, required this.lines, required this.color}) : super(repaint: notifier);

  @override
  void paint(Canvas canvas, Size size) {
    final ps = notifier.value?.paragraphs;
    if (ps == null || ps.isEmpty) return;
    final paint = Paint()..color = color;
    var real = controller.index2lineIndex(ps.first.index);
    final codeLines = controller.codeLines;
    final n = codeLines.length;
    for (final p in ps) {
      if (p.index >= n) break;
      final count = codeLines[p.index].lineCount;
      if (lines.any((l) => l >= real && l < real + count)) {
        canvas.drawCircle(Offset(6, p.top + p.preferredLineHeight / 2), 3, paint);
      }
      real += count;
    }
  }

  @override
  bool shouldRepaint(covariant _ProblemPainter old) => old.lines != lines || old.color != color || old.notifier != notifier || old.controller != controller;
}

/// Minimal ⌘F find bar for the editor.
class YamlFindBar extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  const YamlFindBar({super.key, required this.controller});

  static const barHeight = 40.0;

  @override
  Size get preferredSize => Size.fromHeight(controller.value == null ? 0 : barHeight);

  @override
  Widget build(BuildContext context) {
    if (controller.value == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final result = controller.value?.result;
    return Container(
      height: barHeight,
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
