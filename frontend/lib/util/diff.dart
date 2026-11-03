/// Minimal line diff (LCS) for reviewing YAML edits before applying.
library;

enum DiffOp { same, add, remove }

class DiffLine {
  final DiffOp op;
  final String text;

  /// 1-based line numbers in the old/new text (null for the other side).
  final int? oldNo;
  final int? newNo;
  const DiffLine(this.op, this.text, {this.oldNo, this.newNo});

  @override
  String toString() => '${op == DiffOp.add ? '+' : op == DiffOp.remove ? '-' : ' '}$text';
}

/// Line diff between [a] and [b]. Common prefix/suffix are trimmed first so
/// typical small edits to big objects stay cheap.
List<DiffLine> diffLines(String a, String b) {
  final x = a.split('\n'), y = b.split('\n');
  var pre = 0;
  while (pre < x.length && pre < y.length && x[pre] == y[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < x.length - pre && suf < y.length - pre && x[x.length - 1 - suf] == y[y.length - 1 - suf]) {
    suf++;
  }
  final xs = x.sublist(pre, x.length - suf), ys = y.sublist(pre, y.length - suf);
  final out = <DiffLine>[for (var i = 0; i < pre; i++) DiffLine(DiffOp.same, x[i], oldNo: i + 1, newNo: i + 1)];

  final n = xs.length, m = ys.length;
  if (n * m > 4000000) {
    // Too big for LCS: show as replace-all of the middle.
    for (var i = 0; i < n; i++) {
      out.add(DiffLine(DiffOp.remove, xs[i], oldNo: pre + i + 1));
    }
    for (var j = 0; j < m; j++) {
      out.add(DiffLine(DiffOp.add, ys[j], newNo: pre + j + 1));
    }
  } else {
    // dp[i][j] = LCS length of xs[i..] and ys[j..]
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = xs[i] == ys[j] ? dp[i + 1][j + 1] + 1 : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && xs[i] == ys[j]) {
        out.add(DiffLine(DiffOp.same, xs[i], oldNo: pre + i + 1, newNo: pre + j + 1));
        i++;
        j++;
      } else if (j < m && (i == n || dp[i][j + 1] > dp[i + 1][j])) {
        out.add(DiffLine(DiffOp.add, ys[j], newNo: pre + j + 1));
        j++;
      } else {
        out.add(DiffLine(DiffOp.remove, xs[i], oldNo: pre + i + 1));
        i++;
      }
    }
  }
  for (var k = 0; k < suf; k++) {
    final oi = x.length - suf + k, ni = y.length - suf + k;
    out.add(DiffLine(DiffOp.same, x[oi], oldNo: oi + 1, newNo: ni + 1));
  }
  return out;
}

/// A display item: either a diff line or a collapsed run of unchanged lines.
class DiffHunkItem {
  final DiffLine? line;
  final int skipped;
  const DiffHunkItem.line(DiffLine this.line) : skipped = 0;
  const DiffHunkItem.skip(this.skipped) : line = null;
}

/// Collapse unchanged runs, keeping [context] lines around each change.
List<DiffHunkItem> withContext(List<DiffLine> lines, {int context = 3}) {
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].op != DiffOp.same) {
      for (var k = i - context; k <= i + context; k++) {
        if (k >= 0 && k < lines.length) keep[k] = true;
      }
    }
  }
  final out = <DiffHunkItem>[];
  var skipped = 0;
  for (var i = 0; i < lines.length; i++) {
    if (keep[i]) {
      if (skipped > 0) out.add(DiffHunkItem.skip(skipped));
      skipped = 0;
      out.add(DiffHunkItem.line(lines[i]));
    } else {
      skipped++;
    }
  }
  if (skipped > 0) out.add(DiffHunkItem.skip(skipped));
  return out;
}

({int added, int removed}) diffStats(List<DiffLine> lines) =>
    (added: lines.where((l) => l.op == DiffOp.add).length, removed: lines.where((l) => l.op == DiffOp.remove).length);
