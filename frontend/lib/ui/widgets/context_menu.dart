import 'package:flutter/material.dart';

/// Pops [entries] up at [globalPos] (a right-click or tap position) and
/// returns the chosen value. Never animated, like a native menu.
Future<T?> showContextMenuAt<T>(BuildContext context, Offset globalPos, List<PopupMenuEntry<T>> entries, {BoxConstraints? constraints}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future.value();
  final local = overlay.globalToLocal(globalPos);
  return showMenu<T>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(Rect.fromPoints(local, local), Offset.zero & overlay.size),
    constraints: constraints,
    items: entries,
  );
}

/// An icon-plus-label menu row; [shortcut] hints a key at the right, [danger]
/// colours it as destructive.
PopupMenuItem<T> menuItem<T>(T value, IconData icon, String label, {String? shortcut, bool danger = false}) => PopupMenuItem<T>(
      value: value,
      height: 30,
      child: Builder(builder: (context) {
        final theme = Theme.of(context);
        final color = danger ? theme.colorScheme.error : null;
        return Row(children: [
          Icon(icon, size: 15, color: color ?? theme.hintColor),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color))),
          if (shortcut != null) Text(shortcut, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]);
      }),
    );
