/// The app's own errors (overflows, duplicate keys, build/layout/paint
/// exceptions, uncaught async errors), grouped and kept on this machine
/// only: `~/.config/k8sman/diagnostics.json`, next to the backend's
/// settings. Nothing is sent anywhere; Settings ▸ Diagnostics shows the
/// groups and lets the user copy a report or open a GitHub issue.
///
/// Errors are grouped by a stable signature ([DiagnosticGroup.signature]):
/// the kind of error, the first k8sman source location (from the stack, or
/// in debug the widget's creation location), and the widget type where
/// known. Pixel counts, object names and other volatile text stay out of
/// it. Samples are redacted ([redactDiagnostics]) before they're stored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The app's log (installed by `installDiagnostics` in main).
final DiagnosticsLog diagnostics = DiagnosticsLog();

/// One group of identical errors.
class DiagnosticGroup {
  /// `kind|exception type|location|widget`.
  final String signature;

  /// `overflow`, `duplicate-key`, `build`, `layout`, `paint`, `async` or `error`.
  final String kind;
  final String exceptionType;

  /// `package:k8sman/…dart:<line>` (or `lib/…dart:<line>`), or ''.
  final String location;

  /// The widget the error is in, where known, or ''.
  final String widget;
  int count;
  DateTime firstSeen;
  DateTime lastSeen;
  String appVersion;

  /// Where in the app: "Pod inspector › Containers", "Secret table".
  String context;

  /// Redacted samples (the first).
  String message;
  String stack;

  DiagnosticGroup({
    required this.signature,
    required this.kind,
    required this.exceptionType,
    required this.location,
    required this.widget,
    required this.count,
    required this.firstSeen,
    required this.lastSeen,
    required this.appVersion,
    required this.context,
    required this.message,
    required this.stack,
  });

  /// A short title: "Overflow in Row", "_TypeError while building PodPanel".
  String get title {
    final at = widget.isEmpty ? '' : ' in $widget';
    return switch (kind) {
      'overflow' => 'Overflow$at',
      'duplicate-key' => 'Duplicate key$at',
      'build' => '$exceptionType while building${widget.isEmpty ? '' : ' $widget'}',
      'layout' => '$exceptionType during layout$at',
      'paint' => '$exceptionType while painting$at',
      'async' => 'Uncaught $exceptionType',
      _ => '$exceptionType$at',
    };
  }

  Map<String, Object?> toJson() => {
        'signature': signature,
        'kind': kind,
        'exceptionType': exceptionType,
        'location': location,
        'widget': widget,
        'count': count,
        'firstSeen': firstSeen.toUtc().toIso8601String(),
        'lastSeen': lastSeen.toUtc().toIso8601String(),
        'appVersion': appVersion,
        'context': context,
        'message': message,
        'stack': stack,
      };

  static DiagnosticGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sig = raw['signature'];
    final first = DateTime.tryParse('${raw['firstSeen']}');
    final last = DateTime.tryParse('${raw['lastSeen']}');
    if (sig is! String || first == null || last == null) return null;
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return DiagnosticGroup(
      signature: sig,
      kind: s('kind'),
      exceptionType: s('exceptionType'),
      location: s('location'),
      widget: s('widget'),
      count: raw['count'] is int ? raw['count'] as int : 1,
      firstSeen: first.toLocal(),
      lastSeen: last.toLocal(),
      appVersion: s('appVersion'),
      context: s('context'),
      message: s('message'),
      stack: s('stack'),
    );
  }
}

/// The grouped errors, persisted to a capped file with throttled writes.
class DiagnosticsLog extends ChangeNotifier {
  /// The file; null keeps the log in memory (tests). Main sets
  /// [defaultFile].
  File? file;
  final int maxGroups;
  final Duration writeDelay;

  /// This app's version, the place in the app (the fallback context) and
  /// the names to redact (contexts, clusters, namespaces, the open
  /// object): set by main.
  String Function() appVersion = () => 'unknown';
  String Function() place = () => '';
  Iterable<String> Function() sensitiveTerms = () => const [];

  final Map<String, DiagnosticGroup> _groups = {};
  final Expando<String> _signatureOf = Expando('diagnostics signature');
  DateTime? _viewedAt;
  Timer? _write;
  bool _notifyQueued = false;
  bool _recording = false;

  DiagnosticsLog({this.file, this.maxGroups = 200, this.writeDelay = const Duration(seconds: 3)});

  /// `~/.config/k8sman/diagnostics.json` (the backend keeps its settings
  /// in the same folder).
  static File? defaultFile() {
    if (kIsWeb) return null;
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    final sep = Platform.pathSeparator;
    return File('$home$sep.config${sep}k8sman${sep}diagnostics.json');
  }

  /// Newest first.
  List<DiagnosticGroup> get groups => _groups.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  bool get isEmpty => _groups.isEmpty;

  /// Groups first seen since Diagnostics was last viewed.
  int get unseen => _groups.values.where((g) => _viewedAt == null || g.firstSeen.isAfter(_viewedAt!)).length;

  void markViewed() {
    final had = unseen;
    _viewedAt = DateTime.now();
    if (had > 0) {
      _changed();
    }
  }

  /// Records [details]. Never throws (an error here mustn't feed itself).
  void record(FlutterErrorDetails details, {String? phase}) {
    if (_recording) return;
    _recording = true;
    try {
      _record(details, phase);
    } catch (e) {
      debugPrint('diagnostics: could not record an error: $e');
    } finally {
      _recording = false;
    }
  }

  void _record(FlutterErrorDetails details, String? phase) {
    final message = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    final info = _information(details);
    final kind = classify(message, details, phase: phase);
    final widget = info.widget ?? _widgetFromContext(details) ?? '';
    // Debug builds name the widget's creation site in the details text.
    final location = firstAppFrame(stack) ?? (info.hasInformation && kDebugMode ? creationLocation(_text(details)) : null) ?? '';
    final type = details.exception is FlutterError ? 'FlutterError' : details.exception.runtimeType.toString();
    final signature = [kind, type, location, widget].join('|');
    final where = info.context ?? place();
    final now = DateTime.now();
    final g = _groups[signature];
    if (g != null) {
      // The group keeps its first sample: an error repeating every frame
      // costs a count, not another redaction.
      g
        ..count += 1
        ..lastSeen = now
        ..appVersion = appVersion();
    } else {
      final terms = sensitiveTerms();
      _groups[signature] = DiagnosticGroup(
        signature: signature,
        kind: kind,
        exceptionType: type,
        location: location,
        widget: widget,
        count: 1,
        firstSeen: now,
        lastSeen: now,
        appVersion: appVersion(),
        context: redactDiagnostics(where, terms: terms),
        message: _cap(redactDiagnostics(message, terms: terms), 4000),
        stack: _cap(redactDiagnostics(_filterStack(stack), terms: terms), 6000),
      );
      _trim();
    }
    _signatureOf[details] = signature;
    _changed();
  }

  /// Sets the context of [details]' group from where the error showed up
  /// (the error widget's place in the tree), if it wasn't known.
  void attachContext(FlutterErrorDetails details, String context) {
    final g = _groups[_signatureOf[details] ?? ''];
    if (g == null || context.isEmpty) return;
    final c = redactDiagnostics(context, terms: sensitiveTerms());
    if (g.context == c) return;
    g.context = c;
    _changed();
  }

  void clear() {
    _groups.clear();
    _viewedAt = DateTime.now();
    _changed();
  }

  /// Loads the file (merging into anything recorded meanwhile).
  Future<void> load() async {
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return;
      final viewed = DateTime.tryParse('${raw['viewedAt']}');
      if (viewed != null) _viewedAt = viewed.toLocal();
      for (final r in raw['groups'] is List ? raw['groups'] as List : const []) {
        final g = DiagnosticGroup.fromJson(r);
        if (g == null) continue;
        final mine = _groups[g.signature];
        if (mine == null) {
          _groups[g.signature] = g;
        } else {
          mine
            ..count += g.count
            ..firstSeen = g.firstSeen.isBefore(mine.firstSeen) ? g.firstSeen : mine.firstSeen;
        }
      }
      _trim();
      _notify();
    } catch (e) {
      debugPrint('diagnostics: could not read ${f.path}: $e');
    }
  }

  /// Writes now (tests; otherwise writes are throttled).
  Future<void> flush() async {
    _write?.cancel();
    _write = null;
    final f = file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      final body = jsonEncode({
        'version': 1,
        if (_viewedAt != null) 'viewedAt': _viewedAt!.toUtc().toIso8601String(),
        'groups': [for (final g in groups) g.toJson()],
      });
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('diagnostics: could not write ${f.path}: $e');
    }
  }

  void _changed() {
    _notify();
    if (file != null) _write ??= Timer(writeDelay, flush);
  }

  /// Listeners hear of a change after the current frame: errors arrive
  /// mid-build and mid-layout, where a listener's setState would throw.
  void _notify() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      notifyListeners();
    });
  }

  void _trim() {
    if (_groups.length <= maxGroups) return;
    final old = _groups.values.toList()..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
    for (final g in old.take(_groups.length - maxGroups)) {
      _groups.remove(g.signature);
    }
  }

  @override
  void dispose() {
    _write?.cancel();
    super.dispose();
  }

  // ---- report ----

  /// The groups as markdown, with the app and OS versions. Redacted.
  String report({int? maxGroups, bool samples = true}) {
    final b = StringBuffer()
      ..writeln('### Environment')
      ..writeln()
      ..writeln('- k8sman: ${appVersion()}')
      ..writeln('- ${_osName()}: ${kIsWeb ? 'web' : redactDiagnostics(Platform.operatingSystemVersion)}')
      ..writeln('- Error groups: ${_groups.length}')
      ..writeln();
    final all = groups;
    final shown = maxGroups == null ? all : all.take(maxGroups).toList();
    for (final (i, g) in shown.indexed) {
      b
        ..writeln('### ${i + 1}. ${g.title} (×${g.count})')
        ..writeln()
        ..writeln('- Where: ${g.context.isEmpty ? 'unknown' : g.context}')
        ..writeln('- Source: ${g.location.isEmpty ? 'unknown' : '`${g.location}`'}')
        ..writeln('- Seen: ${_date(g.firstSeen)} – ${_date(g.lastSeen)} (k8sman ${g.appVersion})');
      if (samples) {
        b
          ..writeln()
          ..writeln('```')
          ..writeln(g.message.trim())
          ..writeln('```');
        if (g.stack.trim().isNotEmpty) {
          b
            ..writeln()
            ..writeln('<details><summary>Stack</summary>')
            ..writeln()
            ..writeln('```')
            ..writeln(g.stack.trim())
            ..writeln('```')
            ..writeln()
            ..writeln('</details>');
        }
      }
      b.writeln();
    }
    if (shown.length < all.length) b.writeln('…and ${all.length - shown.length} more.');
    return b.toString();
  }

  /// A new-issue URL with the title and body filled in, or null when even
  /// a summary is too long for a URL (copy the report instead).
  /// [full] reports whether the body holds the whole report.
  ({Uri url, bool full}) issueUrl({int maxLength = 7500}) {
    final title = _groups.length == 1 ? 'Error: ${groups.first.title}' : 'Errors: ${_groups.length} groups';
    Uri make(String body) => Uri.https('github.com', '/matty234/k8sman/issues/new', {'title': title, 'body': body});
    final full = make(report());
    if (full.toString().length <= maxLength) return (url: full, full: true);
    const paste = '_The full report is on the clipboard: paste it here._\n\n';
    for (final n in [20, 10, 5, 1]) {
      final u = make('$paste${report(maxGroups: n, samples: false)}');
      if (u.toString().length <= maxLength) return (url: u, full: false);
    }
    return (url: make(paste), full: false);
  }
}

String _osName() => kIsWeb
    ? 'Browser'
    : Platform.isMacOS
        ? 'macOS'
        : Platform.isWindows
            ? 'Windows'
            : Platform.isLinux
                ? 'Linux'
                : Platform.operatingSystem;

String _date(DateTime t) => t.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

String _cap(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}\n…';

/// The stack with framework frames folded (as the console shows it), at
/// most 60 lines.
String _filterStack(String stack) {
  if (stack.isEmpty) return '';
  final lines = FlutterError.defaultStackFilter(stack.trimRight().split('\n')).toList();
  return lines.take(60).join('\n');
}

// ---- signature ----

/// The error kind: `overflow`, `duplicate-key`, or the phase it happened in.
@visibleForTesting
String classify(String message, FlutterErrorDetails details, {String? phase}) {
  if (message.contains('overflowed by')) return 'overflow';
  if (RegExp(r'Duplicate (Global)?[Kk]eys?|same GlobalKey|Duplicate keys found').hasMatch(message)) return 'duplicate-key';
  if (phase != null) return phase;
  final c = '${details.context ?? ''}';
  if (c.startsWith('building') || c.contains('while building') || details.library == 'widgets library') return 'build';
  if (c.contains('performLayout') || c.contains('during layout') || c.contains('performResize')) return 'layout';
  if (c.contains('paint')) return 'paint';
  return 'error';
}

final _appFrame = RegExp(r'package:k8sman/([\w/.-]+\.dart):(\d+)');

/// The first `package:k8sman/…dart:<line>` in [stack], or null.
String? firstAppFrame(String stack) {
  final m = _appFrame.firstMatch(stack);
  return m == null ? null : 'package:k8sman/${m[1]}:${m[2]}';
}

final _creation = RegExp(r'file://[^\s:]*?/lib/([\w/.-]+\.dart):(\d+)');

/// A widget's creation location (`lib/…dart:<line>`) in an error's text
/// (debug builds add "The relevant error-causing widget was: …").
String? creationLocation(String text) {
  final m = _creation.firstMatch(text);
  return m == null ? null : 'lib/${m[1]}:${m[2]}';
}

/// For a build error, the widget being built ("building PodPanel(dirty)").
String? _widgetFromContext(FlutterErrorDetails d) {
  final m = RegExp(r'^building ([A-Za-z_$][\w$]*)').firstMatch('${d.context ?? ''}');
  return m?[1];
}


/// What an error's information names: the widget (and its context in the
/// app) from a render object's creator, which debug builds keep.
({String? widget, String? context, bool hasInformation}) _information(FlutterErrorDetails d) {
  String? widget;
  String? context;
  var has = false;
  try {
    final nodes = d.informationCollector?.call().toList() ?? const <DiagnosticsNode>[];
    has = nodes.isNotEmpty;
    Element? element;
    for (final n in nodes) {
      final v = n.value;
      if (v is DebugCreator) {
        element = v.element;
        break;
      }
      if (v is RenderObject && v.debugCreator is DebugCreator) {
        element = (v.debugCreator as DebugCreator).element;
        break;
      }
    }
    if (element != null) {
      widget = element.widget.runtimeType.toString();
      final c = diagnosticsContextOf(element);
      if (c.isNotEmpty) context = c;
    }
  } catch (_) {}
  return (widget: widget, context: context, hasInformation: has);
}

/// The details as the console shows them (in debug, with the widget's
/// creation location).
String _text(FlutterErrorDetails d) {
  try {
    return d.toString();
  } catch (_) {
    return '';
  }
}


// ---- context ----

/// Names a part of the app for diagnostics: errors inside it are reported
/// as happening there ("Pod inspector › Containers"). Labels nest.
class DiagnosticsContext extends InheritedWidget {
  final String label;
  const DiagnosticsContext({super.key, required this.label, required super.child});

  @override
  bool updateShouldNotify(DiagnosticsContext oldWidget) => false;
}

/// The [DiagnosticsContext] labels above [context], outermost first,
/// joined with ›. Walks the tree: for errors only.
String diagnosticsContextOf(BuildContext context) {
  final labels = <String>[];
  void take(Element e) {
    final w = e.widget;
    if (w is DiagnosticsContext && w.label.isNotEmpty && (labels.isEmpty || labels.last != w.label)) labels.add(w.label);
  }

  if (context is Element) take(context);
  context.visitAncestorElements((e) {
    take(e);
    return true;
  });
  return labels.reversed.join(' › ');
}

// ---- redaction ----


const _keepNamespaces = {'default', 'kube-system', 'kube-public', 'kube-node-lease'};

final _ipv4 = RegExp(r'(?<![\w.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?:/\d{1,2})?(?!\w|\.\d)');
final _ipv6 = RegExp(
  r'(?<![\w:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?|::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?)(?:%\w+)?(?![\w:])',
);
final _email = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
final _bearer = RegExp(r'(Bearer\s+|token[=:]\s*)\S+', caseSensitive: false);
final _home = RegExp(r'(/Users/|/home/|[A-Za-z]:\\Users\\)[^/\\\s]+');
final _url = RegExp(r'(https?|wss?)://[^/\s"\x27]+');
final _host = RegExp(r'(?<![\w.:/@<-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}(?![\w-]|\.\w)');
final _apiNamespace = RegExp(r'(/namespaces/)([^/\s?"\x27]+)(?:(/[a-z0-9.-]+/)([^/\s?"\x27]+))?');
final _keyed = RegExp(r'''(\b(?:name|namespace|pod|node|container|context|cluster|host|hostname|server)["']?\s*[:=]\s*["']?)([A-Za-z0-9][\w.:@-]*)''', caseSensitive: false);

/// Names Kubernetes generates (`web-7d9c8b6f5-x2k9q`, `web-x2k9q`): the
/// random parts use an alphabet without vowels, so ordinary words stay.
final _generated = RegExp(r'\b[a-z0-9]+(?:-[a-z0-9]+)*-(?:[bcdfghjklmnpqrstvwxz2456789]{8,10}-)?[bcdfghjklmnpqrstvwxz2456789]{5}\b');

/// Code locations (`package:…`, `dart:…`, `file://…`): left as they are
/// (beyond the home folder), so library names and lines stay.
final _code = RegExp(r'(?:package|dart|file):[^\s)]+');

/// Last labels that make a dotted word a host.
const _tlds = {
  'com', 'net', 'org', 'io', 'dev', 'local', 'internal', 'cloud', 'app', 'co', 'uk', 'de', 'svc', 'cluster', 'lan', 'corp', //
  'home', 'ai', 'sh', 'me', 'us', 'eu', 'info', 'biz', 'xyz', 'tech', 'site', 'cn', 'jp', 'fr', 'nl', 'au', 'ca', 'in', 'gov', 'edu',
};

final _codeFile = RegExp(r'\.(dart|go|json|yaml|yml|js|ts|md|swift|txt|html)$');

/// [text] with what could identify a cluster replaced by placeholders:
/// IPv4/IPv6 addresses (`<ip>`), hostnames and URLs' hosts (`<host>`),
/// e-mail addresses, bearer tokens, home folders, Kubernetes object names
/// and namespaces where recognisable (`<name>`, `<namespace>`: in API
/// paths, after `name:`-style keys, generated pod names) and [terms] (the
/// app's contexts, clusters, namespaces and open object: `<redacted>`).
/// Widget and library names, code locations and plain numbers stay.
String redactDiagnostics(String text, {Iterable<String> terms = const []}) {
  if (text.isEmpty) return text;
  final s = text.replaceAllMapped(_home, (m) => '${m[1]}<user>');
  // Known names, longest first, as whole words.
  final known = {
    for (final t in terms)
      if (t.trim().length >= 3 && !_keepNamespaces.contains(t.trim())) t.trim(),
  }.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final knownRe = known.isEmpty ? null : RegExp('(?<![\\w.-])(?:${known.map(RegExp.escape).join('|')})(?![\\w-])');
  String redact(String p) {
    if (knownRe != null) p = p.replaceAll(knownRe, '<redacted>');
    return p
        .replaceAllMapped(_bearer, (m) => '${m[1]}<token>')
        .replaceAllMapped(_url, (m) => '${m[1]}://<host>')
        .replaceAll(_email, '<email>')
        .replaceAll(_ipv6, '<ip>')
        .replaceAll(_ipv4, '<ip>')
        .replaceAllMapped(_apiNamespace, (m) => '${m[1]}<namespace>${m[3] == null ? '' : '${m[3]}<name>'}')
        .replaceAllMapped(_keyed, (m) => '${m[1]}<${_placeholder(m[0]!)}>')
        .replaceAll(_generated, '<name>')
        .replaceAllMapped(_host, (m) {
          final h = m[0]!;
          // API groups and Dart member access stay.
          if (h.endsWith('k8s.io') || h.startsWith('this.') || h.startsWith('widget.')) return h;
          final last = h.substring(h.lastIndexOf('.') + 1);
          final labels = '.'.allMatches(h).length + 1;
          return _tlds.contains(last) || (labels >= 3 && !_codeFile.hasMatch(h)) ? '<host>' : h;
        });
  }

  // Redact between the code locations, which stay as they are.
  final out = StringBuffer();
  var at = 0;
  for (final m in _code.allMatches(s)) {
    out
      ..write(redact(s.substring(at, m.start)))
      ..write(m[0]);
    at = m.end;
  }
  out.write(redact(s.substring(at)));
  return out.toString();
}

String _placeholder(String keyed) {
  final k = keyed.toLowerCase();
  if (k.startsWith('namespace')) return 'namespace';
  if (k.startsWith('host') || k.startsWith('server')) return 'host';
  if (k.startsWith('context') || k.startsWith('cluster')) return 'redacted';
  return 'name';
}
