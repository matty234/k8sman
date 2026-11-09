import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/kubeconfig.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// Native file helpers: `MainFlutterWindow.swift` on macOS; the
/// file_selector plugin and Explorer on Windows, or the file manager on Linux.
class NativeFiles {
  NativeFiles._();
  static const _channel = MethodChannel('k8sman/files');

  static bool get _windows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get _linux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  /// Shows an open panel (starting in ~/.kube); returns the chosen path.
  static Future<String?> chooseKubeconfig({String? directory}) async {
    if (_windows || _linux) {
      final profile = _windows ? Platform.environment['USERPROFILE'] : Platform.environment['HOME'];
      final kube = profile == null ? null : '$profile${Platform.pathSeparator}.kube';
      final file = await FileSelectorPlatform.instance.openFile(
        initialDirectory: directory ?? (kube != null && Directory(kube).existsSync() ? kube : profile),
        confirmButtonText: 'Use Kubeconfig',
      );
      return file?.path;
    }
    try {
      return await _channel.invokeMethod<String>('chooseKubeconfig', {'directory': ?directory});
    } on MissingPluginException {
      return null;
    }
  }

  static const _yaml = XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml']);

  /// Shows an open panel for a `.yaml` / `.yml` file; returns the chosen path.
  static Future<String?> chooseYaml() async {
    if (_windows || _linux) {
      final file = await FileSelectorPlatform.instance.openFile(acceptedTypeGroups: const [_yaml], confirmButtonText: 'Import');
      return file?.path;
    }
    try {
      return await _channel.invokeMethod<String>('chooseYaml');
    } on MissingPluginException {
      return null;
    }
  }

  /// Asks where to save [text] as `.yaml` and writes it. Returns the path,
  /// or null when cancelled. Throws [UnsupportedError] when the platform
  /// has no save panel (the caller then falls back to the clipboard).
  static Future<String?> saveYaml(String suggestedName, String text) => saveText(suggestedName, text, extensions: const ['yaml', 'yml'], label: 'YAML');

  /// [saveYaml] for any text file type: the save panel offers [extensions]
  /// (the first is the default).
  static Future<String?> saveText(String suggestedName, String text, {required List<String> extensions, required String label, String confirm = 'Export'}) async {
    String? path;
    if (_windows || _linux) {
      try {
        final loc = await FileSelectorPlatform.instance.getSaveLocation(
          acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
          options: SaveDialogOptions(suggestedName: suggestedName, confirmButtonText: confirm),
        );
        path = loc?.path;
      } on UnimplementedError {
        throw UnsupportedError('no save panel');
      }
    } else {
      try {
        path = await _channel.invokeMethod<String>('saveYaml', {'name': suggestedName, 'extensions': extensions, 'prompt': confirm});
      } on MissingPluginException {
        throw UnsupportedError('no save panel');
      }
    }
    if (path == null) return null;
    await File(path).writeAsString(text);
    return path;
  }

  static Future<void> reveal(String path) async {
    if (_windows) {
      // Explorer exits non-zero even when it worked.
      await Process.run('explorer.exe', ['/select,', path]).catchError((Object _) => ProcessResult(0, 1, '', ''));
      return;
    }
    if (_linux) {
      // No portable "select this file": open its folder.
      await Process.run('xdg-open', [File(path).parent.path]).catchError((Object _) => ProcessResult(0, 1, '', ''));
      return;
    }
    try {
      await _channel.invokeMethod<void>('reveal', path);
    } on MissingPluginException {
      // Not on macOS.
    }
  }
}

/// "Reveal in Finder" / "Show in Explorer".
String get revealLabel => kIsWeb
    ? 'Reveal in Finder'
    : switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Show in Explorer',
        TargetPlatform.linux => 'Show in Folder',
        _ => 'Reveal in Finder',
      };

const _choose = '\u0000choose';
const _reveal = '\u0000reveal';

/// Shows the active kubeconfig file; its menu lists the candidate files (with
/// context counts), "Choose file…" and [revealLabel].
class KubeconfigPicker extends StatefulWidget {
  /// Compact: one line in the nav. Otherwise a button (startup error screen).
  final bool compact;
  const KubeconfigPicker({super.key, this.compact = true});

  @override
  State<KubeconfigPicker> createState() => _KubeconfigPickerState();
}

class _KubeconfigPickerState extends State<KubeconfigPicker> {
  bool _hover = false;

  Future<void> _open(BuildContext ctx) async {
    final app = context.read<AppState>();
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    // Refresh so newly added files show up (quick: local file reads only).
    await app.loadKubeconfigs().timeout(const Duration(seconds: 2), onTimeout: () {});
    if (!ctx.mounted) return;
    final list = app.kubeconfigs;
    final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    final v = await showMenu<String>(
      popUpAnimationStyle: AnimationStyle.noAnimation,
      context: ctx,
      position: RelativeRect.fromLTRB(topLeft.dx, topLeft.dy, overlay.size.width - topLeft.dx - box.size.width, 0),
      constraints: BoxConstraints(minWidth: box.size.width.clamp(260, 460), maxWidth: 460),
      items: _items(ctx, list),
    );
    if (v == null || !mounted) return;
    if (v == _reveal) {
      if (list.current.isNotEmpty) await NativeFiles.reveal(list.current);
      return;
    }
    final path = v == _choose ? await NativeFiles.chooseKubeconfig() : v;
    if (path == null || path == list.current) return;
    final err = await app.switchKubeconfig(path);
    if (err != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not use ${list.shorten(path)}: $err')));
    }
  }

  List<PopupMenuEntry<String>> _items(BuildContext context, KubeconfigList list) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return [
      for (final c in list.candidates)
        PopupMenuItem<String>(
          value: c.path,
          enabled: c.error == null && c.contexts.isNotEmpty,
          height: 40,
          child: Row(children: [
            SizedBox(width: 18, child: c.path == list.current ? Icon(Icons.check, size: 14, color: theme.colorScheme.primary) : null),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(list.shorten(c.path), overflow: TextOverflow.ellipsis, maxLines: 1),
                Text(
                  c.error ?? _contextsLabel(c),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: c.error != null ? hint?.copyWith(color: theme.colorScheme.error) : hint,
                ),
              ]),
            ),
          ]),
        ),
      if (list.candidates.isNotEmpty) const PopupMenuDivider(height: 8),
      const PopupMenuItem<String>(
        value: _choose,
        height: 28,
        child: Row(children: [SizedBox(width: 18), Text('Choose file…')]),
      ),
      PopupMenuItem<String>(
        value: _reveal,
        enabled: list.current.isNotEmpty,
        height: 28,
        child: Row(children: [const SizedBox(width: 18), Text(revealLabel)]),
      ),
    ];
  }

  static String _contextsLabel(KubeconfigCandidate c) {
    final n = c.contexts.length;
    final label = '$n context${n == 1 ? '' : 's'}';
    return c.source == 'KUBECONFIG' ? '$label · \$KUBECONFIG' : label;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final label = app.kubeconfigs.currentLabel;
    if (!widget.compact) {
      return Builder(
        builder: (ctx) => OutlinedButton.icon(
          onPressed: app.switchingKubeconfig ? null : () => _open(ctx),
          icon: const Icon(Icons.description_outlined, size: 16),
          label: Text('Kubeconfig: $label'),
        ),
      );
    }
    return Tooltip(
      message: app.kubeconfigs.current.isEmpty ? 'Kubeconfig' : 'Kubeconfig: ${app.kubeconfigs.current}',
      waitDuration: const Duration(milliseconds: 600),
      child: Builder(
        builder: (ctx) => MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: app.switchingKubeconfig ? null : () => _open(ctx),
            // A quiet subtitle under the context name (aligned with it, past
            // the 20px badge): the file the contexts come from, with the
            // chevron only on hover.
            child: Container(
              height: 20,
              padding: const EdgeInsets.only(left: 36, right: 8),
              decoration: BoxDecoration(color: _hover ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
              child: Row(children: [
                if (app.switchingKubeconfig) ...[
                  const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.faint, fontSize: 11.5),
                  ),
                ),
                if (_hover) Icon(Icons.unfold_more, size: 12, color: theme.hintColor),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
