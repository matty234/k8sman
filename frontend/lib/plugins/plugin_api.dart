/// Models for the runtime plugin endpoints (`/api/plugins…`, see
/// docs/PLUGINS.md). The backend loads, compiles and evaluates plugins;
/// the UI only draws what it sends.
library;

import '../api/models.dart';
import '../util/k8s.dart';

/// A load, compile or evaluation problem, with its place in plugin.yaml.
class PluginDiag {
  final String file;
  final int line;
  final int col;
  final String message;
  final bool warning;

  /// The source line (shown with a caret under [col]).
  final String snippet;
  const PluginDiag({required this.file, required this.line, required this.col, required this.message, this.warning = false, this.snippet = ''});

  factory PluginDiag.fromJson(Json j) => PluginDiag(
        file: '${j['file'] ?? 'plugin.yaml'}',
        line: (j['line'] as num?)?.toInt() ?? 0,
        col: (j['col'] as num?)?.toInt() ?? 0,
        message: '${j['message'] ?? ''}',
        warning: j['warning'] == true,
        snippet: '${j['snippet'] ?? ''}',
      );

  String get where => '$file:$line:$col';

  @override
  String toString() => '$where: $message';
}

/// One contribution type's evaluation numbers.
class PluginStats {
  final int count;
  final int errors;
  final int limitHits;
  final double p50us;
  final double p95us;
  final double maxUs;
  const PluginStats({this.count = 0, this.errors = 0, this.limitHits = 0, this.p50us = 0, this.p95us = 0, this.maxUs = 0});

  factory PluginStats.fromJson(Json j) => PluginStats(
        count: (j['count'] as num?)?.toInt() ?? 0,
        errors: (j['errors'] as num?)?.toInt() ?? 0,
        limitHits: (j['limitHits'] as num?)?.toInt() ?? 0,
        p50us: (j['p50Us'] as num?)?.toDouble() ?? 0,
        p95us: (j['p95Us'] as num?)?.toDouble() ?? 0,
        maxUs: (j['maxUs'] as num?)?.toDouble() ?? 0,
      );
}

/// A kind entry of a plugin.
class PluginKind {
  final String key;
  final bool served;
  final bool compiled;
  final int columns;
  final int sections;
  final int actions;
  final int alerts;
  final int related;
  final int metrics;
  final int errors;
  const PluginKind({
    required this.key,
    this.served = false,
    this.compiled = false,
    this.columns = 0,
    this.sections = 0,
    this.actions = 0,
    this.alerts = 0,
    this.related = 0,
    this.metrics = 0,
    this.errors = 0,
  });

  factory PluginKind.fromJson(Json j) => PluginKind(
        key: '${j['key'] ?? ''}',
        served: j['served'] == true,
        compiled: j['compiled'] == true,
        columns: (j['columns'] as num?)?.toInt() ?? 0,
        sections: (j['sections'] as num?)?.toInt() ?? 0,
        actions: (j['actions'] as num?)?.toInt() ?? 0,
        alerts: (j['alerts'] as num?)?.toInt() ?? 0,
        related: (j['related'] as num?)?.toInt() ?? 0,
        metrics: (j['metrics'] as num?)?.toInt() ?? 0,
        errors: (j['errors'] as num?)?.toInt() ?? 0,
      );
}

class PluginPermissions {
  final List<String> read;
  final List<String> patch;
  final List<String> commands;
  final bool prometheus;
  const PluginPermissions({this.read = const [], this.patch = const [], this.commands = const [], this.prometheus = false});

  factory PluginPermissions.fromJson(Json j) => PluginPermissions(
        read: [for (final x in (j['read'] as List? ?? const [])) '$x'],
        patch: [for (final x in (j['patch'] as List? ?? const [])) '$x'],
        commands: [for (final x in (j['commands'] as List? ?? const [])) '$x'],
        prometheus: j['prometheus'] == true,
      );
}

/// A plugin's sidebar section.
class PluginNav {
  final String title;
  final String? after;
  final List<String> kinds;
  const PluginNav({required this.title, this.after, this.kinds = const []});
}

/// One plugin folder.
class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final List<String> authors;
  final String homepage;
  final String dir;

  /// dev (added in the app), flag (--plugin-dev), installed or bundled
  /// (compiled into the backend; shown in Settings ▸ Integrations like a
  /// module).
  final String source;

  /// Whether its contributions apply now (decided by the backend: loaded,
  /// on, not overridden or replaced by its module, and for the user's own
  /// plugins, dev mode with the Plugins integration on).
  final bool active;

  /// A bundled plugin that a loaded folder with its id overrides, and that
  /// folder's plugin.
  final bool overridden;
  final bool overrides;

  /// The built-in module a bundled plugin replaces, and whether the app
  /// uses that module instead (to compare the two; settings.json's
  /// plugins.useModule).
  final String? replacesModule;
  final bool usingModule;

  /// ok, warning or error (the last load failed; [loaded] says whether a
  /// previous version still runs).
  final String status;
  final bool loaded;
  final bool disabled;
  final List<PluginDiag> diags;
  final PluginPermissions permissions;
  final String permissionsHash;
  final bool consented;
  final List<PluginKind> kinds;
  final PluginNav? nav;
  final Map<String, String> kindIcons;
  final bool hasIcon;
  final double loadMs;
  final double compileMs;
  final Map<String, PluginStats> stats;

  const PluginInfo({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.authors = const [],
    this.homepage = '',
    this.dir = '',
    this.source = 'dev',
    this.active = true,
    this.overridden = false,
    this.overrides = false,
    this.replacesModule,
    this.usingModule = false,
    this.status = 'ok',
    this.loaded = true,
    this.disabled = false,
    this.diags = const [],
    this.permissions = const PluginPermissions(),
    this.permissionsHash = '',
    this.consented = false,
    this.kinds = const [],
    this.nav,
    this.kindIcons = const {},
    this.hasIcon = false,
    this.loadMs = 0,
    this.compileMs = 0,
    this.stats = const {},
  });

  factory PluginInfo.fromJson(Json j) {
    final nav = asMap(j['nav']);
    return PluginInfo(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? ''}',
      version: '${j['version'] ?? ''}',
      description: '${j['description'] ?? ''}',
      authors: [for (final a in (j['authors'] as List? ?? const [])) '$a'],
      homepage: '${j['homepage'] ?? ''}',
      dir: '${j['dir'] ?? ''}',
      source: '${j['source'] ?? 'dev'}',
      active: j['active'] == true,
      overridden: j['overridden'] == true,
      overrides: j['overrides'] == true,
      replacesModule: (j['replacesModule'] as String?)?.isEmpty == true ? null : j['replacesModule'] as String?,
      usingModule: j['usingModule'] == true,
      status: '${j['status'] ?? 'ok'}',
      loaded: j['loaded'] == true,
      disabled: j['disabled'] == true,
      diags: [for (final d in asMapList(j['diags'])) PluginDiag.fromJson(d)],
      permissions: PluginPermissions.fromJson(asMap(j['permissions'])),
      permissionsHash: '${j['permissionsHash'] ?? ''}',
      consented: j['consented'] == true,
      kinds: [for (final k in asMapList(j['kinds'])) PluginKind.fromJson(k)],
      nav: nav.isEmpty
          ? null
          : PluginNav(title: '${nav['title'] ?? ''}', after: (nav['after'] as String?)?.isEmpty == true ? null : nav['after'] as String?, kinds: [
              for (final k in (nav['kinds'] as List? ?? const [])) '$k',
            ]),
      kindIcons: {for (final e in asMap(j['kindIcons']).entries) e.key: '${e.value}'},
      hasIcon: j['hasIcon'] == true,
      loadMs: (j['loadMs'] as num?)?.toDouble() ?? 0,
      compileMs: (j['compileMs'] as num?)?.toDouble() ?? 0,
      stats: {for (final e in asMap(j['stats']).entries) e.key: PluginStats.fromJson(asMap(e.value))},
    );
  }

  /// Compiled into the backend.
  bool get bundled => source == 'bundled';

  List<PluginDiag> get errors => [for (final d in diags) if (!d.warning) d];
}

/// `GET /api/plugins`.
class PluginsState {
  final bool devMode;
  final bool devModeSaved;
  final List<String> devFolders;
  final List<String> flagFolders;
  final String installedDir;
  final int generation;
  final bool readOnly;
  final List<PluginInfo> plugins;
  const PluginsState({
    this.devMode = false,
    this.devModeSaved = false,
    this.devFolders = const [],
    this.flagFolders = const [],
    this.installedDir = '',
    this.generation = 0,
    this.readOnly = false,
    this.plugins = const [],
  });

  factory PluginsState.fromJson(Json j) => PluginsState(
        devMode: j['devMode'] == true,
        devModeSaved: j['devModeSaved'] == true,
        devFolders: [for (final d in (j['devFolders'] as List? ?? const [])) '$d'],
        flagFolders: [for (final d in (j['flagFolders'] as List? ?? const [])) '$d'],
        installedDir: '${j['installedDir'] ?? ''}',
        generation: (j['generation'] as num?)?.toInt() ?? 0,
        readOnly: j['readOnly'] == true,
        plugins: [for (final p in asMapList(j['plugins'])) PluginInfo.fromJson(p)],
      );

  static const empty = PluginsState();
}

/// A form field of a plugin patch action. The backend checks the value
/// again (type, options, the plugin's `validate`).
class PluginInput {
  final String name;
  final String label;

  /// string, int, bool or enum.
  final String type;
  final List<String> options;
  final Object? defaultValue;
  final String? validateMessage;
  const PluginInput({required this.name, required this.label, this.type = 'string', this.options = const [], this.defaultValue, this.validateMessage});

  factory PluginInput.fromJson(Json j) => PluginInput(
        name: '${j['name'] ?? ''}',
        label: '${j['label'] ?? j['name'] ?? ''}',
        type: '${j['type'] ?? 'string'}',
        options: [for (final o in (j['options'] as List? ?? const [])) '$o'],
        defaultValue: j['default'],
        validateMessage: (j['validateMessage'] as String?)?.isEmpty == true ? null : j['validateMessage'] as String?,
      );
}

/// An action offered for an object: a shell command run on this computer,
/// or a patch of the object (through `POST /api/actions/plugin.<id>.<action>`).
class PluginAction {
  final String plugin;
  final String id;
  final String label;
  final String? icon;
  final String? shortcut;
  final String? message;
  final bool dangerous;

  /// shell or patch.
  final String type;

  /// A shell action's command exactly as it will run.
  final List<String> argv;

  /// A shell action that runs without a dock tab.
  final bool background;

  /// A patch action's type (merge or json) and form.
  final String patchType;
  final List<PluginInput> inputs;
  final bool consented;
  const PluginAction({
    required this.plugin,
    required this.id,
    required this.label,
    this.icon,
    this.shortcut,
    this.message,
    this.dangerous = true,
    this.type = 'shell',
    this.argv = const [],
    this.background = false,
    this.patchType = 'merge',
    this.inputs = const [],
    this.consented = false,
  });

  bool get isPatch => type == 'patch';

  /// Its name on `POST /api/actions/{action}`.
  String get actionName => 'plugin.$plugin.$id';

  factory PluginAction.fromJson(Json j) => PluginAction(
        plugin: '${j['plugin'] ?? ''}',
        id: '${j['id'] ?? ''}',
        label: '${j['label'] ?? ''}',
        icon: j['icon'] as String?,
        shortcut: (j['shortcut'] as String?)?.isEmpty == true ? null : j['shortcut'] as String?,
        message: (j['message'] as String?)?.isEmpty == true ? null : j['message'] as String?,
        dangerous: j['dangerous'] != false,
        type: '${j['type'] ?? 'shell'}',
        argv: [for (final a in (j['argv'] as List? ?? const [])) '$a'],
        background: j['background'] == true,
        patchType: '${j['patchType'] ?? 'merge'}',
        inputs: [for (final i in asMapList(j['inputs'])) PluginInput.fromJson(i)],
        consented: j['consented'] == true,
      );

  /// Identity for change detection (what the UI shows and runs).
  String get signature => '$plugin/$id/$type/${argv.join(' ')}/$consented/${[for (final i in inputs) '${i.name}=${i.defaultValue}'].join(',')}';
}

/// One plugin's resolved sections for an object.
class PluginPanelOut {
  final String plugin;
  final String name;

  /// Sections: {title, icon?, collapsed?, blocks: [{type, …}]}.
  final List<Json> sections;
  final List<PluginDiag> errors;

  /// What related objects or metrics couldn't be read.
  final List<String> notes;

  /// Seconds after which to render again while open (0 = only when the
  /// object changes): the panel reads related objects, metrics or `now`.
  final int refresh;
  const PluginPanelOut({required this.plugin, required this.name, this.sections = const [], this.errors = const [], this.notes = const [], this.refresh = 0});

  factory PluginPanelOut.fromJson(Json j) => PluginPanelOut(
        plugin: '${j['plugin'] ?? ''}',
        name: '${j['name'] ?? ''}',
        sections: asMapList(j['sections']),
        errors: [for (final d in asMapList(j['errors'])) PluginDiag.fromJson(d)],
        notes: [for (final n in (j['notes'] as List? ?? const [])) '$n'],
        refresh: (j['refresh'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /api/plugins/panel`.
class PluginPanelData {
  final List<PluginPanelOut> panels;
  final List<PluginAction> actions;
  const PluginPanelData({this.panels = const [], this.actions = const []});

  factory PluginPanelData.fromJson(Json j) => PluginPanelData(
        panels: [for (final p in asMapList(j['panels'])) PluginPanelOut.fromJson(p)],
        actions: [for (final a in asMapList(j['actions'])) PluginAction.fromJson(a)],
      );

  /// The soonest refresh any panel asks for (null = none).
  Duration? get refresh {
    final secs = [for (final p in panels) if (p.refresh > 0) p.refresh];
    return secs.isEmpty ? null : Duration(seconds: secs.reduce((a, b) => a < b ? a : b));
  }
}
