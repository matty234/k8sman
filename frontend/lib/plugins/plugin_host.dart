/// The app's view of the backend's runtime plugins: the plugin list (for
/// the Plugins settings, sidebar sections and kind icons), its changes
/// (hot reload), and the shell actions last offered per object.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api/client.dart';
import '../modules/module.dart' show NavGroup;
import '../state/startup_gate.dart';
import 'plugin_api.dart';
import 'plugin_icons.dart';

/// The id of the plugin host module (backend and UI).
const String pluginsModuleId = 'plugins';

class PluginHost extends ChangeNotifier {
  ApiClient? _api;
  PluginsState _state = PluginsState.empty;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _retry;
  int _attempt = 0;
  final Map<String, Uint8List?> _icons = {};
  final Map<String, List<PluginAction>> _actions = {};

  /// The last `GET /api/plugins`.
  PluginsState get state => _state;

  /// Bumped by the backend on every load, hot reload or setting change.
  int get generation => _state.generation;

  /// Follows [api] from now on (idempotent; safe in build methods). The
  /// first fetch waits until the first table has painted.
  void attach(ApiClient api) {
    if (identical(_api, api)) return;
    _stopEvents();
    _api = api;
    _state = PluginsState.empty;
    _icons.clear();
    _actions.clear();
    StartupGate.ready.then((_) {
      if (identical(_api, api)) refresh();
    });
  }

  /// Fetches the plugin list again.
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      final s = PluginsState.fromJson(await api.plugins());
      if (identical(api, _api)) apply(s);
    } on ApiException catch (e) {
      // 404: the plugins integration is turned off.
      if (e.status == 404 && identical(api, _api)) apply(PluginsState.empty);
    } catch (_) {
      // No backend (yet): the next change or attach tries again.
    }
  }

  /// Takes a fresh state (from a fetch or a settings change's answer).
  void apply(PluginsState s) {
    if (s.generation != _state.generation) {
      _actions.clear();
      _icons.clear();
    }
    _state = s;
    _followEvents();
    notifyListeners();
  }

  /// Takes the answer of a plugin settings call (`GET /api/plugins`'s shape).
  void applyJson(Map<String, dynamic> j) => apply(PluginsState.fromJson(j));

  // While dev mode is on, a WebSocket tells about every change.
  void _followEvents() {
    final api = _api;
    if (!_state.devMode || api == null) {
      _stopEvents();
      return;
    }
    if (_events != null || _retry != null) return;
    _events = api.jsonStream('plugins/events').listen(
      (m) {
        _attempt = 0;
        final g = (m['generation'] as num?)?.toInt();
        if (g != null && g != _state.generation) refresh();
      },
      onError: (Object _) {},
      onDone: () {
        _events = null;
        if (!_state.devMode || !identical(api, _api)) return;
        _retry = Timer(Duration(seconds: math.min(30, 1 << _attempt++)), () {
          _retry = null;
          _followEvents();
        });
      },
    );
  }

  void _stopEvents() {
    _retry?.cancel();
    _retry = null;
    _events?.cancel();
    _events = null;
  }

  /// The plugins whose contributions apply.
  Iterable<PluginInfo> get active => _state.devMode ? _state.plugins.where((p) => p.active) : const [];

  /// Whether a plugin adds panel sections or actions to kind [gk].
  bool contributesTo(String gk) => active.any((p) => p.kinds.any((k) => (k.key == gk && (k.sections > 0 || k.actions > 0)) || (k.key == '*' && k.actions > 0)));

  /// The plugins' sidebar sections.
  List<NavGroup> get navGroups => [
        for (final p in active)
          if (p.nav case final nav? when nav.title.isNotEmpty) NavGroup(nav.title, nav.kinds, after: nav.after),
      ];

  /// Sidebar glyphs the plugins give their kinds (by icon name).
  Map<String, IconData> get kindIcons => {
        for (final p in active)
          for (final e in p.kindIcons.entries)
            e.key: ?pluginIcons[e.value],
      };

  /// The plugin whose icon.png is kind [gk]'s glyph, if any.
  PluginInfo? pngIconFor(String gk) => active.where((p) => p.hasIcon && p.kindIcons[gk] == 'icon.png').firstOrNull;

  /// Plugin [id]'s icon.png: null until fetched (listeners hear when it
  /// lands) or when it can't be.
  Uint8List? iconBytes(String id) {
    if (_icons.containsKey(id)) return _icons[id];
    _icons[id] = null;
    final api = _api;
    if (api != null) {
      api.pluginIcon(id).then((b) {
        _icons[id] = b;
        notifyListeners();
      }, onError: (Object _) {});
    }
    return null;
  }

  /// The shell actions last offered for object [uid] (by its panel fetch).
  List<PluginAction> actionsFor(String uid) => _actions[uid] ?? const [];

  /// Records the actions offered for [uid]; listeners hear after the frame.
  void setActions(String uid, List<PluginAction> actions) {
    final old = _actions[uid];
    if (old != null && listEquals([for (final a in old) '${a.plugin}/${a.id}/${a.argv.join(' ')}/${a.consented}'],
        [for (final a in actions) '${a.plugin}/${a.id}/${a.argv.join(' ')}/${a.consented}'])) {
      return;
    }
    _actions[uid] = actions;
    SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  /// Sets the state directly (tests).
  @visibleForTesting
  void debugSet(PluginsState s) {
    _state = s;
    notifyListeners();
  }
}

/// The app's [PluginHost].
final pluginHost = PluginHost();
