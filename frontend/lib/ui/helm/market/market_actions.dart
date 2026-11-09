/// Install, upgrade and repository actions of the charts browser. Installs
/// and upgrades go through the add-ons install dialog (version, values, dry
/// run, confirmation naming the context); repository changes write the
/// user's own repositories.yaml, after a confirmation.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../actions/actions.dart' show showActionError;
import '../../../addons/addon_status.dart';
import '../../../addons/addons.dart';
import '../../../api/client.dart';
import '../../../state/app_state.dart';
import '../../../util/diff.dart';
import '../../addons/addon_install_dialog.dart';
import '../../detail/yaml_editor.dart' show DiffView;
import '../../theme.dart';
import '../../widgets/common.dart';
import '../helm_api.dart';
import 'market_api.dart';

/// [chart] from [repoURL] as an [Addon], so the add-on install dialog can
/// install or upgrade it. [values] start the values editor.
Addon chartAddon({required String repoURL, required String chart, String? version, String description = '', String values = '', String? releaseName, String? namespace}) =>
    Addon(
      id: 'chart:$repoURL/$chart',
      name: chart,
      enables: description.isEmpty ? 'Helm chart $chart' : description,
      description: 'Version ${version ?? 'latest'}.',
      repo: repoURL,
      chart: chart,
      version: version,
      namespace: namespace ?? chart,
      releaseName: releaseName ?? chart,
      values: values,
    );

/// Opens the install dialog for [d] at [version], values starting from the
/// chart's defaults. Returns true if the cluster changed.
Future<bool> installChart(BuildContext context, ChartDetail d, {required String version, String values = '', HelmApi? api}) =>
    showAddonInstallDialog(context, chartAddon(repoURL: d.repoURL, chart: d.name, version: version, description: d.description, values: values), api: api);

/// Opens the upgrade dialog: [r] to [chart] [version] from [repoURL],
/// starting from the release's current values. Returns true if it changed.
Future<bool> upgradeReleaseTo(BuildContext context, HelmRelease r, {required String repoURL, required String chart, required String version, HelmApi? api}) {
  final addon = chartAddon(repoURL: repoURL, chart: chart, version: version, releaseName: r.name, namespace: r.namespace);
  return showAddonInstallDialog(context, addon, api: api, upgrade: AddonStatus(addon: addon, state: AddonState.installed, release: r, targetVersion: version));
}

/// The release's current computed values against [d]'s defaults at [version].
Future<void> showValuesComparison(BuildContext context, HelmApi api, HelmRelease r, {required String version, required String defaults}) async {
  HelmReleaseDetail detail;
  try {
    detail = await api.release(r.namespace, r.name);
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
    return;
  }
  if (!context.mounted) return;
  final lines = diffLines(detail.computedValues, defaults);
  final stats = diffStats(lines);
  await showDialog<void>(
    context: context,
    builder: (c) {
      final size = MediaQuery.sizeOf(c);
      final theme = Theme.of(c);
      return AlertDialog(
        title: Text('${r.name}: values against ${r.chart} $version defaults'),
        content: SizedBox(
          width: (size.width - 120).clamp(320.0, 900.0),
          height: (size.height - 240).clamp(240.0, 640.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Left: the release\'s current values (${r.chartRef} defaults with its overrides). Right: the defaults of $version. '
              '+${stats.added} −${stats.removed} lines. Upgrading keeps the release\'s own overrides.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Expanded(child: DiffView(lines: lines)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      );
    },
  );
}

/// "1.4.2 available": a quiet link that opens the upgrade.
class UpdateBadge extends StatelessWidget {
  final ChartUpdate update;
  final VoidCallback? onTap;

  /// "↑ 1.4.2", for table rows.
  final bool compact;
  const UpdateBadge(this.update, {super.key, this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final from = update.source == ChartSource.artifactHub ? 'Artifact Hub (${update.repo})' : 'repository ${update.repo}';
    return Tooltip(
      message: '${update.chart} ${update.latest} is available in $from.${onTap == null ? '' : ' Click to upgrade.'}',
      child: Hoverable(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onTap: onTap,
        builder: (h) => Container(
          key: ValueKey('update-${update.chart}'),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: h && onTap != null ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_upward, size: 10, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(compact ? update.latest : '${update.latest} available',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Asks before removing [repo] from the user's repositories.yaml.
Future<bool> confirmRemoveRepo(BuildContext context, HelmRepo repo, String configPath) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Remove repository ${repo.name}?'),
      content: SizedBox(
        width: 440,
        child: Text('Removes ${repo.name} (${repo.url}) from $configPath and deletes its cached index, like helm repo remove. '
            'Releases installed from it are not affected.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error, foregroundColor: Theme.of(c).colorScheme.onError),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// "Add repository…": name, URL and optional credentials, written to the
/// user's repositories.yaml (after the backend checks the index). Returns
/// the added repository.
Future<HelmRepo?> showAddRepoDialog(BuildContext context, HelmMarketApi api, String configPath) {
  if (context.read<AppState>().readOnly) {
    showActionError(context, 'This context is read-only, so k8sman doesn\'t change your Helm configuration.');
    return Future.value();
  }
  return showDialog<HelmRepo>(context: context, barrierDismissible: false, builder: (_) => _AddRepoDialog(api: api, configPath: configPath));
}

class _AddRepoDialog extends StatefulWidget {
  final HelmMarketApi api;
  final String configPath;
  const _AddRepoDialog({required this.api, required this.configPath});

  @override
  State<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends State<_AddRepoDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _auth = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim(), url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Name and URL are required.');
      return;
    }
    setState(() => (_busy = true, _error = null));
    try {
      final r = await widget.api.addRepo(name: name, url: url, username: _auth ? _user.text : null, password: _auth ? _pass.text : null);
      if (mounted) Navigator.pop(context, r);
    } on ApiException catch (e) {
      if (mounted) setState(() => (_busy = false, _error = e.message));
    } catch (e) {
      if (mounted) setState(() => (_busy = false, _error = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget field(String label, TextEditingController c, {String? placeholder, bool obscure = false, Key? key}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            key: key,
            controller: c,
            obscureText: obscure,
            enabled: !_busy,
            style: obscure ? null : monoStyle(context),
            decoration: InputDecoration(labelText: label, hintText: placeholder, isDense: true),
            onSubmitted: (_) => _add(),
          ),
        );
    return AlertDialog(
      title: const Text('Add Helm repository'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Adds it to ${widget.configPath}, like helm repo add. Its index is downloaded first to check the URL.', style: hint),
          const SizedBox(height: 12),
          field('Name', _name, placeholder: 'e.g. example-charts', key: const ValueKey('repo-name')),
          field('URL', _url, placeholder: 'https://charts.example.com', key: const ValueKey('repo-url')),
          Row(children: [
            SizedBox(width: 28, child: Checkbox(value: _auth, onChanged: _busy ? null : (v) => setState(() => _auth = v == true))),
            const SizedBox(width: 4),
            Text('Needs a username and password', style: theme.textTheme.bodySmall),
          ]),
          if (_auth) ...[
            const SizedBox(height: 6),
            field('Username', _user),
            field('Password', _pass, obscure: true),
            Text('Stored in ${widget.configPath}, as helm does. k8sman never shows it again.', style: hint),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            SelectableText(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _add, child: Text(_busy ? 'Checking…' : 'Add repository')),
      ],
    );
  }
}
