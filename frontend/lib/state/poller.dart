import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// One place that decides when pages poll the backend.
///
/// Every [Poll] holds at most one one-shot timer, and only while it can run:
/// the app is in the foreground (not hidden/minimised), the poll's subtree is
/// visible ([TickerMode] enabled, e.g. not in the collapsed inspector), and
/// it isn't paused by the user. A paused poll has no timer at all; when it
/// can run again it refreshes immediately. Failures back off exponentially
/// (doubling the interval, capped) until the next success.
class PollScheduler with WidgetsBindingObserver {
  PollScheduler._();
  static final PollScheduler instance = PollScheduler._();

  final Set<Poll> _polls = {};
  bool _observing = false;
  bool _wasForeground = true;

  /// Hidden, paused or detached apps don't poll. `inactive` (window not
  /// focused) still counts as foreground: the window is on screen.
  bool get foreground => switch (WidgetsBinding.instance.lifecycleState) {
        AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
        _ => true,
      };

  /// Polls currently registered (live, not disposed).
  int get pollCount => _polls.length;

  /// Polls currently holding a timer.
  int get armedCount => _polls.where((p) => p._timer != null).length;

  void _add(Poll p) {
    if (!_observing) {
      _observing = true;
      _wasForeground = foreground;
      WidgetsBinding.instance.addObserver(this);
    }
    _polls.add(p);
  }

  void _remove(Poll p) => _polls.remove(p);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = foreground;
    if (fg == _wasForeground) return;
    _wasForeground = fg;
    for (final p in [..._polls]) {
      p._update();
    }
  }
}

/// A periodic refresh managed by [PollScheduler]. [onTick] returns whether
/// the refresh succeeded (a throw counts as a failure). The next tick is
/// scheduled [interval] after the previous one finished, so slow requests
/// never overlap.
class Poll {
  final Duration interval;
  final Future<bool> Function() onTick;

  /// Longest delay while failing.
  final Duration maxBackoff;

  Poll({required this.interval, required this.onTick, Duration? maxBackoff, bool paused = false})
      : maxBackoff = maxBackoff ?? Duration(microseconds: math.max(interval.inMicroseconds, math.min(interval.inMicroseconds * 8, const Duration(minutes: 2).inMicroseconds))) {
    _paused = paused;
    PollScheduler.instance._add(this);
    _update();
  }

  Timer? _timer;
  bool _visible = true;
  bool _paused = false;
  bool _running = false;
  bool _disposed = false;

  /// Set while the poll couldn't run: run immediately once it can.
  bool _stale = false;
  int _failures = 0;
  ValueListenable<TickerModeData>? _tickerMode;

  /// Consecutive failures (0 after a success).
  int get failures => _failures;

  /// Whether the poll currently holds a timer.
  bool get armed => _timer != null;

  bool get _active => !_disposed && !_paused && _visible && PollScheduler.instance.foreground;

  /// The delay before the next tick: [interval], doubled per failure.
  Duration get nextDelay {
    if (_failures == 0) return interval;
    final us = interval.inMicroseconds * math.pow(2, math.min(_failures, 20));
    return Duration(microseconds: math.min(us, maxBackoff.inMicroseconds).toInt());
  }

  /// User pause (e.g. the Overview's pause button).
  bool get paused => _paused;
  set paused(bool v) {
    if (v == _paused) return;
    _paused = v;
    // Resuming from a user pause waits a full interval (as before).
    if (v && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
    _update();
  }

  /// Follow the [TickerMode] around [context]: call from
  /// `didChangeDependencies` and `activate` (see [PollingState]).
  void attach(BuildContext context) {
    final n = TickerMode.getValuesNotifier(context);
    if (identical(n, _tickerMode)) return;
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = n..addListener(_onTickerMode);
    _onTickerMode();
  }

  void _onTickerMode() {
    final v = _tickerMode?.value.enabled ?? true;
    if (v == _visible) return;
    _visible = v;
    _update();
  }

  /// Refresh now (and restart the interval).
  Future<void> now() => _tick();

  void _update() {
    if (_disposed) return;
    if (!_active) {
      if (_timer != null) {
        _timer!.cancel();
        _timer = null;
        _stale = true;
      }
      return;
    }
    if (_stale) {
      _stale = false;
      // After the frame that made us visible (listeners may fire mid-build).
      scheduleMicrotask(() {
        if (_active && !_running) _tick();
      });
      return;
    }
    _arm();
  }

  void _arm() {
    if (_disposed || _running || _timer != null || !_active) return;
    _timer = Timer(nextDelay, _tick);
  }

  Future<void> _tick() async {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _running) return;
    _running = true;
    var ok = false;
    try {
      ok = await onTick();
    } catch (_) {
      ok = false;
    }
    _running = false;
    if (_disposed) return;
    _failures = ok ? 0 : _failures + 1;
    if (_active) {
      _arm();
    } else if (!_paused) {
      _stale = true;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = null;
    PollScheduler.instance._remove(this);
  }
}

/// Polls owned by a [State]: they follow its [TickerMode] and are disposed
/// with it.
mixin PollingState<T extends StatefulWidget> on State<T> {
  final List<Poll> _polls = [];

  /// Starts polling [onTick] every [interval] (first tick after [interval]).
  Poll poll(Duration interval, Future<bool> Function() onTick, {bool paused = false}) {
    final p = Poll(interval: interval, onTick: onTick, paused: paused);
    _polls.add(p);
    return p;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final p in _polls) {
      p.attach(context);
    }
  }

  @override
  void activate() {
    super.activate();
    for (final p in _polls) {
      p.attach(context);
    }
  }

  @override
  void dispose() {
    for (final p in _polls) {
      p.dispose();
    }
    _polls.clear();
    super.dispose();
  }
}
