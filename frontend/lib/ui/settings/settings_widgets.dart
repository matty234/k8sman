/// Building blocks of the Settings page: the searchable [SettingItem]s each
/// section lists, the grouped cards they sit in, and the row layouts.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// One setting (or one block of related ones) on the Settings page. The
/// search matches [label], [description] and [keywords].
class SettingItem {
  /// Card heading: consecutive items with the same [group] share a card.
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

/// [items] laid out as cards: a card per run of items with the same
/// group, its heading above it, hairlines between the rows.
class SettingCards extends StatelessWidget {
  final List<SettingItem> items;
  const SettingCards(this.items, {super.key});

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
        if (i > 0) const SizedBox(height: 20),
        if (group != null) SettingsGroupTitle(group),
        SettingsCard(children: [for (final item in run) KeyedSubtree(key: item.key, child: Builder(builder: item.builder))]),
      ],
    ]);
  }
}

/// The small heading over a card.
class SettingsGroupTitle extends StatelessWidget {
  final String title;
  const SettingsGroupTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
    );
  }
}

/// A rounded, faintly filled box with hairlines between [children].
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // A Material, so list tiles and ink in a module's form paint on it.
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(side: BorderSide(color: colors.separator), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, indent: 14, endIndent: 14, color: colors.separator),
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
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                if (description != null && description!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(description!, style: hint),
                ],
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
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

/// A small, quiet "nothing here" line inside a card.
class SettingsEmpty extends StatelessWidget {
  final String text;
  const SettingsEmpty(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint)),
      );
}
