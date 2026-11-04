import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k8sman/app/updates/github_releases.dart';
import 'package:k8sman/app/updates/update_controller.dart';
import 'package:k8sman/app/updates/update_ui.dart';
import 'package:k8sman/app/updates/version.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

const _channel = UpdateController.channel;

Map<String, Object?> _nativeInfo({
  String version = '0.1.0',
  bool enabled = true,
  bool automaticChecks = true,
  DateTime? lastCheck,
  String? disabledReason,
  Map<String, Object?>? available,
}) =>
    {
      'version': version,
      'build': version,
      'enabled': enabled,
      'automaticChecks': automaticChecks,
      'lastCheck': ?lastCheck?.millisecondsSinceEpoch,
      'disabledReason': ?disabledReason,
      'available': ?available,
    };

const _update = {
  'version': '0.1.1',
  'build': '0.1.1',
  'releaseNotesURL': 'https://github.com/matty234/k8sman/releases/tag/v0.1.1',
  'date': 1762171200000,
  'size': 31457280,
  'critical': false,
};

/// Fake native side of `k8sman/updates`; records calls.
class _FakeNative {
  final calls = <String>[];
  Map<String, Object?> info;
  bool canCheck = true;
  _FakeNative(this.info);

  void install(WidgetTester? tester) {
    final messenger = tester?.binding.defaultBinaryMessenger ??
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'info':
          return info;
        case 'setAutomaticChecks':
          info = {...info, 'automaticChecks': call.arguments};
          return info;
        case 'checkInBackground':
          return canCheck;
        default:
          return true;
      }
    });
  }
}

Widget _wrap(Widget child, UpdateController u) => ChangeNotifierProvider<UpdateController>.value(
      value: u,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SemVer', () {
    test('parses with v prefix, pre-release and build metadata', () {
      final v = SemVer.tryParse('v1.2.3-beta.2+77')!;
      expect([v.major, v.minor, v.patch], [1, 2, 3]);
      expect(v.pre, ['beta', '2']);
      expect(v.build, '77');
      expect(SemVer.tryParse('1.4')!.toString(), '1.4.0');
      expect(SemVer.tryParse('nope'), isNull);
      expect(SemVer.tryParse(''), isNull);
      expect(SemVer.tryParse('1.2.3.4'), isNull);
    });

    test('orders versions per semver', () {
      final ordered = ['0.0.9', '0.1.0-alpha', '0.1.0-alpha.1', '0.1.0-alpha.beta', '0.1.0-beta.2', '0.1.0-beta.11', '0.1.0-rc.1', '0.1.0', '0.1.1', '0.2.0', '0.10.0', '1.0.0']
          .map((s) => SemVer.tryParse(s)!)
          .toList();
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(ordered[i] < ordered[i + 1], isTrue, reason: '${ordered[i]} < ${ordered[i + 1]}');
        expect(ordered[i + 1] > ordered[i], isTrue);
      }
      expect(SemVer.tryParse('v1.0.0+5'), SemVer.tryParse('1.0.0+9'));
    });

    test('dev versions', () {
      expect(isDevVersion('0.0.0'), isTrue);
      expect(isDevVersion('1.2.0-dev'), isTrue);
      expect(isDevVersion(''), isTrue);
      expect(isDevVersion(null), isTrue);
      expect(isDevVersion('0.1.0'), isFalse);
      expect(isDevVersion('0.1.0-rc.1'), isFalse);
    });
  });

  group('native payloads', () {
    test('UpdaterInfo and AvailableUpdate parse the channel maps', () {
      final at = DateTime(2026, 11, 2, 9);
      final i = UpdaterInfo.fromNative(_nativeInfo(lastCheck: at, available: _update));
      expect(i.version, '0.1.0');
      expect(i.displayVersion, '0.1.0');
      expect(i.nativeEnabled, isTrue);
      expect(i.lastCheck, at);
      final a = i.available!;
      expect(a.label, 'v0.1.1');
      expect(a.releaseNotes.toString(), endsWith('/v0.1.1'));
      expect(a.size, 31457280);
      expect(a.date, isNotNull);
      expect(UpdaterInfo.fromNative({'version': '0.1.0', 'build': '7'}).displayVersion, '0.1.0 (7)');
      expect(UpdaterInfo.fromNative(null).nativeEnabled, isFalse);
      expect(AvailableUpdate.fromNative({'version': ''}), isNull);
      expect(AvailableUpdate.fromNative('x'), isNull);
    });
  });

  group('schedule', () {
    const s = UpdateSchedule(); // every 6 h; at launch if older than 3 h
    final now = DateTime(2026, 11, 3, 12);
    DateTime ago(int h, [int m = 0]) => now.subtract(Duration(hours: h, minutes: m));

    test('due when never checked, after the interval, or when the clock went backwards', () {
      expect(s.isDue(now: now), isTrue);
      expect(s.isDue(now: now, lastCheck: ago(5)), isFalse);
      expect(s.isDue(now: now, lastCheck: ago(6)), isTrue);
      expect(s.isDue(now: now, lastCheck: now.add(const Duration(days: 3))), isTrue);
    });

    test('a launch checks sooner', () {
      expect(s.isDue(now: now, lastCheck: ago(2), atLaunch: true), isFalse);
      expect(s.isDue(now: now, lastCheck: ago(3), atLaunch: true), isTrue);
    });

    test('next delay from launch', () {
      expect(s.nextDelay(now: now), const Duration(seconds: 20));
      expect(s.nextDelay(now: now, lastCheck: ago(4)), const Duration(seconds: 20));
      expect(s.nextDelay(now: now, lastCheck: ago(2)), const Duration(hours: 4));
    });
  });

  group('disabling', () {
    test('dev builds, dev versions and an unconfigured updater are off', () {
      const on = UpdaterInfo(version: '0.1.0', nativeEnabled: true);
      expect(updatesDisabledReason(releaseMode: true, info: on), isNull);
      expect(updatesDisabledReason(releaseMode: false, info: on), 'development build');
      expect(updatesDisabledReason(releaseMode: true, info: const UpdaterInfo(version: '0.0.0', nativeEnabled: true)), contains('development version'));
      expect(updatesDisabledReason(releaseMode: true, info: const UpdaterInfo(version: '0.1.0', disabledReason: 'no update signing key configured')),
          'no update signing key configured');
    });

    test('a debug (flutter run) controller never checks', () async {
      final native = _FakeNative(_nativeInfo())..install(null);
      final u = UpdateController(releaseMode: false);
      await u.start();
      expect(u.enabled, isFalse);
      expect(u.hasScheduledCheck, isFalse);
      expect(await u.checkIfDue(), isFalse);
      expect(native.calls, isNot(contains('checkInBackground')));
      u.dispose();
    });
  });

  group('controller', () {
    test('checks in the background when due, then not again the same day', () async {
      var now = DateTime(2026, 11, 3, 12);
      final native = _FakeNative(_nativeInfo(lastCheck: now.subtract(const Duration(days: 2))))..install(null);
      final u = UpdateController(releaseMode: true, now: () => now);
      await u.start();
      expect(u.enabled, isTrue);
      expect(u.hasScheduledCheck, isTrue);
      expect(await u.checkIfDue(), isTrue);
      expect(native.calls.where((c) => c == 'checkInBackground'), hasLength(1));
      now = now.add(const Duration(hours: 5));
      expect(await u.checkIfDue(), isFalse);
      now = now.add(const Duration(hours: 20));
      expect(await u.checkIfDue(), isTrue);
      u.dispose();
    });

    test('turning automatic checks off persists natively and unschedules', () async {
      final native = _FakeNative(_nativeInfo())..install(null);
      final u = UpdateController(releaseMode: true);
      await u.start();
      expect(u.hasScheduledCheck, isTrue);
      await u.setAutomaticChecks(false);
      expect(native.calls, contains('setAutomaticChecks'));
      expect(u.automaticChecks, isFalse);
      expect(u.hasScheduledCheck, isFalse);
      expect(await u.checkIfDue(), isFalse);
      u.dispose();
    });

    test('native pushes drive the banner state', () async {
      _FakeNative(_nativeInfo()).install(null);
      final u = UpdateController(releaseMode: true);
      await u.start();
      await u.handleNativeCall(const MethodCall('updateAvailable', _update));
      expect(u.bannerUpdate?.version, '0.1.1');
      u.dismiss();
      expect(u.bannerUpdate, isNull);
      await u.handleNativeCall(const MethodCall('updateAvailable', _update));
      expect(u.bannerUpdate, isNull, reason: 'dismissed for this version');
      await u.handleNativeCall(MethodCall('updateAvailable', {..._update, 'version': '0.1.2'}));
      expect(u.bannerUpdate?.version, '0.1.2');
      await u.handleNativeCall(const MethodCall('attended'));
      expect(u.bannerUpdate, isNull);
      var shown = 0;
      u.onShowAbout = () => shown++;
      await u.handleNativeCall(const MethodCall('showAbout'));
      expect(shown, 1);
      u.dispose();
    });
  });

  group('widgets', () {
    testWidgets('UpdateBanner shows the version, notes and Install', (tester) async {
      var installs = 0, dismissed = 0;
      final opened = <Uri>[];
      final update = AvailableUpdate.fromNative(_update)!;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: UpdateBanner(
              update: update,
              onInstall: () => installs++,
              onDismiss: () => dismissed++,
              openUrl: (u) async => opened.add(u),
            ),
          ),
        ),
      ));
      expect(find.text('Update available: v0.1.1'), findsOneWidget);
      await tester.tap(find.text('Release Notes'));
      expect(opened.single.path, '/matty234/k8sman/releases/tag/v0.1.1');
      await tester.tap(find.text('Install & Relaunch…'));
      expect(installs, 1);
      await tester.tap(find.byIcon(Icons.close));
      expect(dismissed, 1);
    });

    testWidgets('UpdateHost shows the banner over the app and hides it on dismiss', (tester) async {
      final native = _FakeNative(_nativeInfo())..install(tester);
      final u = UpdateController(releaseMode: true);
      await u.start();
      await tester.pumpWidget(ChangeNotifierProvider<UpdateController>.value(
        value: u,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          navigatorKey: u.navigatorKey,
          builder: (context, child) => UpdateHost(child: child!),
          home: const Scaffold(body: Text('app')),
        ),
      ));
      expect(find.byType(UpdateBanner), findsNothing);
      await u.handleNativeCall(const MethodCall('updateAvailable', _update));
      await tester.pump();
      expect(find.byType(UpdateBanner), findsOneWidget);
      await tester.tap(find.text('Install & Relaunch…'));
      expect(native.calls.last, 'install');
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byType(UpdateBanner), findsNothing);

      // The app menu's About item opens the About panel.
      await u.handleNativeCall(const MethodCall('showAbout'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPanel), findsOneWidget);
      expect(find.text('Version 0.1.0'), findsOneWidget);
      u.dispose();
    });

    testWidgets('About panel: version, automatic-check toggle and Check Now', (tester) async {
      final now = DateTime(2026, 11, 3, 12);
      final native = _FakeNative(_nativeInfo(version: '0.1.0', lastCheck: now.subtract(const Duration(hours: 3))))..install(tester);
      final u = UpdateController(releaseMode: true, now: () => now);
      await u.start();
      await tester.pumpWidget(_wrap(AboutPanel(now: () => now), u));
      expect(find.text('k8sman'), findsOneWidget);
      expect(find.text('Version 0.1.0'), findsOneWidget);
      expect(find.text('Last checked 3 h ago.'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(native.calls, contains('setAutomaticChecks'));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.text('Check Now'));
      expect(native.calls.last, 'checkNow');

      await u.handleNativeCall(const MethodCall('updateAvailable', _update));
      await tester.pump();
      expect(find.text('Version v0.1.1 is available.'), findsOneWidget);
      await tester.tap(find.text('Install…'));
      expect(native.calls.last, 'install');
      u.dispose();
    });

    testWidgets('About panel in a dev build says updates are off', (tester) async {
      _FakeNative(_nativeInfo(version: '0.0.0', enabled: false, disabledReason: 'development build')).install(tester);
      final u = UpdateController(releaseMode: false);
      await u.start();
      await tester.pumpWidget(_wrap(const AboutPanel(), u));
      expect(find.text('Version 0.0.0'), findsOneWidget);
      expect(find.text('Updates are off: development build.'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Check Now'), findsNothing);
      u.dispose();
    });
  });

  test('without Sparkle (Windows): GitHub latest release, opened to download', () async {
    final latest = {'tag_name': 'v0.2.0', 'html_url': 'https://github.com/matty234/k8sman/releases/tag/v0.2.0'};
    expect(GitHubReleases.parseLatest(latest, '0.2.0'), isNull);
    expect(GitHubReleases.parseLatest({...latest, 'tag_name': 'v0.1.9'}, '0.2.0'), isNull);
    expect(GitHubReleases.parseLatest(latest, 'not-a-version'), isNull);

    final opened = <Uri>[];
    final releases = GitHubReleases(client: () => MockClient((_) async => http.Response(jsonEncode(latest), 200)));
    final u = UpdateController(releaseMode: true, github: releases, version: '0.1.0', openUrl: (url) async => opened.add(url));
    await u.start();
    expect(u.enabled, isTrue);
    expect(await u.checkIfDue(), isTrue);
    expect(u.bannerUpdate?.label, 'v0.2.0');
    await u.install();
    expect(opened.single.path, '/matty234/k8sman/releases/tag/v0.2.0');
    expect(await u.checkIfDue(), isFalse, reason: 'checked today');
    u.dispose();
  });
}
