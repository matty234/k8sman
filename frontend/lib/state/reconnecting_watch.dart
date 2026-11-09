import 'dart:async';
import 'dart:math' as math;

import '../api/models.dart';

/// A watch stream that reopens itself after it fails or closes, with a
/// jittered exponential backoff. The owner calls [resetBackoff] on the first
/// good frame (a SNAPSHOT), so the next failure starts from the short delay.
class ReconnectingWatch {
  /// Opens the stream; called for every (re)connect.
  final Stream<WatchMessage> Function() open;
  final void Function(WatchMessage) onFrame;

  /// The stream failed ([error] set) or closed cleanly (null); a reconnect
  /// is already scheduled.
  final void Function(Object? error)? onLost;

  ReconnectingWatch({required this.open, required this.onFrame, this.onLost});

  static const _base = Duration(milliseconds: 500);
  static const _cap = Duration(seconds: 16);
  static final _random = math.Random();

  StreamSubscription<WatchMessage>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _stopped = false;

  /// Exponential backoff (500 ms doubling to 16 s) with "equal jitter": a
  /// random delay in [d/2, d], so many watches (and windows) that lost the
  /// backend together don't reconnect in lockstep.
  static Duration delay(int attempt, math.Random random) {
    final d = math.min(_base.inMilliseconds * (1 << attempt.clamp(0, 5)), _cap.inMilliseconds);
    return Duration(milliseconds: d ~/ 2 + random.nextInt(d ~/ 2 + 1));
  }

  void resetBackoff() => _attempt = 0;

  /// Connects now, replacing any open stream and pending retry.
  void start() {
    _stopped = false;
    _retry?.cancel();
    _sub?.cancel();
    _sub = open().listen(onFrame, onError: (Object e) => _lost(e), onDone: () => _lost(null));
  }

  /// Connects now from the shortest backoff (a manual retry, a new target).
  void restart() {
    resetBackoff();
    start();
  }

  /// Closes the stream and drops any pending reconnect.
  void stop() {
    _stopped = true;
    _retry?.cancel();
    _sub?.cancel();
  }

  void _lost(Object? error) {
    if (_stopped) return;
    onLost?.call(error);
    if (_stopped) return;
    _retry?.cancel();
    _retry = Timer(delay(_attempt++, _random), start);
  }
}
