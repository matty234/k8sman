import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k8sman/app/updates/github_releases.dart';
import 'package:k8sman/app/updates/update_controller.dart';
import 'package:k8sman/app/updates/update_ui.dart';
import 'package:k8sman/app/updates/version.dart';
import 'package:k8sman/ui/theme.dart';

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

  });

  group('native payloads', () {
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
