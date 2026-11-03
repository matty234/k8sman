import 'dart:convert';

import 'package:http/http.dart' as http;

import 'update_controller.dart';
import 'version.dart';

/// The app version baked in at build time (`--dart-define=K8SMAN_VERSION=…`,
/// set by the Windows release build). Empty in local builds, which therefore
/// never check.
const buildVersion = String.fromEnvironment('K8SMAN_VERSION');

/// Update checks without Sparkle (Windows): asks GitHub for the latest
/// release and, if it is newer, offers its page to download from. Nothing
/// is installed automatically.
class GitHubReleases {
  final Uri latest;
  final http.Client Function() _client;

  GitHubReleases({Uri? latest, http.Client Function()? client})
      : latest = latest ?? Uri.parse('https://api.github.com/repos/matty234/k8sman/releases/latest'),
        _client = client ?? http.Client.new;

  /// The latest release if it is newer than [current], else null. Throws on
  /// network or HTTP errors.
  Future<AvailableUpdate?> newerThan(String current) async {
    final c = _client();
    try {
      final r = await c
          .get(latest, headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('GitHub returned HTTP ${r.statusCode}');
      return parseLatest(jsonDecode(r.body), current);
    } finally {
      c.close();
    }
  }

  /// The update described by a `releases/latest` response, if it is newer
  /// than [current].
  static AvailableUpdate? parseLatest(Object? json, String current) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final have = SemVer.tryParse(current);
    final next = SemVer.tryParse(tag);
    if (have == null || next == null || !(next > have) || json['draft'] == true) return null;
    final page = json['html_url'];
    final date = json['published_at'];
    return AvailableUpdate(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      releaseNotes: page is String ? Uri.tryParse(page) : null,
      date: date is String ? DateTime.tryParse(date) : null,
    );
  }
}
