// Memory benchmark scenario driver (tools/membench). build.sh copies it into
// frontend/lib for one build only; it runs the scenario inside the app, so
// nothing has to take keyboard focus.
// Prints "BENCH <step>" lines on stdout.
import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'api/models.dart';
import 'state/app_state.dart';
import 'state/log_dock.dart';
import 'ui/palette/command_palette.dart';
import 'ui/shell.dart';
import 'ui/terminal/open_terminal.dart';

const benchStartDelay = int.fromEnvironment('K8SMAN_BENCH_START', defaultValue: 20);

void _say(String s) {
  stdout.writeln('BENCH $s');
}

Future<void> _wait(double s) => Future<void>.delayed(Duration(milliseconds: (s * 1000).round()));

BuildContext? _shellContext() {
  BuildContext? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget is Shell) {
      // A context below the Shell (inside its providers/overlay).
      e.visitChildren((c) => found ??= c);
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> runBenchScenario(AppState app, ApiClient api) async {
  await _wait(benchStartDelay.toDouble());
  while (app.loading || app.types.isEmpty) {
    await _wait(0.5);
  }
  final ctx = _shellContext();
  if (ctx == null) {
    _say('error no-shell');
    return;
  }
  _say('start');
  app.setNamespace(null);
  for (final k in ['Pod', 'ConfigMap', 'Secret', 'Deployment', 'Service']) {
    final t = app.typeFor(k == 'Deployment' ? 'apps' : '', k);
    if (t != null) app.selectType(t);
    await _wait(3);
  }
  ResourceType t(String g, String k) => app.typeFor(g, k)!;
  final targets = [
    DetailTarget(type: t('apps', 'Deployment'), name: 'dep-001', namespace: 'bulk-1'),
    DetailTarget(type: t('', 'ConfigMap'), name: 'cfg-010', namespace: 'bulk-0'),
    DetailTarget(type: t('', 'Service'), name: 'svc-005', namespace: 'bulk-2'),
  ];
  for (final d in targets) {
    app.openDetail(d);
    await _wait(2.5);
  }
  final pods = await api.table(t('', 'Pod').ref, namespace: 'kube-system', labelSelector: 'component=kube-apiserver', includeObject: true);
  final pod = pods.rows.first;
  app.openDetail(DetailTarget(type: t('', 'Pod'), name: pod.name, namespace: pod.namespace));
  await _wait(2.5);
  if (!ctx.mounted) return;
  ctx.read<LogDock>().open(pod.object!);
  await _wait(3);
  if (!ctx.mounted) return;
  openLocalShell(ctx);
  await _wait(3);
  if (!ctx.mounted) return;
  showCommandPalette(ctx);
  await _wait(3);
  if (!ctx.mounted) return;
  showCommandPalette(ctx); // toggles it closed
  await _wait(2);
  _stats();
  _say('done');
  Timer.periodic(const Duration(seconds: 60), (_) => _stats());
}

void _stats() {
  final ic = PaintingBinding.instance.imageCache;
  _say('stats imageCache=${(ic.currentSizeBytes / 1024).round()}KB images=${ic.currentSize} live=${ic.liveImageCount}');
}
