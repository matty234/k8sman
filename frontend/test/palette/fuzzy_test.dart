import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/palette/fuzzy.dart';
import 'package:k8sman/ui/palette/palette_items.dart';

List<String> _rank(String q, List<String> names) {
  final scored = [
    for (final n in names)
      if (fuzzyMatch(q, n) case final m?) (n, m.score),
  ]..sort((a, b) => b.$2 - a.$2);
  return [for (final s in scored) s.$1];
}

PaletteItem _item(PaletteGroup g, String title, {List<String> aliases = const [], List<String> short = const []}) =>
    PaletteItem(group: g, title: title, typeLabel: '', icon: (_) => const SizedBox(), run: () {}, aliases: aliases, exactAliases: short);

void main() {
  test('fuzzy: exact, then prefix (shorter first), then word starts, then scattered', () {
    expect(_rank('pod', ['ReplicaSet', 'PodTemplate', 'pod-reader-xpd', 'Pod', 'PodDisruptionBudget', 'web-pod']),
        ['Pod', 'PodTemplate', 'pod-reader-xpd', 'PodDisruptionBudget', 'web-pod']);
    // camelCase and dash word starts beat letters in the middle of words.
    expect(_rank('pv', ['prevent', 'PersistentVolume', 'pvc-data']).take(2), ['pvc-data', 'PersistentVolume']);
    expect(_rank('pv', ['prevent', 'PersistentVolume']), ['PersistentVolume', 'prevent']);
    expect(_rank('pf', ['helm-platform', 'Port Forwards']), ['Port Forwards', 'helm-platform']);
    expect(fuzzyMatch('xyz', 'Deployment'), isNull);
    expect(fuzzyMatch('tolp', 'Deployment'), isNull); // out of order
    expect(fuzzyMatch('dpl', 'Deployment', positions: true)!.positions, [0, 2, 3]);
  });

  test('palette ranking: short names, aliases and group order', () {
    final items = [
      _item(PaletteGroup.pages, 'Overview'),
      _item(PaletteGroup.kinds, 'Deployment', aliases: ['deployments'], short: ['deploy']),
      _item(PaletteGroup.kinds, 'Service', aliases: ['services'], short: ['svc']),
      _item(PaletteGroup.objects, 'deploy-hook'),
      _item(PaletteGroup.objects, 'svc-gateway'),
      _item(PaletteGroup.namespaces, 'default'),
    ];
    // A short name counts as an exact hit: the kind leads.
    final svc = rankPalette('svc', items);
    expect(svc.first.group, PaletteGroup.kinds);
    expect(svc.first.items.single.title, 'Service');
    expect(svc[1].items.single.title, 'svc-gateway');

    // Plural resource names match too.
    expect(rankPalette('services', items).first.items.first.title, 'Service');

    // Groups follow their best match: an exact namespace beats a prefix kind.
    expect(rankPalette('default', items).first.group, PaletteGroup.namespaces);

    // No query: browse groups in default order, no kinds or objects.
    expect(rankPalette('', items).map((s) => s.group), [PaletteGroup.pages, PaletteGroup.namespaces]);
  });
}
