/// The app's view of the backend's runtime plugins: the plugin list (for
/// the Plugins settings, sidebar sections and kind icons), its changes
/// (hot reload), and the actions last offered per object.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../actions/actions.dart' show ResourceAction;
import '../api/client.dart';
import '../modules/module.dart' show NavGroup;
import '../state/startup_gate.dart';
import '../util/k8s.dart' show asMap;
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
    _bound.clear();
    _status.clear();
    _statusKey = null;
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
      // 404: an older backend without plugins.
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

  /// The plugins whose contributions apply: bundled ones that are on, and
  /// in dev mode the user's own (the backend decides; see
  /// [PluginInfo.active]).
  Iterable<PluginInfo> get active => _state.plugins.where((p) => p.active);

  /// The bundled plugins (shown in Settings ▸ Integrations like modules).
  Iterable<PluginInfo> get bundled => _state.plugins.where((p) => p.bundled);

  /// Whether a plugin adds panel sections, tabs or actions to kind [gk]
  /// (its own entry, or one for any kind, "*").
  bool contributesTo(String gk) => active.any((p) => p.kinds.any((k) => (k.key == gk || k.key == '*') && (k.sections > 0 || k.tabs > 0 || k.actions > 0)));

  /// What becomes of the generic panel's sections for kind [gk] when it
  /// has no compiled-in panel: `replace` if a plugin with sections for it
  /// says so, else `collapse` if one says that, else `keep`.
  String genericFor(String gk) {
    final modes = {
      for (final p in active)
        for (final k in p.kinds)
          if (k.key == gk && k.sections > 0) k.generic,
    };
    return modes.contains('replace') ? 'replace' : (modes.contains('collapse') ? 'collapse' : 'keep');
  }

  final Map<String, PluginStatusLine> _status = {};
  String? _statusKey;
  DateTime _statusAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _statusBusy = false;

  /// Plugin [id]'s status line on context [contextName] (null until
  /// fetched, or when it has none). Fetched again after 30 seconds, or when
  /// the context or the plugins change; listeners hear when it lands.
  PluginStatusLine? statusOf(String id, String contextName) {
    final key = '$contextName@$generation';
    if (!_statusBusy && (key != _statusKey || DateTime.now().difference(_statusAt) > const Duration(seconds: 30))) {
      final api = _api;
      if (api != null) {
        if (key != _statusKey) _status.clear();
        _statusKey = key;
        _statusBusy = true;
        _statusAt = DateTime.now();
        // Never synchronously: this is called from build methods.
        Future(() => api.pluginStatus()).then((j) {
          if (!identical(api, _api) || key != _statusKey) return;
          _status
            ..clear()
            ..addAll({for (final e in asMap(j['plugins']).entries) e.key: PluginStatusLine.fromJson(asMap(e.value))});
        }, onError: (Object _) {}).whenComplete(() {
          _statusBusy = false;
          notifyListeners();
        });
      }
    }
    return _status[id];
  }

  /// The plugins' sidebar sections.
  List<NavGroup> get navGroups => [
        for (final p in active)
          if (p.nav case final nav? when nav.title.isNotEmpty) NavGroup(nav.title, nav.kinds),
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

  /// The actions last offered for object [uid] (by its panel fetch).
  List<PluginAction> actionsFor(String uid) => _actions[uid] ?? const [];

  /// The action of object [uid] whose `shortcut` is [key] (with or without
  /// Shift; other modifiers aren't bound), for the table's single-key
  /// bindings. The table checks its own keys first, so a clash keeps the
  /// built-in.
  PluginAction? actionForKey(String uid, LogicalKeyboardKey key, {required bool shift}) {
    final label = key.keyLabel.toUpperCase();
    for (final a in actionsFor(uid)) {
      final parts = (a.shortcut ?? '').split('+');
      final mods = parts.sublist(0, parts.length - 1).map((m) => m.toLowerCase()).toSet();
      if (parts.last.length != 1 || mods.difference(const {'shift'}).isNotEmpty) continue;
      if (mods.contains('shift') == shift && parts.last.toUpperCase() == label) return a;
    }
    return null;
  }

  final Map<String, List<ResourceAction> Function()> _bound = {};

  /// Records how to build the plugin actions of the object the inspector
  /// shows ([pluginTargetKey]), for the command palette.
  void bindActions(String target, List<ResourceAction> Function() actions) => _bound[target] = actions;

  /// The plugin actions of the inspected object [target], ready to run.
  List<ResourceAction> boundActions(String target) => _bound[target]?.call() ?? const [];

  /// Records the actions offered for [uid]; listeners hear after the frame.
  void setActions(String uid, List<PluginAction> actions) {
    final old = _actions[uid];
    if (old != null && listEquals([for (final a in old) a.signature], [for (final a in actions) a.signature])) {
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

/// Identifies an inspected object for [PluginHost.bindActions].
String pluginTargetKey(String gk, String? namespace, String name) => '$gk|${namespace ?? ''}|$name';
