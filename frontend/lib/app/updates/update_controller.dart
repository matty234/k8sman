import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'github_releases.dart';
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

/// When background checks run (wall clock, so time asleep counts): every
/// [interval], plus [startupDelay] after launch when the last check is older
/// than [launchInterval], so a fresh release reaches users within hours.
class UpdateSchedule {
  final Duration interval;
  final Duration launchInterval;
  final Duration startupDelay;
  const UpdateSchedule({
    this.interval = const Duration(hours: 6),
    this.launchInterval = const Duration(hours: 3),
    this.startupDelay = const Duration(seconds: 20),
  });

  bool isDue({required DateTime now, DateTime? lastCheck, bool atLaunch = false}) =>
      lastCheck == null || lastCheck.isAfter(now) || now.difference(lastCheck) >= (atLaunch ? launchInterval : interval);

  /// Delay from launch until the first check.
  Duration nextDelay({required DateTime now, DateTime? lastCheck}) {
    if (isDue(now: now, lastCheck: lastCheck, atLaunch: true)) return startupDelay;
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
/// checks, verifies, installs and relaunches; this schedules the periodic
/// background check, keeps the user's setting, and drives the banner and
/// About panel.
///
/// With [github] (Windows) there is no Sparkle: the periodic check asks GitHub
/// for the latest release and "install" opens its download page.
class UpdateController extends ChangeNotifier {
  static const channel = MethodChannel('k8sman/updates');

  final UpdateSchedule schedule;
  final bool releaseMode;
  final DateTime Function() _now;
  final GitHubReleases? github;

  /// This app's version when [github] is used.
  final String version;

  /// Opens a URL (the release page); replaced in tests.
  final Future<void> Function(Uri) openUrl;

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

  UpdateController({
    this.schedule = const UpdateSchedule(),
    bool? releaseMode,
    DateTime Function()? now,
    this.github,
    this.version = buildVersion,
    Future<void> Function(Uri)? openUrl,
  })  : releaseMode = releaseMode ?? kReleaseMode,
        _now = now ?? DateTime.now,
        openUrl = openUrl ?? ((_) async {});

  /// Updates are downloaded by hand from the release page (no Sparkle).
  bool get manualInstall => github != null;

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
    if (github != null) {
      info = UpdaterInfo(version: version, nativeEnabled: true, lastCheck: info.lastCheck, available: available);
      notifyListeners();
      return;
    }
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

  /// Turn the background checks on or off (persisted natively in the
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
  Future<void> checkNow() async {
    if (github != null) {
      await _checkGitHub();
      return;
    }
    await _invoke('checkNow');
  }

  /// "Install & Relaunch…": brings Sparkle's window for the pending update
  /// into focus (release notes, Install; then Install and Relaunch). With
  /// [github]: opens the release page to download it from.
  Future<void> install() async {
    if (github != null) {
      final page = available?.releaseNotes;
      if (page != null) await openUrl(page);
      return;
    }
    await _invoke('install');
  }

  /// Asks GitHub for a newer release. Returns whether it asked.
  Future<bool> _checkGitHub() async {
    if (checking) return false;
    checking = true;
    notifyListeners();
    try {
      available = await github!.newerThan(version);
      lastError = null;
    } catch (e) {
      lastError = '$e';
    } finally {
      checking = false;
      info = _withLastCheck(_now());
      notifyListeners();
    }
    return true;
  }

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
  Future<bool> checkIfDue({bool atLaunch = false}) async {
    if (!enabled || !automaticChecks || checking) return false;
    if (!schedule.isDue(now: _now(), lastCheck: info.lastCheck, atLaunch: atLaunch)) return false;
    if (github != null) return _checkGitHub();
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
        available: github != null ? available : info.available,
      );

  void _reschedule() {
    _startup?.cancel();
    _tick?.cancel();
    _startup = _tick = null;
    if (!enabled || !automaticChecks) return;
    _startup = Timer(schedule.nextDelay(now: _now(), lastCheck: info.lastCheck), () => checkIfDue(atLaunch: true));
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
