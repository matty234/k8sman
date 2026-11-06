import 'package:flutter/foundation.dart';

/// Which namespaces a table or page shows: all of them, or a set.
///
/// A set of one is "one namespace" (what the app had before sets).
/// Namespaces are kept sorted, so equal sets compare equal.
@immutable
class NamespaceScope {
  /// The selected namespaces, sorted; empty = all namespaces.
  final List<String> namespaces;

  const NamespaceScope._(this.namespaces);

  static const all = NamespaceScope._([]);

  /// One namespace, or all for null.
  factory NamespaceScope.single(String? namespace) => namespace == null || namespace.isEmpty ? all : NamespaceScope._([namespace]);

  /// A set (empty = all).
  factory NamespaceScope.of(Iterable<String> namespaces) {
    final l = {for (final n in namespaces) if (n.trim().isNotEmpty) n.trim()}.toList()..sort();
    return l.isEmpty ? all : NamespaceScope._(List.unmodifiable(l));
  }

  /// Parses `a,b,c` (as [query] writes it); '' = all.
  factory NamespaceScope.parse(String s) => NamespaceScope.of(s.split(','));

  bool get isAll => namespaces.isEmpty;

  /// Two or more namespaces.
  bool get isMulti => namespaces.length > 1;

  /// The namespace of a one-namespace scope, null otherwise (all, or a set).
  String? get single => namespaces.length == 1 ? namespaces.first : null;

  bool contains(String? ns) => isAll || ns == null || namespaces.contains(ns);

  NamespaceScope toggle(String ns) =>
      namespaces.contains(ns) ? NamespaceScope.of(namespaces.where((n) => n != ns)) : NamespaceScope.of([...namespaces, ns]);

  NamespaceScope add(String ns) => NamespaceScope.of([...namespaces, ns]);
  NamespaceScope remove(String ns) => NamespaceScope.of(namespaces.where((n) => n != ns));

  /// Query parameters for the backend: `namespace=a` for one,
  /// `namespaces=a,b` for a set, nothing for all.
  Map<String, String?> get query => switch (namespaces.length) {
        0 => const {},
        1 => {'namespace': namespaces.first},
        _ => {'namespaces': namespaces.join(',')},
      };

  /// The comma-separated form ('' = all).
  String get asString => namespaces.join(',');

  /// Short label for buttons: `All namespaces`, `team-1`,
  /// `team-1, team-2`, `team-1, team-2 +2`.
  String get label {
    if (isAll) return 'All namespaces';
    if (namespaces.length <= 2) return namespaces.join(', ');
    return '${namespaces.take(2).join(', ')} +${namespaces.length - 2}';
  }

  /// The scope as one string for APIs that take a namespace: null = all,
  /// `a`, or `a,b` for a set (see [namespaceQuery]).
  String? get param => isAll ? null : asString;

  @override
  bool operator ==(Object other) => other is NamespaceScope && listEquals(other.namespaces, namespaces);

  @override
  int get hashCode => Object.hashAll(namespaces);

  @override
  String toString() => isAll ? 'all' : asString;
}

/// Query parameters for a namespace given as [NamespaceScope.param]:
/// `namespace=a`, or `namespaces=a,b` when it holds a set.
Map<String, String?> namespaceQuery(String? ns) => ns != null && ns.contains(',') ? {'namespaces': ns} : {'namespace': ns};
