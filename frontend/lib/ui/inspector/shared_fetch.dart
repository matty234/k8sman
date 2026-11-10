import 'dart:async';

import 'package:flutter/material.dart';

/// A small session cache so a header and a section can share one fetch
/// (e.g. the Used by report both count and list). Keys should include the
/// API client's identity and whatever should trigger a refetch; a failed
/// fetch is dropped so the next build retries.
class SharedFetch {
  SharedFetch._();
  // Each entry remembers the zone that fetched it: a future from another
  // zone (a finished widget test) never delivers here, so it's refetched.
  static final _cache = <String, (Zone, Future<Object?>)>{};

  /// Bumped by [invalidate], so listeners rebuild and fetch again.
  static final changes = ValueNotifier<int>(0);

  static Future<T> get<T>(String key, Future<T> Function() fetch) {
    final hit = _cache.remove(key);
    if (hit != null && identical(hit.$1, Zone.current)) {
      _cache[key] = hit;
      return hit.$2 as Future<T>;
    }
    final f = fetch();
    _cache[key] = (Zone.current, f);
    f.then((_) {}, onError: (Object _) {
      if (identical(_cache[key]?.$2, f)) _cache.remove(key);
    });
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }

  /// Whether [key] is cached (fetched or in flight) in this zone.
  static bool has(String key) => identical(_cache[key]?.$1, Zone.current);

  /// Drops every entry whose key starts with [prefix] and notifies.
  static void invalidate(String prefix) {
    _cache.removeWhere((k, _) => k.startsWith(prefix));
    changes.value++;
  }
}

/// Builds from a [SharedFetch] entry, rebuilding after an invalidation.
class SharedFetchBuilder<T> extends StatelessWidget {
  final String fetchKey;
  final Future<T> Function() fetch;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snap) builder;
  const SharedFetchBuilder({super.key, required this.fetchKey, required this.fetch, required this.builder});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: SharedFetch.changes,
        builder: (context, _, _) => FutureBuilder<T>(future: SharedFetch.get<T>(fetchKey, fetch), builder: builder),
      );
}
