/// Small text helpers shared across panels and pages. No Flutter imports.
library;

/// "1 pod", "3 pods"; [many] overrides the plural form ("1 policy", "2 policies").
String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

final _safeShellArg = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// POSIX-shell quoting of an argument list into one pasteable line.
String shellJoin(List<dynamic> args) => args.map((a) {
  final s = '$a';
  if (s.isNotEmpty && _safeShellArg.hasMatch(s)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}).join(' ');
