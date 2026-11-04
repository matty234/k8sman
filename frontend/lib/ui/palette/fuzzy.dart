/// Fuzzy (subsequence) matching for the command palette.
///
/// Every query character must appear in the text, in order. Matches score
/// higher when they are exact, a prefix, start words (after `-`, `_`, `.`,
/// `/`, a space or a camelCase hump) or run consecutively, and lower the
/// more text they skip or leave unmatched.
library;

/// A successful match: higher [score] is better; [positions] are the
/// matched character indices in the text (only when asked for).
class FuzzyMatch {
  final int score;
  final List<int> positions;
  const FuzzyMatch(this.score, [this.positions = const []]);
}

const _charScore = 16;
const _firstCharBonus = 40;
const _wordStartBonus = 28;
const _consecutiveBonus = 20;
const _exactBonus = 400;
const _prefixBonus = 160;

bool _isSeparator(int c) => c == 0x2D || c == 0x5F || c == 0x2E || c == 0x2F || c == 0x20 || c == 0x3A;
bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;
bool _isLowerOrDigit(int c) => (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);

/// Bonus for matching at [i] in [text] (original case, for camelCase).
int _boundaryBonus(String text, int i) {
  if (i == 0) return _firstCharBonus;
  final prev = text.codeUnitAt(i - 1);
  if (_isSeparator(prev)) return _wordStartBonus;
  if (_isUpper(text.codeUnitAt(i)) && _isLowerOrDigit(prev)) return _wordStartBonus;
  return 0;
}

/// Matches [query] (already lower-cased, non-empty) against [text]. [lower]
/// is `text.toLowerCase()`, passed in so callers can cache it. Returns null
/// when [query] is not a subsequence of [text].
FuzzyMatch? fuzzyMatch(String query, String text, {String? lower, bool positions = false}) {
  final t = lower ?? text.toLowerCase();
  final m = query.length, n = t.length;
  if (m == 0) return const FuzzyMatch(0);
  if (m > n) return null;

  // Fast reject (and the common case of thousands of non-matches).
  var k = 0;
  for (var j = 0; j < n && k < m; j++) {
    if (t.codeUnitAt(j) == query.codeUnitAt(k)) k++;
  }
  if (k < m) return null;

  // Short text penalty: prefer "Pod" over "PodTemplate" for "pod".
  final slack = n - m;
  final lengthPenalty = slack > 40 ? 20 : slack ~/ 2;

  if (t == query) return FuzzyMatch(_exactBonus + m * (_charScore + _consecutiveBonus), positions ? List.generate(m, (i) => i) : const []);

  final sub = t.indexOf(query);
  if (sub == 0) {
    return FuzzyMatch(_prefixBonus + _firstCharBonus + m * (_charScore + _consecutiveBonus) - lengthPenalty, positions ? List.generate(m, (i) => i) : const []);
  }

  // Dynamic programming over (query char i, text position j): best score
  // with q[i] matched at j. A contiguous run at a word start is the ideal;
  // gaps cost one point per skipped character.
  const none = -1 << 30;
  var prev = List<int>.filled(n, none);
  var cur = List<int>.filled(n, none);
  final from = positions ? List.generate(m, (_) => List<int>.filled(n, -1)) : null;
  for (var j = 0; j < n; j++) {
    if (t.codeUnitAt(j) == query.codeUnitAt(0)) {
      final lead = j > 15 ? 15 : j;
      prev[j] = _charScore + _boundaryBonus(text, j) - lead;
    }
  }
  for (var i = 1; i < m; i++) {
    final qc = query.codeUnitAt(i);
    var best = none, bestAt = -1; // best prev[k] - (j - k - 1) for k < j - 1, kept decayed
    for (var j = 0; j < n; j++) {
      cur[j] = none;
      if (j >= 1 && t.codeUnitAt(j) == qc) {
        final bonus = _charScore + _boundaryBonus(text, j);
        var s = none, at = -1;
        if (prev[j - 1] > none) {
          s = prev[j - 1] + bonus + _consecutiveBonus;
          at = j - 1;
        }
        if (best > none && best + bonus > s) {
          s = best + bonus;
          at = bestAt;
        }
        cur[j] = s;
        if (from != null) from[i][j] = at;
      }
      // Slide the gap window: k = j - 1 becomes available for j + 1.
      if (best > none) best -= 1;
      if (j >= 1 && prev[j - 1] > none && prev[j - 1] - 1 > best) {
        best = prev[j - 1] - 1;
        bestAt = j - 1;
      }
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  var score = none, end = -1;
  for (var j = 0; j < n; j++) {
    if (prev[j] > score) {
      score = prev[j];
      end = j;
    }
  }
  if (end < 0) return null;
  // A plain substring is at least as good as a scattered match.
  if (sub > 0) score += _consecutiveBonus;
  score -= lengthPenalty;
  if (from == null) return FuzzyMatch(score);
  final pos = List<int>.filled(m, 0);
  for (var i = m - 1, j = end; i >= 0; i--) {
    pos[i] = j;
    j = i > 0 ? from[i][j] : j;
  }
  return FuzzyMatch(score, pos);
}
