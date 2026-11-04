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
  final _focus = FocusNode(debugLabel: 'table-filter');
  List<FilterSuggestion> _shown = const [];

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
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
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.tab && _shown.isNotEmpty && focus.hasFocus && !HardwareKeyboard.instance.isShiftPressed) {
            onSubmitted();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          key: const ValueKey('table-filter'),
          controller: text,
          focusNode: focus,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Filter  (or status=…, age<1h)'),
          style: theme.textTheme.bodyMedium,
          onChanged: widget.controller.setFilter,
          onSubmitted: (_) => onSubmitted(),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => _SuggestionList(options: options.toList(), onSelected: onSelected),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  final List<FilterSuggestion> options;
  final ValueChanged<FilterSuggestion> onSelected;
  const _SuggestionList({required this.options, required this.onSelected});

  static const _help = 'Terms combine: status=running restarts>0 · != excludes · quote "two words"';

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
                          if (context.mounted) Scrollable.ensureVisible(context, alignment: 0.5);
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
