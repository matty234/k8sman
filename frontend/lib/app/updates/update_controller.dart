import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'version.dart';

/// An update offered by the feed (Sparkle's appcast item), as sent by
/// `UpdateController.swift`.
@immutable
class AvailableUpdate {
  final String version;
  final String build;
  final Uri? releaseNotes;
  final DateTime? date;
  final int? size;
  final bool critical;

  const AvailableUpdate({required this.version, this.build = '', this.releaseNotes, this.date, this.size, this.critical = false});

  static AvailableUpdate? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    if (version is! String || version.isEmpty) return null;
    final notes = raw['releaseNotesURL'];
    final date = raw['date'];
    final size = raw['size'];
    return AvailableUpdate(
      version: version,
      build: raw['build'] as String? ?? '',
      releaseNotes: notes is String ? Uri.tryParse(notes) : null,
      date: date is int ? DateTime.fromMillisecondsSinceEpoch(date) : null,
      size: size is int ? size : null,
      critical: raw['critical'] == true,
    );
  }

  /// `v1.2.3` (or the raw string if it isn't a version).
  String get label => SemVer.tryParse(version) != null && !version.startsWith('v') ? 'v$version' : version;
}

/// The native updater's state (`info` on the `k8sman/updates` channel).
@immutable
class UpdaterInfo {
  final String version;
  final String build;

  /// Sparkle is running (release build with a key and feed).
  final bool nativeEnabled;
  final String? disabledReason;
  final bool automaticChecks;
  final DateTime? lastCheck;
  final String? feedUrl;
  final AvailableUpdate? available;

  const UpdaterInfo({
    this.version = '',
    this.build = '',
    this.nativeEnabled = false,
    this.disabledReason,
    this.automaticChecks = true,
    this.lastCheck,
    this.feedUrl,
    this.available,
  });

  static UpdaterInfo fromNative(Object? raw) {
    if (raw is! Map) return const UpdaterInfo(disabledReason: 'not available on this platform');
    final last = raw['lastCheck'];
    return UpdaterInfo(
      version: raw['version'] as String? ?? '',
      build: raw['build'] as String? ?? '',
      nativeEnabled: raw['enabled'] == true,
      disabledReason: raw['disabledReason'] as String?,
      automaticChecks: raw['automaticChecks'] != false,
      lastCheck: last is int ? DateTime.fromMillisecondsSinceEpoch(last) : null,
      feedUrl: raw['feedURL'] as String?,
      available: AvailableUpdate.fromNative(raw['available']),
    );
  }

  /// "0.1.0" or "0.1.0 (42)" when the build number differs.
  String get displayVersion => build.isEmpty || build == version ? version : '$version ($build)';
}

/// When background checks run: at most once per [interval] (wall clock, so
/// time asleep counts), first [startupDelay] after launch.
class UpdateSchedule {
  final Duration interval;
  final Duration startupDelay;
  const UpdateSchedule({this.interval = const Duration(days: 1), this.startupDelay = const Duration(seconds: 20)});

  bool isDue({required DateTime now, DateTime? lastCheck}) =>
      lastCheck == null || lastCheck.isAfter(now) || now.difference(lastCheck) >= interval;

  /// Delay until the next check from [now].
  Duration nextDelay({required DateTime now, DateTime? lastCheck}) {
    if (isDue(now: now, lastCheck: lastCheck)) return startupDelay;
    final left = interval - now.difference(lastCheck!);
    return left < startupDelay ? startupDelay : left;
  }
}

/// Why updates are off in this build, or null when they're on.
String? updatesDisabledReason({required bool releaseMode, required UpdaterInfo info}) {
  if (!releaseMode) return 'development build';
  if (!info.nativeEnabled) return info.disabledReason ?? 'updater unavailable';
  if (isDevVersion(info.version)) return 'development version (${info.version.isEmpty ? 'unknown' : info.version})';
  return null;
}

/// Dart side of in-app updates. Sparkle (macos/Runner/UpdateController.swift)
/// checks, verifies, installs and relaunches; this schedules the daily
/// background check, keeps the user's setting, and drives the banner and
/// About panel.
class UpdateController extends ChangeNotifier {
  static const channel = MethodChannel('k8sman/updates');

  final UpdateSchedule schedule;
  final bool releaseMode;
  final DateTime Function() _now;

  /// Used to show the About panel from the app menu.
  final navigatorKey = GlobalKey<NavigatorState>();

  /// Shows the About panel; set by the UI (see `UpdateHost`).
  void Function()? onShowAbout;

  UpdaterInfo info = const UpdaterInfo();
  AvailableUpdate? available;

  /// The user closed the banner for this version (it returns on the next
  /// day's check or via Check for Updates…).
  String? dismissedVersion;
  String? lastError;
  bool checking = false;

  Timer? _startup, _tick;

  UpdateController({this.schedule = const UpdateSchedule(), bool? releaseMode, DateTime Function()? now})
      : releaseMode = releaseMode ?? kReleaseMode,
        _now = now ?? DateTime.now;

  String? get disabledReason => updatesDisabledReason(releaseMode: releaseMode, info: info);
  bool get enabled => disabledReason == null;
  bool get automaticChecks => info.automaticChecks;

  /// The update to show in the banner, if any.
  AvailableUpdate? get bannerUpdate {
    final a = available;
    if (a == null || !enabled || a.version == dismissedVersion) return null;
    return a;
  }

  Future<void> start() async {
    channel.setMethodCallHandler(handleNativeCall);
    await refresh();
    _reschedule();
  }

  Future<void> refresh() async {
    try {
      info = UpdaterInfo.fromNative(await channel.invokeMethod<Object?>('info'));
      available ??= info.available;
    } on MissingPluginException {
      info = const UpdaterInfo(disabledReason: 'not running in the macOS app');
    } on PlatformException catch (e) {
      info = UpdaterInfo(disabledReason: e.message);
    }
    notifyListeners();
  }

  /// Turn the daily background check on or off (persisted natively in the
  /// app's user defaults).
  Future<void> setAutomaticChecks(bool on) async {
    try {
      info = UpdaterInfo.fromNative(await channel.invokeMethod<Object?>('setAutomaticChecks', on));
    } on MissingPluginException {
      return;
    }
    _reschedule();
    notifyListeners();
  }

  /// "Check for Updates…": Sparkle shows its own progress and result.
  Future<void> checkNow() => _invoke('checkNow');

  /// "Install & Relaunch…": brings Sparkle's window for the pending update
  /// into focus (release notes, Install; then Install and Relaunch).
  Future<void> install() => _invoke('install');

  void dismiss() {
    dismissedVersion = available?.version;
    notifyListeners();
  }

  Future<void> _invoke(String method) async {
    try {
      await channel.invokeMethod<Object?>(method);
    } on MissingPluginException {
      // Not in the macOS app.
    }
  }

  /// Runs a background check if one is due. Returns whether it asked.
  Future<bool> checkIfDue() async {
    if (!enabled || !automaticChecks || checking) return false;
    if (!schedule.isDue(now: _now(), lastCheck: info.lastCheck)) return false;
    checking = true;
    try {
      final asked = await channel.invokeMethod<bool>('checkInBackground') ?? false;
      if (asked) info = _withLastCheck(_now());
      return asked;
    } on MissingPluginException {
      return false;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  UpdaterInfo _withLastCheck(DateTime t) => UpdaterInfo(
        version: info.version,
        build: info.build,
        nativeEnabled: info.nativeEnabled,
        disabledReason: info.disabledReason,
        automaticChecks: info.automaticChecks,
        lastCheck: t,
        feedUrl: info.feedUrl,
        available: info.available,
      );

  void _reschedule() {
    _startup?.cancel();
    _tick?.cancel();
    _startup = _tick = null;
    if (!enabled || !automaticChecks) return;
    _startup = Timer(schedule.nextDelay(now: _now(), lastCheck: info.lastCheck), checkIfDue);
    // Re-evaluated hourly against the wall clock, so a Mac that slept
    // through the due time checks soon after waking.
    _tick = Timer.periodic(const Duration(hours: 1), (_) => checkIfDue());
  }

  @visibleForTesting
  bool get hasScheduledCheck => _startup?.isActive ?? false;

  @visibleForTesting
  Future<Object?> handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'updateAvailable':
        available = AvailableUpdate.fromNative(call.arguments);
        lastError = null;
      case 'upToDate':
        available = null;
        if (call.arguments is Map) info = UpdaterInfo.fromNative(call.arguments);
      case 'attended':
      case 'sessionFinished':
        // Sparkle's window now owns the update (or it was installed,
        // skipped or postponed).
        available = null;
      case 'error':
        lastError = call.arguments as String?;
      case 'showAbout':
        onShowAbout?.call();
      default:
        return null;
    }
    notifyListeners();
    return null;
  }

  @override
  void dispose() {
    _startup?.cancel();
    _tick?.cancel();
    super.dispose();
  }
}
