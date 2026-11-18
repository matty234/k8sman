// ANSI escape handling for log lines: programs such as pino-pretty, winston
// or Rails colour their output with SGR sequences (`ESC [ 35 m`) even when
// stdout is not a terminal.

const _esc = 0x1B;

/// Whether [s] contains an escape character at all (the cheap pre-check).
bool hasAnsi(String s) => s.contains('\x1b');

/// The SGR state of a run of text. Colours are an index into the 256-colour
/// palette (0-15 the basic and bright colours) or, when >= 0x1000000, a
/// 24-bit `0x1RRGGBB` value; null is the default colour.
class AnsiStyle {
  final int? fg;
  final int? bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  const AnsiStyle({this.fg, this.bg, this.bold = false, this.dim = false, this.italic = false, this.underline = false});

  static const plain = AnsiStyle();

  bool get isPlain => fg == null && bg == null && !bold && !dim && !italic && !underline;
}

/// A half-open [start, end) range of the cleaned text and its style.
typedef AnsiRun = (int start, int end, AnsiStyle style);

/// [s] with every escape sequence removed.
String stripAnsi(String s) => hasAnsi(s) ? parseAnsi(s).$1 : s;

/// Splits [s] into its visible text (escapes removed) and styled runs over
/// that text. SGR sequences set the style; other CSI / OSC / two-byte escapes
/// are dropped. Never throws on truncated input.
(String, List<AnsiRun>) parseAnsi(String s) {
  final out = StringBuffer();
  final runs = <AnsiRun>[];
  int? fg, bg;
  var bold = false, dim = false, italic = false, underline = false;
  var runStart = 0;
  var cur = AnsiStyle.plain;
  final n = s.length;
  var i = 0;
  var lit = 0; // start of the pending literal stretch

  void flushLit(int end) {
    if (end > lit) out.write(s.substring(lit, end));
  }

  void setStyle(AnsiStyle next) {
    final pos = out.length;
    if (pos > runStart) runs.add((runStart, pos, cur));
    runStart = pos;
    cur = next;
  }

  while (i < n) {
    if (s.codeUnitAt(i) != _esc) {
      i++;
      continue;
    }
    flushLit(i);
    if (i + 1 >= n) {
      i = n;
      lit = n;
      break;
    }
    final kind = s.codeUnitAt(i + 1);
    if (kind == 0x5B) {
      // CSI: parameters and intermediates, then a final byte in 0x40-0x7E.
      var j = i + 2;
      while (j < n) {
        final c = s.codeUnitAt(j);
        if (c >= 0x40 && c <= 0x7E) break;
        j++;
      }
      if (j < n && s.codeUnitAt(j) == 0x6D) {
        final ps = s.substring(i + 2, j).split(RegExp('[;:]')).map((p) => p.isEmpty ? 0 : (int.tryParse(p) ?? -1)).toList();
        for (var k = 0; k < ps.length; k++) {
          final p = ps[k];
          if (p == 0) {
            fg = bg = null;
            bold = dim = italic = underline = false;
          } else if (p == 1) {
            bold = true;
          } else if (p == 2) {
            dim = true;
          } else if (p == 3) {
            italic = true;
          } else if (p == 4) {
            underline = true;
          } else if (p == 22) {
            bold = dim = false;
          } else if (p == 23) {
            italic = false;
          } else if (p == 24) {
            underline = false;
          } else if (p >= 30 && p <= 37) {
            fg = p - 30;
          } else if (p >= 90 && p <= 97) {
            fg = p - 90 + 8;
          } else if (p == 39) {
            fg = null;
          } else if (p >= 40 && p <= 47) {
            bg = p - 40;
          } else if (p >= 100 && p <= 107) {
            bg = p - 100 + 8;
          } else if (p == 49) {
            bg = null;
          } else if ((p == 38 || p == 48) && k + 1 < ps.length) {
            int? c;
            if (ps[k + 1] == 5 && k + 2 < ps.length) {
              c = ps[k + 2].clamp(0, 255);
              k += 2;
            } else if (ps[k + 1] == 2 && k + 4 < ps.length) {
              c = 0x1000000 | (ps[k + 2].clamp(0, 255) << 16) | (ps[k + 3].clamp(0, 255) << 8) | ps[k + 4].clamp(0, 255);
              k += 4;
            } else {
              k = ps.length;
            }
            if (p == 38) {
              fg = c;
            } else {
              bg = c;
            }
          }
        }
        setStyle(AnsiStyle(fg: fg, bg: bg, bold: bold, dim: dim, italic: italic, underline: underline));
      }
      i = j < n ? j + 1 : n;
    } else if (kind == 0x5D) {
      // OSC: up to BEL or ESC \.
      var j = i + 2;
      while (j < n) {
        final c = s.codeUnitAt(j);
        if (c == 0x07) {
          j++;
          break;
        }
        if (c == _esc && j + 1 < n && s.codeUnitAt(j + 1) == 0x5C) {
          j += 2;
          break;
        }
        j++;
      }
      i = j;
    } else {
      i += 2;
    }
    lit = i;
  }
  flushLit(n);
  final text = out.toString();
  if (text.length > runStart) runs.add((runStart, text.length, cur));
  return (text, runs);
}
