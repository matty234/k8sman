/// Building blocks of the Settings page: the searchable [SettingItem]s each
/// section lists, the groups they sit in (a section heading with a hairline,
/// hairlines between rows, nothing boxed), and the row layouts.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/editorial.dart';

/// One setting (or one block of related ones) on the Settings page. The
/// search matches [label], [description] and [keywords].
class SettingItem {
  /// Group heading: consecutive items with the same [group] share a group.
  final String? group;
  final String label;
  final String description;
  final List<String> keywords;
  final WidgetBuilder builder;

  /// Keeps the item's state when the list around it changes (search).
  final Key? key;
  const SettingItem({this.group, required this.label, this.description = '', this.keywords = const [], required this.builder, this.key});

  /// An item drawn as a [SettingRow] of its own label and description.
  factory SettingItem.row({
    Key? key,
    String? group,
    required String label,
    String description = '',
    List<String> keywords = const [],
    WidgetBuilder? leading,
    WidgetBuilder? trailing,
    WidgetBuilder? child,
  }) =>
      SettingItem(
        key: key,
        group: group,
        label: label,
        description: description,
        keywords: keywords,
        builder: (context) => SettingRow(
          label: label,
          description: description,
          leading: leading?.call(context),
          trailing: trailing?.call(context),
          child: child?.call(context),
        ),
      );

  /// Whether every word of [terms] is in the label, description, keywords
  /// or [section] title.
  bool matches(List<String> terms, String section) {
    final hay = [label, description, ...keywords, section].join(' ').toLowerCase();
    return terms.every(hay.contains);
  }
}

/// The words being searched for, so rows can highlight them.
class SettingsSearchTerms extends InheritedWidget {
  final List<String> terms;
  const SettingsSearchTerms({super.key, required this.terms, required super.child});

  static List<String> of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SettingsSearchTerms>()?.terms ?? const [];

  @override
  bool updateShouldNotify(SettingsSearchTerms old) => old.terms.join(' ') != terms.join(' ');
}

/// [text] with the search terms in it marked by a soft accent wash.
class HighlightedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  const HighlightedText(this.text, {super.key, this.style, this.maxLines, this.overflow});

  @override
  Widget build(BuildContext context) {
    final terms = SettingsSearchTerms.of(context);
    if (terms.isEmpty) return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    final theme = Theme.of(context);
    final mark = TextStyle(
      backgroundColor: theme.colorScheme.primary.withValues(alpha: theme.brightness == Brightness.dark ? 0.28 : 0.16),
      color: theme.colorScheme.onSurface,
    );
    // Mark every occurrence of every term (case-insensitive), merging overlaps.
    final lower = text.toLowerCase();
    final marked = List.filled(text.length, false);
    for (final t in terms) {
      for (var i = lower.indexOf(t); i >= 0 && t.isNotEmpty; i = lower.indexOf(t, i + t.length)) {
        for (var k = i; k < i + t.length; k++) {
          marked[k] = true;
        }
      }
    }
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = 1; i <= text.length; i++) {
      if (i == text.length || marked[i] != marked[start]) {
        spans.add(TextSpan(text: text.substring(start, i), style: marked[start] ? mark : null));
        start = i;
      }
    }
    return Text.rich(TextSpan(children: spans), style: style, maxLines: maxLines, overflow: overflow);
  }
}

/// [items] in groups: a section heading (a label with a hairline) over each
/// run of items with the same group, hairlines between the rows.
class SettingCards extends StatelessWidget {
  final List<SettingItem> items;

  /// Draw the group headings (search results go without them).
  final bool headings;
  const SettingCards(this.items, {super.key, this.headings = true});

  @override
  Widget build(BuildContext context) {
    final runs = <(String?, List<SettingItem>)>[];
    for (final i in items) {
      if (runs.isNotEmpty && runs.last.$1 == i.group) {
        runs.last.$2.add(i);
      } else {
        runs.add((i.group, [i]));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, (group, run)) in runs.indexed) ...[
        if (i > 0) SizedBox(height: headings ? 26 : 0),
        if (headings && group != null) SettingsGroupTitle(group),
        SettingsCard(children: [for (final item in run) KeyedSubtree(key: item.key, child: Builder(builder: item.builder))]),
      ],
    ]);
  }
}

/// The heading of a group: the app's section heading, a small semibold
/// label with a hairline running out from it.
class SettingsGroupTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SettingsGroupTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 2), child: SectionHeader(title: title, trailing: trailing));
}

/// A group's rows, open on the page with hairlines between [children].
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // A Material, so list tiles and ink in a module's form paint on it.
    return Material(
      type: MaterialType.transparency,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: colors.separator.withValues(alpha: 0.6)),
          c,
        ],
      ]),
    );
  }
}

/// A setting on one line: label and description on the left, the control
/// ([trailing]) on the right. With [child], a block below spans the width.
class SettingRow extends StatelessWidget {
  final String label;
  final String? description;
  final Widget? trailing;
  final Widget? child;

  /// Before the label (an icon).
  final Widget? leading;
  const SettingRow({super.key, required this.label, this.description, this.trailing, this.child, this.leading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                HighlightedText(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                if (description != null && description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  HighlightedText(description!, style: hint),
                ],
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: 24), trailing!],
          ]),
        ),
        if (child != null) ...[const SizedBox(height: 10), child!],
      ]),
    );
  }
}

/// A switch at the size of a macOS one (Material's is large for a row).
class SettingSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const SettingSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 40,
        height: 24,
        child: FittedBox(child: Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)),
      );
}

/// A small, quiet "nothing here" line inside a group.
class SettingsEmpty extends StatelessWidget {
  final String text;
  const SettingsEmpty(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint)),
      );
}

/// Shows [child] while [open], growing and shrinking into place (at once
/// with reduced motion).
class SettingsReveal extends StatefulWidget {
  final bool open;
  final Widget child;
  const SettingsReveal({super.key, required this.open, required this.child});

  @override
  State<SettingsReveal> createState() => _SettingsRevealState();
}

class _SettingsRevealState extends State<SettingsReveal> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 200), value: widget.open ? 1 : 0);
  late final _curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  @override
  void didUpdateWidget(SettingsReveal old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _c.value = widget.open ? 1 : 0;
    } else {
      widget.open ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_c.value == 0 && !widget.open) return const SizedBox.shrink();
          return ClipRect(
            child: Align(
              alignment: Alignment.topLeft,
              heightFactor: _curve.value,
              child: Opacity(opacity: _curve.value, child: widget.child),
            ),
          );
        },
      );
}
