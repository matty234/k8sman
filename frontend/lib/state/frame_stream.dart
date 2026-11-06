import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import 'ring_buffer.dart';

/// What one frame of a batched stream carries.
typedef StreamFrame<T> = ({List<T> items, int lost, bool end, String? error});

enum FramePhase { connecting, live, ended, error }

/// A live list fed by a backend WebSocket that sends rows in batched
/// frames (`/api/hubble/flows`; any `{items…, lost, end, error}` shape via
/// [decode]): connects, keeps the newest [capacity] rows in a
/// [RingBuffer], and notifies once per frame (the backend batches, so at
/// most ~10 times a second).
///
/// [pause] freezes [items] so a reader isn't scrolled away: rows that
/// arrive meanwhile wait in [pending] (also bounded) and land on [resume].
/// Lists render [items] with a fixed-height `ListView.builder`; see
/// `FlowList` (lib/hubble) for one.
class FrameStream<T> extends ChangeNotifier {
  /// Opens the socket; called again by [restart].
  final Stream<Json> Function() connect;
  final StreamFrame<T> Function(Json frame) decode;
  final int capacity;

  FrameStream({required this.connect, required this.decode, this.capacity = 5000})
      : items = RingBuffer<T>(capacity);

  final RingBuffer<T> items;
  final List<T> _pending = [];
  StreamSubscription<Json>? _sub;
  bool _disposed = false;

  FramePhase phase = FramePhase.connecting;
  String? error;
  bool paused = false;

  /// Rows the backend reported lost (rate cap, relay buffer overruns), plus
  /// rows that didn't fit in [pending] while paused.
  int lost = 0;

  /// Rows evicted from [items] because it was full.
  int evicted = 0;

  /// Rows received while paused, oldest first.
  List<T> get pending => List.unmodifiable(_pending);
  int get pendingCount => _pending.length;

  void start() {
    _sub?.cancel();
    phase = FramePhase.connecting;
    error = null;
    _sub = connect().listen(_onFrame, onError: (Object e) {
      phase = FramePhase.error;
      error = '$e';
      _notify();
    }, onDone: () {
      if (phase == FramePhase.connecting || phase == FramePhase.live) phase = FramePhase.ended;
      _notify();
    });
    _notify();
  }

  /// Clears everything and connects again (e.g. after the filters changed).
  void restart() {
    items.clear();
    _pending.clear();
    lost = 0;
    evicted = 0;
    paused = false;
    start();
  }

  void _onFrame(Json j) {
    final f = decode(j);
    lost += f.lost;
    if (f.error != null) {
      phase = FramePhase.error;
      error = f.error;
    } else if (f.end) {
      phase = FramePhase.ended;
    } else {
      phase = FramePhase.live;
    }
    if (f.items.isNotEmpty) {
      if (paused) {
        _pending.addAll(f.items);
        final over = _pending.length - capacity;
        if (over > 0) {
          _pending.removeRange(0, over);
          lost += over;
        }
      } else {
        evicted += items.append(f.items);
      }
    }
    _notify();
  }

  void pause() {
    if (paused) return;
    paused = true;
    _notify();
  }

  void resume() {
    if (!paused) return;
    paused = false;
    evicted += items.append(_pending);
    _pending.clear();
    _notify();
  }

  void clear() {
    items.clear();
    _pending.clear();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
