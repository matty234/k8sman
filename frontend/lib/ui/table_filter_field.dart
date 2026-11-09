/// The resource table's filter box: live filtering plus a suggestions list
/// that helps compose queries (fields, then the values seen in that column).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/table_controller.dart';
import '../state/table_query.dart';
import 'theme.dart';

class TableFilterField extends StatefulWidget {
  final TableController controller;
  const TableFilterField({super.key, required this.controller});

  @override
  State<TableFilterField> createState() => _TableFilterFieldState();
}

class _TableFilterFieldState extends State<TableFilterField> {
  late final _text = TextEditingController(text: widget.controller.filter);
  FocusNode get _focus => widget.controller.filterFocus;
  List<FilterSuggestion> _shown = const [];

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  /// `/` (or a click) into the box selects its text, ready to retype.
  void _onFocus() {
    if (_focus.hasFocus) _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _text.dispose();
    super.dispose();
  }

  List<FilterSuggestion> _options(TextEditingValue v) {
    final tc = widget.controller;
    // Only complete at the end of the text.
    final atEnd = !v.selection.isValid || v.selection.baseOffset >= v.text.length;
    _shown = !atEnd || tc.columns.isEmpty
        ? const []
        : filterSuggestions(v.text, tc.columns, tc.allRows, namespaced: tc.type.namespaced);
    return _shown;
  }

  void _picked(FilterSuggestion s) {
    widget.controller.setFilter(s.result);
    // Keep typing after the pick (RawAutocomplete leaves the caret at the end).
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? regexErrorOf(String t) => t.contains('/') && widget.controller.columns.isNotEmpty ? TableQuery.parse(t, widget.controller.columns).error : null;
    return RawAutocomplete<FilterSuggestion>(
      textEditingController: _text,
      focusNode: _focus,
      optionsBuilder: _options,
      displayStringForOption: (s) => s.result,
      onSelected: _picked,
      fieldViewBuilder: (context, text, focus, onSubmitted) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        // Tab takes the highlighted suggestion, like Enter.
        onKeyEvent: (_, e) {
          // Esc with no suggestions open hands focus back to the table; with
          // some open, the first Esc just closes them.
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && focus.hasFocus) {
            if (_shown.isEmpty) {
              widget.controller.bodyFocus.requestFocus();
              return KeyEventResult.handled;
            }
            _shown = const [];
            return KeyEventResult.ignored;
          }
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.tab && _shown.isNotEmpty && focus.hasFocus && !HardwareKeyboard.instance.isShiftPressed) {
            onSubmitted();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ListenableBuilder(
          listenable: text,
          builder: (context, _) => _field(theme, text, focus, onSubmitted, regexErrorOf(text.text)),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => _SuggestionList(options: options.toList(), onSelected: onSelected),
    );
  }

  Widget _field(ThemeData theme, TextEditingController text, FocusNode focus, VoidCallback onSubmitted, String? regexError) {
    return TextField(
          key: const ValueKey('table-filter'),
          controller: text,
          focusNode: focus,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 15),
            // Short so it fits; the syntax (status=…, !text, /regex/) is in the
            // suggestions list and the ? help.
            hintText: 'Filter',
            enabledBorder: regexError == null ? null : OutlineInputBorder(borderSide: BorderSide(color: theme.colorScheme.error)),
            focusedBorder: regexError == null ? null : OutlineInputBorder(borderSide: BorderSide(color: theme.colorScheme.error, width: 2)),
            // The regex error (if any), then a clear button once there's text.
            suffixIcon: text.text.isEmpty && regexError == null
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (regexError != null)
                      Tooltip(message: 'Invalid regex: $regexError', child: Icon(Icons.error_outline, size: 15, color: theme.colorScheme.error)),
                    if (text.text.isNotEmpty)
                      Tooltip(
                        message: 'Clear filter',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            key: const ValueKey('table-filter-clear'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              text.clear();
                              widget.controller.setFilter('');
                              focus.requestFocus();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.cancel, size: 14, color: theme.hintColor),
                            ),
                          ),
                        ),
                      ),
                  ]),
          ),
          style: theme.textTheme.bodyMedium,
          onChanged: widget.controller.setFilter,
          onSubmitted: (_) {
            if (_shown.isEmpty) widget.controller.bodyFocus.requestFocus();
            onSubmitted();
          },
        );
  }
}

class _SuggestionList extends StatelessWidget {
  final List<FilterSuggestion> options;
  final ValueChanged<FilterSuggestion> onSelected;
  const _SuggestionList({required this.options, required this.onSelected});

  static const _help = 'Terms combine: status=running restarts>0 · !text or != excludes · /regex/ · quote "two words"';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final highlighted = AutocompleteHighlightedOption.of(context);
    final mono = monoStyle(context, size: 12);
    // Wider than the field (which sits at the window's right edge), so it
    // grows leftwards from the field's right edge.
    return OverflowBox(
      alignment: Alignment.topRight,
      minWidth: 0,
      maxWidth: 380,
      minHeight: 0,
      maxHeight: 340,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Material(
          key: const ValueKey('filter-suggestions'),
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: theme.dividerColor)),
          color: theme.colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, minWidth: 380, maxHeight: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, i) {
                      final o = options[i];
                      final on = i == highlighted;
                      if (on) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!context.mounted) return;
                          // Scroll only as far as needed (centring could
                          // push the first row under the top edge).
                          final pos = Scrollable.maybeOf(context)?.position;
                          if (i == 0) {
                            pos?.jumpTo(pos.minScrollExtent);
                          } else {
                            Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
                            Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
                          }
                        });
                      }
                      return InkWell(
                        onTap: () => onSelected(o),
                        child: Container(
                          color: on ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Row(
                            children: [
                              Expanded(child: Text(o.label, style: mono, overflow: TextOverflow.ellipsis, maxLines: 1)),
                              if (o.detail != null) ...[
                                const SizedBox(width: 12),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 170),
                                  child: Text(o.detail!, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
                  child: Text(_help, style: theme.textTheme.labelSmall?.copyWith(color: colors.faint)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
