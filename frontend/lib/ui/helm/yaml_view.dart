import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../theme.dart';

/// Syntax-highlighted YAML in the same re_editor setup as the sidebar's
/// YAML tab. Read-only unless [controller] is given and [readOnly] is false.
class HelmYamlView extends StatefulWidget {
  final String text;
  final CodeLineEditingController? controller;
  final bool readOnly;
  const HelmYamlView({super.key, this.text = '', this.controller, this.readOnly = true});

  @override
  State<HelmYamlView> createState() => _HelmYamlViewState();
}

class _HelmYamlViewState extends State<HelmYamlView> {
  CodeLineEditingController? _own;
  final _scroll = CodeScrollController();

  CodeLineEditingController get _controller => widget.controller ?? (_own ??= CodeLineEditingController.fromText(widget.text));

  @override
  void didUpdateWidget(covariant HelmYamlView old) {
    super.didUpdateWidget(old);
    if (widget.controller == null && old.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _own?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final editing = !widget.readOnly;
    return CodeEditor(
      controller: _controller,
      scrollController: _scroll,
      readOnly: widget.readOnly,
      wordWrap: false,
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
        DefaultCodeLineNumber(controller: editingController, notifier: notifier, textStyle: monoStyle(context, size: 11, color: theme.hintColor)),
        DefaultCodeChunkIndicator(width: 16, controller: chunkController, notifier: notifier),
      ]),
    );
  }
}
