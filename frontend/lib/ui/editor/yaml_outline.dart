import 'dart:typed_data';
import 'dart:ui' show TextRange;

import 'package:re_editor/re_editor.dart';

/// The block structure of YAML text, from indentation alone: which line
/// opens the block each line sits in, and where each block ends. Cheap
/// (one pass, no parsing), so it is rebuilt whenever the text changes and
/// drives folding, the sticky key header and key paths.
///
/// A sequence item (`- …`) counts as half a level deeper than its own
/// indentation, so `containers:` followed by `- name: web` at the same
/// column (how Kubernetes serialises lists) still nests. Blank and comment
/// lines don't open or close blocks; a comment indented deeper than the
/// block it sits in (or a `#` line in a block scalar) stays inside it.
class YamlOutline {
  /// The opening line of the innermost block each line sits in, or -1.
  final Int32List parent;

  /// The end (exclusive) of the block each line opens; `i + 1` when it
  /// opens none. Trailing blank lines stay outside the block.
  final Int32List end;

  YamlOutline._(this.parent, this.end);

  factory YamlOutline.of(List<String> lines) {
    final n = lines.length;
    final parent = Int32List(n), end = Int32List(n), level = Int32List(n);
    final stack = <int>[];
    var last = -1;
    var scalar = -1; // indentation of the line opening a block scalar (`key: |`)
    for (var i = 0; i < n; i++) {
      end[i] = i + 1;
      var lv = _level(lines[i]);
      // In a block scalar a `#` line is text, not a comment.
      if (lv < -1 && scalar >= 0 && (-2 - lv) ~/ 2 > scalar) lv = -2 - lv;
      if (lv < 0) {
        parent[i] = stack.isEmpty ? -1 : stack.last;
        if (lv < -1 && stack.isNotEmpty && -2 - lv > level[stack.last]) last = i;
        continue;
      }
      while (stack.isNotEmpty && level[stack.last] >= lv) {
        end[stack.removeLast()] = last + 1;
      }
      parent[i] = stack.isEmpty ? -1 : stack.last;
      level[i] = lv;
      stack.add(i);
      last = i;
      if (scalar >= 0 && lv ~/ 2 <= scalar) scalar = -1;
      if (scalar < 0 && _scalarRe.hasMatch(lines[i])) scalar = lv ~/ 2;
    }
    for (final i in stack) {
      end[i] = last + 1;
    }
    return YamlOutline._(parent, end);
  }

  int get length => end.length;

  bool canFold(int i) => end[i] > i + 1;

  /// The blocks [line] sits in, outermost first. Blank lines between two
  /// blocks belong to neither.
  List<int> ancestors(int line) {
    final out = <int>[];
    for (var p = parent[line]; p >= 0; p = parent[p]) {
      if (end[p] > line) out.add(p);
    }
    return out.reversed.toList();
  }

  /// The key path of [line], e.g. `spec.template.spec.containers[0].image`.
  String path(List<String> lines, int line) {
    final sb = StringBuffer();
    final chain = [...ancestors(line), line];
    for (var k = 0; k < chain.length; k++) {
      final i = chain[k];
      final text = lines[i];
      var rest = text.trimLeft();
      if (_isItem(rest)) {
        var index = 0;
        for (var j = parent[i] + 1; j < i; j++) {
          if (parent[j] == parent[i] && _isItem(lines[j].trimLeft())) index++;
        }
        sb.write('[$index]');
        // An item's first key is the item's own, not an ancestor's.
        if (k < chain.length - 1) continue;
        rest = rest.substring(1).trimLeft();
      }
      final key = yamlKey(rest);
      if (key == null) continue;
      if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) {
        sb.write(sb.isEmpty ? key : '.$key');
      } else {
        sb.write('["$key"]');
      }
    }
    return sb.toString();
  }

  static final _keyRe = RegExp(r'''^("[^"]*"|'[^']*'|[^\s#'"][^#]*?)\s*:(\s|$)''');

  /// The mapping key [s] (already left-trimmed) starts with, unquoted.
  static String? yamlKey(String s) {
    final m = _keyRe.firstMatch(s);
    if (m == null) return null;
    final k = m.group(1)!;
    return (k.startsWith('"') || k.startsWith("'")) ? k.substring(1, k.length - 1) : k;
  }

  static final _scalarRe = RegExp(r'(:|^\s*-)\s+[|>][-+0-9]*\s*(#.*)?$');

  static bool _isItem(String trimmed) => trimmed == '-' || trimmed.startsWith('- ');

  /// Twice the indentation, plus one for a sequence item; -1 for a blank
  /// line, and -2 minus twice the indentation for a comment.
  static int _level(String s) {
    var n = 0;
    while (n < s.length && s.codeUnitAt(n) == 0x20) {
      n++;
    }
    if (n == s.length) return -1;
    if (s.codeUnitAt(n) == 0x23) return -2 - n * 2;
    final item = s.codeUnitAt(n) == 0x2D && (n + 1 == s.length || s.codeUnitAt(n + 1) == 0x20);
    return n * 2 + (item ? 1 : 0);
  }
}

/// Folding regions for re_editor from [YamlOutline]. Runs on the editor's
/// background isolate; a folded line reports an empty region so the editor
/// keeps it folded.
class YamlChunkAnalyzer implements CodeChunkAnalyzer {
  const YamlChunkAnalyzer();

  @override
  List<CodeChunk> run(CodeLines codeLines) {
    final lines = codeLines.toList();
    final o = YamlOutline.of([for (final l in lines) l.text]);
    return [
      for (var i = 0; i < lines.length; i++)
        if (o.canFold(i) || lines[i].chunkParent) CodeChunk(i, o.end[i]),
    ];
  }
}

/// The editor's lines unfolded, with the real indexes of the folded ones.
({List<CodeLine> lines, Set<int> folded}) flattenFolds(CodeLines codeLines) {
  final lines = <CodeLine>[];
  final folded = <int>{};
  void walk(Iterable<CodeLine> ls) {
    for (final l in ls) {
      if (l.chunkParent) {
        folded.add(lines.length);
        lines.add(CodeLine(l.text));
        walk(l.chunks);
      } else {
        lines.add(l);
      }
    }
  }

  walk(codeLines.toList());
  return (lines: lines, folded: folded);
}

/// Sets [controller]'s folds to exactly [folded] (real line indexes) in one
/// change. The selection moves onto a fold line if its line is now hidden.
void applyFolds(CodeLineEditingController controller, List<CodeLine> lines, YamlOutline o, Set<int> folded) {
  final n = lines.length;
  final visOf = List<int>.filled(n, 0);
  final realOf = <int>[];
  List<CodeLine> build(int from, int to) {
    final out = <CodeLine>[];
    var r = from;
    while (r < to) {
      if (folded.contains(r) && o.canFold(r)) {
        out.add(CodeLine(lines[r].text, build(r + 1, o.end[r])));
        r = o.end[r];
      } else {
        out.add(lines[r]);
        r++;
      }
    }
    return out;
  }

  // Visible index of every real line (hidden ones: their outermost fold).
  for (var r = 0; r < n;) {
    final v = realOf.length;
    realOf.add(r);
    visOf[r] = v;
    if (folded.contains(r) && o.canFold(r)) {
      for (var k = r + 1; k < o.end[r]; k++) {
        visOf[k] = v;
      }
      r = o.end[r];
    } else {
      r++;
    }
  }
  final sel = controller.selection;
  ({int index, int offset}) map(int index, int offset) {
    final real = controller.index2lineIndex(index);
    if (real < 0 || real >= n) return (index: 0, offset: 0);
    final v = visOf[real];
    return realOf[v] == real ? (index: v, offset: offset) : (index: v, offset: lines[realOf[v]].length);
  }

  final base = map(sel.baseIndex, sel.baseOffset), extent = map(sel.extentIndex, sel.extentOffset);
  controller.value = controller.value.copyWith(
    codeLines: CodeLines.of(build(0, n)),
    selection: CodeLineSelection(baseIndex: base.index, baseOffset: base.offset, extentIndex: extent.index, extentOffset: extent.offset),
    composing: TextRange.empty,
  );
}
