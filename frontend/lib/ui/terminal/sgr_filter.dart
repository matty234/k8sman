/// Works around parsing gaps in package:xterm 4.0 by rewriting terminal
/// output before it reaches the emulator:
///
/// - `CSI > Ps ; Ps m` (xterm's modifyOtherKeys, sent by Claude Code, vim
///   and others) and other private-prefixed `m` sequences (`CSI ? … m`,
///   `CSI = … m`, `CSI < … m`) aren't styles, but xterm.dart runs them through
///   SGR, so `CSI > 4 ; 2 m` turned underline on for everything after it.
///   They are dropped.
/// - Private prefixes on other commands, which xterm.dart mostly ignores:
///   `CSI ? Pi ; Pa ; Pv S` (a graphics query) scrolled the screen. Prefixed
///   sequences are dropped except where xterm.dart handles the prefix (DEC
///   modes `? h`/`? l`, `? J`/`? K`, `? n`, device attributes `c`).
/// - Colon sub-parameters (ITU T.416 / kitty), which xterm.dart concatenates
///   into one number: `4:0` → `24`, `4:n` → `4` (curly etc. as plain
///   underline), `38:2:[cs]:r:g:b` / `48:…` → `38;2;r;g;b`, `38:5:n` →
///   `38;5;n`. Other colon groups are dropped.
/// - Underline colour (`58;2;r;g;b`, `58;5;n`, `59`), which xterm.dart doesn't
///   know, so it read the colour values as attributes (a 4 = underline).
/// - `22` (normal intensity), which xterm.dart treats as "not dim" only, so
///   everything after bold text stayed bold. It becomes `21;22` (xterm.dart's
///   21 clears bold).
/// - DCS, APC, PM and SOS strings (`ESC P`, `ESC _`, `ESC ^`, `ESC X` … ST),
///   which xterm.dart doesn't recognise, so their contents (tmux/vim
///   capability queries, kitty graphics, sixel) were printed as text. They
///   are dropped, however long, without being buffered.
///
/// Stateful: a sequence split across chunks is held (or, inside a string,
/// keeps being dropped) until it completes.
class SgrFilter {
  String _pending = '';

  /// Inside a DCS/APC/PM/SOS string: dropping until ST (or BEL).
  bool _inString = false;

  /// The last chunk ended on ESC inside a string (maybe the start of ST).
  bool _stringEsc = false;

  static const _esc = 0x1b;

  /// Finals for which xterm.dart honours a `?` prefix; `>`/`=` only on `c`.
  static const _questionOk = {0x68 /* h */, 0x6c /* l */, 0x4a /* J */, 0x4b /* K */, 0x6e /* n */, 0x63 /* c */};

  /// Returns [chunk] with problem sequences rewritten. A trailing incomplete
  /// CSI is held back for the next call.
  String process(String chunk) {
    var s = _pending.isEmpty ? chunk : _pending + chunk;
    _pending = '';
    if (!_inString && !s.contains('\x1b')) return s;
    final out = StringBuffer();
    var i = 0;
    if (_inString) i = _skipString(s, 0);
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c != _esc) {
        out.writeCharCode(c);
        i++;
        continue;
      }
      if (i + 1 >= s.length) {
        _pending = s.substring(i); // lone ESC: the rest comes next chunk
        break;
      }
      final next = s.codeUnitAt(i + 1);
      if (next == 0x50 /* P */ || next == 0x5f /* _ */ || next == 0x5e /* ^ */ || next == 0x58 /* X */) {
        _inString = true;
        i = _skipString(s, i + 2);
        continue;
      }
      if (next != 0x5b /* [ */) {
        out.writeCharCode(c);
        i++;
        continue;
      }
      // CSI: parameter bytes 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
      var j = i + 2;
      while (j < s.length) {
        final b = s.codeUnitAt(j);
        if (b >= 0x40 && b <= 0x7e) break;
        if (b < 0x20 || b > 0x3f) break; // malformed: pass through as is
        j++;
      }
      if (j >= s.length) {
        if (j - i > 64) {
          out.write(s.substring(i)); // runaway: give up holding it
        } else {
          _pending = s.substring(i);
        }
        break;
      }
      final fin = s.codeUnitAt(j);
      final params = s.substring(i + 2, j);
      if (fin == 0x6d /* m */) {
        out.write(_sgr(params));
      } else if (_keepCsi(params, fin)) {
        out.write(s.substring(i, j + 1));
      }
      i = j + 1;
    }
    return out.toString();
  }

  /// Skips string content from [from] to just past its terminator (ST =
  /// ESC \, or BEL). Returns the index to continue at; if the chunk ends
  /// first, the string continues into the next chunk.
  int _skipString(String s, int from) {
    var k = from;
    if (_stringEsc && k < s.length) {
      _stringEsc = false;
      if (s.codeUnitAt(k) == 0x5c /* \ */) {
        _inString = false;
        return k + 1;
      }
    }
    while (k < s.length) {
      final b = s.codeUnitAt(k);
      if (b == 0x07) {
        _inString = false;
        return k + 1;
      }
      if (b == _esc) {
        if (k + 1 >= s.length) {
          _stringEsc = true;
          return s.length;
        }
        if (s.codeUnitAt(k + 1) == 0x5c) {
          _inString = false;
          return k + 2;
        }
      }
      k++;
    }
    return s.length;
  }

  /// Whether a (non-SGR) CSI goes through: unprefixed ones always; private
  /// prefixes only where xterm.dart understands them.
  static bool _keepCsi(String params, int fin) {
    if (params.isEmpty) return true;
    final p = params.codeUnitAt(0);
    if (p < 0x3c || p > 0x3f) return true;
    if (p == 0x3f /* ? */) return _questionOk.contains(fin);
    return fin == 0x63 /* c */; // > c (secondary DA), = c
  }

  /// Rewrites one SGR's parameter string; '' drops the sequence.
  static String _sgr(String params) {
    if (params.isNotEmpty) {
      final p = params.codeUnitAt(0);
      if (p >= 0x3c && p <= 0x3f) return ''; // < = > ? : private, not a style
    }
    final groups = params.split(';');
    final out = <String>[];
    for (var k = 0; k < groups.length; k++) {
      final g = groups[k];
      if (g.contains(':')) {
        final sub = g.split(':');
        switch (sub[0]) {
          case '4':
            out.add(sub.length > 1 && (sub[1] == '0' || sub[1].isEmpty) ? '24' : '4');
          case '38' || '48':
            if (sub.length > 1 && sub[1] == '5' && sub.length >= 3) {
              out.addAll([sub[0], '5', sub[2]]);
            } else if (sub.length > 1 && sub[1] == '2') {
              // 38:2:r:g:b or 38:2:<colourspace>:r:g:b
              final rgb = sub.length >= 6 ? sub.sublist(3, 6) : (sub.length == 5 ? sub.sublist(2, 5) : null);
              if (rgb != null) out.addAll([sub[0], '2', for (final v in rgb) v.isEmpty ? '0' : v]);
            }
          default:
            break; // 58:… and anything else: drop
        }
        continue;
      }
      if (g == '58') {
        // Underline colour in semicolon form: skip its arguments too.
        final mode = k + 1 < groups.length ? groups[k + 1] : '';
        k += mode == '2' ? 4 : (mode == '5' ? 2 : 0);
        continue;
      }
      if (g == '59') continue;
      if (g == '22') {
        // Normal intensity ends bold *and* dim; xterm.dart's 22 only ends
        // dim (its 21 ends bold), so text after a bold run stayed bold.
        out.addAll(['21', '22']);
        continue;
      }
      if (g == '38' || g == '48') {
        // Keep 38;5;n / 38;2;r;g;b intact (their values aren't attributes).
        final mode = k + 1 < groups.length ? groups[k + 1] : '';
        final n = mode == '2' ? 4 : (mode == '5' ? 2 : 0);
        out.addAll(groups.sublist(k, (k + 1 + n).clamp(0, groups.length)));
        k += n;
        continue;
      }
      out.add(g);
    }
    if (out.isEmpty) return params.isEmpty ? '\x1b[m' : '';
    return '\x1b[${out.join(';')}m';
  }
}
