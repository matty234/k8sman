import 'dart:async';

import 'package:flutter/widgets.dart';

/// Holds back non-critical startup fetches (CRD group icons, the alerts
/// badge) until the first resource table has painted, so they don't compete
/// with its list/watch for the backend.
///
/// The [Shell] [hold]s the gate while it is up; the first table that loads
/// (or fails) opens it after its next frame, and so does a shell showing no
/// table. It opens after [maxHold] regardless. Without a holder (widgets
/// pumped on their own, e.g. in tests) [ready] resolves at once.
abstract final class StartupGate {
  static const maxHold = Duration(seconds: 3);

  static Completer<void>? _gate;
  static Timer? _cap;
  static bool _opened = false;

  /// Whether gated work may run now.
  static bool get isOpen => _opened || _gate == null;

  /// Completes when gated work may run.
  static Future<void> get ready => isOpen ? Future.value() : _gate!.future;

  /// Start holding (the shell, on startup). No-op once opened.
  static void hold() {
    if (_opened || _gate != null) return;
    _gate = Completer<void>();
    _cap = Timer(maxHold, open);
  }

  /// The first table has data (or failed): open once that frame is drawn.
  static void firstContentShown() {
    if (isOpen) return;
    final binding = WidgetsBinding.instance;
    binding.scheduleFrame();
    binding.endOfFrame.then((_) => open());
  }

  static void open() {
    _cap?.cancel();
    _cap = null;
    _opened = true;
    final g = _gate;
    _gate = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  /// The holder went away (e.g. the shell was disposed).
  static void release() {
    if (_gate != null) open();
  }

  /// Back to the initial state (tests).
  @visibleForTesting
  static void reset() {
    _cap?.cancel();
    _cap = null;
    _opened = false;
    final g = _gate;
    _gate = null;
    if (g != null && !g.isCompleted) g.complete();
  }
}
