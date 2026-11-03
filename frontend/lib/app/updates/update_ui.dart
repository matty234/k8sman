import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/theme.dart';
import 'update_controller.dart';

const repoUrl = 'https://github.com/matty234/k8sman';

/// Wraps the app (`MaterialApp.builder`): shows the update banner over
/// [child] and the About panel when the app menu asks for it.
class UpdateHost extends StatefulWidget {
  final Widget child;
  const UpdateHost({super.key, required this.child});

  @override
  State<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends State<UpdateHost> {
  UpdateController? _updates;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final u = context.read<UpdateController?>();
    if (u != _updates) {
      _updates?.onShowAbout = null;
      _updates = u;
      u?.onShowAbout = _showAbout;
    }
  }

  void _showAbout() {
    final ctx = _updates?.navigatorKey.currentContext;
    if (ctx != null) showAboutPanel(ctx);
  }

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<UpdateController?>();
    final update = updates?.bannerUpdate;
    return Stack(children: [
      widget.child,
      if (updates != null && update != null)
        Positioned(
          right: 16,
          bottom: 16,
          child: UpdateBanner(
            update: update,
            manual: updates.manualInstall,
            onInstall: updates.install,
            onDismiss: updates.dismiss,
          ),
        ),
    ]);
  }
}

Future<void> _open(Uri uri) async {
  await launchUrl(uri);
}

/// A calm, dismissible "Update available" card, styled like the backend
/// crash banner.
class UpdateBanner extends StatelessWidget {
  final AvailableUpdate update;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;
  final Future<void> Function(Uri)? openUrl;

  /// No Sparkle (Windows): [onInstall] opens the release page.
  final bool manual;
  const UpdateBanner({super.key, required this.update, required this.onInstall, required this.onDismiss, this.openUrl, this.manual = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final notes = update.releaseNotes;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.separator),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.arrow_circle_down_outlined, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Flexible(
            child: Text('Update available: ${update.label}', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          if (notes != null && !manual)
            TextButton(
              onPressed: () => (openUrl ?? _open)(notes),
              child: const Text('Release Notes'),
            ),
          const SizedBox(width: 4),
          FilledButton(onPressed: onInstall, child: Text(manual ? 'Download…' : 'Install & Relaunch…')),
          const SizedBox(width: 2),
          // No tooltip: the banner sits above the Navigator (no Overlay).
          IconButton(
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: theme.hintColor, semanticLabel: 'Not now'),
          ),
        ]),
      ),
    );
  }
}

Future<void> showAboutPanel(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider<UpdateController>.value(
        value: context.read<UpdateController>(),
        child: const AboutPanel(),
      ),
    );

/// About k8sman: version, and the update settings.
class AboutPanel extends StatelessWidget {
  final DateTime Function() now;
  const AboutPanel({super.key, this.now = DateTime.now});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final u = context.watch<UpdateController>();
    final info = u.info;
    final reason = u.disabledReason;
    final faint = theme.textTheme.bodySmall?.copyWith(color: colors.faint);
    return AlertDialog(
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 4),
          Icon(Icons.sailing_outlined, size: 44, color: theme.colorScheme.primary),
          const SizedBox(height: 10),
          Text('k8sman', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('Version ${info.version.isEmpty ? 'unknown' : info.displayVersion}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 4),
          Text('A Kubernetes desktop app', style: faint),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.separator),
          const SizedBox(height: 10),
          if (reason != null)
            Text('Updates are off: $reason.', style: faint, textAlign: TextAlign.center)
          else ...[
            // Without Sparkle (Windows) the daily check is always on.
            if (!u.manualInstall)
              Row(children: [
                Expanded(child: Text('Check for updates automatically', style: theme.textTheme.bodyMedium)),
                Switch(value: u.automaticChecks, onChanged: u.setAutomaticChecks),
              ]),
            Row(children: [
              Expanded(
                child: Text(
                  u.available != null
                      ? 'Version ${u.available!.label} is available.'
                      : u.manualInstall && u.lastError != null
                          ? 'Could not check: ${u.lastError}'
                          : info.lastCheck == null
                          ? 'Not checked yet.'
                          : 'Last checked ${_ago(now().difference(info.lastCheck!))}.',
                  style: faint,
                ),
              ),
              TextButton(
                onPressed: u.checking ? null : (u.available != null ? u.install : u.checkNow),
                child: Text(u.available != null ? (u.manualInstall ? 'Download…' : 'Install…') : 'Check Now'),
              ),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => _open(Uri.parse(repoUrl)), child: const Text('GitHub')),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
      ],
    );
  }
}

String _ago(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
}
