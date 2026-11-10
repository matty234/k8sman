/// Lays a container command out the way a person would write it. No Flutter
/// imports. Quoting is exactly [shellJoin]'s, so the text stays valid shell.
library;

import 'text.dart';

const _width = 80;
const _shells = {'sh', 'bash', 'ash', 'dash', 'zsh'};
final _dashC = RegExp(r'^-[A-Za-z]*c[A-Za-z]*$');

String _q(String a) => shellJoin([a]);

/// [argv] as one line when it fits in about 80 characters, else broken over
/// ` \` continuation lines: the program (with any leading subcommand), then
/// each flag with its value. `sh -c` shows its script with real line breaks.
String formatCommand(List<String> argv) {
  if (argv.isEmpty) return '';
  final one = shellJoin(argv);
  if (one.length <= _width && !one.contains('\n')) return one;
  return _shellScript(argv) ?? _flagged(argv);
}

String? _shellScript(List<String> argv) {
  if (argv.length < 3) return null;
  final c = argv.length - 2;
  if (!_shells.contains(argv.first.split('/').last) || !_dashC.hasMatch(argv[c])) return null;
  for (var i = 1; i < c; i++) {
    if (!argv[i].startsWith('-')) return null;
  }
  final script = argv.last;
  var lines = script.split('\n');
  if (lines.length == 1) {
    if (script.length <= 60) return null;
    lines = _breakChain(script);
    if (lines.length == 1) return null;
  }
  // Inside one pair of single quotes, so it stays one argument: a quote in
  // the script becomes `'\''`, as in shellJoin.
  final body = [for (final l in lines) l.isEmpty ? '' : '  ${l.replaceAll("'", r"'\''")}'];
  return "${shellJoin(argv.sublist(0, c + 1))} '\n${body.join('\n')}\n'";
}

/// Splits one line after each `&&` / `;` outside quotes.
List<String> _breakChain(String s) {
  final out = <String>[];
  var start = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == r'\' && quote == '"') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
    } else if (ch == r'\') {
      i++;
    } else if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == ';' || (ch == '&' && i + 1 < s.length && s[i + 1] == '&')) {
      if (ch == '&') i++;
      out.add(s.substring(start, i + 1).trim());
      start = i + 1;
    }
  }
  final rest = s.substring(start).trim();
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

bool _isFlag(String a) => a.length > 1 && a.startsWith('-') && a != '--';
bool _isPath(String a) => a.startsWith('/') || a.startsWith('./') || a.startsWith('../') || a.startsWith('~');
bool _isStructured(String a) => (a.length > 40 || a.contains('\n')) && (a.startsWith('{') || a.startsWith('[') || (a.contains('\n') && a.contains(': ')));

String _flagged(List<String> argv) {
  final chunks = <String>[];
  var i = 0;
  var head = _q(argv[i++]);
  // Leading subcommands stay with the program: `kubectl get pods`.
  while (i < argv.length && !_isFlag(argv[i]) && argv[i] != '--' && !_isStructured(argv[i])) {
    head += ' ${_q(argv[i++])}';
  }
  chunks.add(head);
  while (i < argv.length) {
    final a = argv[i++];
    if (!_isFlag(a) || a.contains('=') || _isStructured(a)) {
      chunks.add(_q(a));
      continue;
    }
    // A non-flag after a flag is its value; a path after a short flag
    // (`-v /data`, `-rf /tmp`) is left alone since those are often switches.
    final short = !a.startsWith('--');
    if (i < argv.length && !_isFlag(argv[i]) && argv[i] != '--' && !(short && _isPath(argv[i]))) {
      final v = argv[i++];
      if (_isStructured(v)) {
        chunks..add(_q(a))..add(_q(v));
      } else {
        chunks.add('${_q(a)} ${_q(v)}');
      }
    } else {
      chunks.add(_q(a));
    }
  }
  return [
    for (final (n, c) in chunks.indexed) '${n == 0 ? '' : '  '}$c${n == chunks.length - 1 ? '' : ' \\'}',
  ].join('\n');
}
