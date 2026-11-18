/// The icon, colour and display name a user picked for a kube context. [icon]
/// is a stable id from the app's icon set, or `text:PR` for a monogram;
/// [color] a palette id or `#rrggbb`; [label] replaces the name where the
/// context is shown (display only). Empty = the default.
class ContextAppearance {
  final String icon;
  final String color;
  final String label;
  const ContextAppearance({this.icon = '', this.color = '', this.label = ''});

  bool get isDefault => icon.isEmpty && color.isEmpty && label.isEmpty;
  String? get monogram => icon.startsWith('text:') ? icon.substring(5) : null;

  ContextAppearance copyWith({String? icon, String? color, String? label}) =>
      ContextAppearance(icon: icon ?? this.icon, color: color ?? this.color, label: label ?? this.label);

  @override
  bool operator ==(Object other) => other is ContextAppearance && other.icon == icon && other.color == color && other.label == label;

  @override
  int get hashCode => Object.hash(icon, color, label);
}
