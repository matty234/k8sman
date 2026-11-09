/// The icon and colour a user picked for a kube context's badge. [icon] is a
/// stable id from the app's icon set, or `text:PR` for a monogram; [color] a
/// palette id or `#rrggbb`. Empty = the default.
class ContextAppearance {
  final String icon;
  final String color;
  const ContextAppearance({this.icon = '', this.color = ''});

  bool get isDefault => icon.isEmpty && color.isEmpty;
  String? get monogram => icon.startsWith('text:') ? icon.substring(5) : null;

  @override
  bool operator ==(Object other) => other is ContextAppearance && other.icon == icon && other.color == color;

  @override
  int get hashCode => Object.hash(icon, color);
}
