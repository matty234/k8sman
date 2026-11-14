import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/error_info.dart' show errorText;
import '../../app/kubeconfig_picker.dart' show NativeFiles;
import '../../state/app_state.dart';
import '../widgets/common.dart' show copyToClipboard;
import 'settings_widgets.dart';

const _description = 'Adds a k8sman MCP server that Claude Code can use to list resources, read objects, events and logs, and see problems '
    'on the context k8sman shows. It can read but not change anything, and never sees Secrets. '
    'Also adds Ask Claude to the inspector and a Claude Code button to the bottom panel. '
    'What Claude reads is sent to Anthropic. Off until you turn it on.';

/// Settings ▸ General: the opt-in MCP server for Claude Code.
SettingItem claudeCodeSetting() => SettingItem(
      key: const ValueKey('settings-claude-code'),
      group: 'Claude Code',
      label: 'Let Claude Code read this cluster',
      description: _description,
      keywords: const ['claude', 'claude code', 'mcp', 'ai', 'llm', 'agent', 'assistant', 'privacy', 'folder', 'ask claude'],
      builder: (_) => const _ClaudeCodeSetting(),
    );

class _ClaudeCodeSetting extends StatefulWidget {
  const _ClaudeCodeSetting();

  @override
  State<_ClaudeCodeSetting> createState() => _ClaudeCodeSettingState();
}

class _ClaudeCodeSettingState extends State<_ClaudeCodeSetting> {
  late final ApiClient _api = context.read<ApiClient>();
  McpSettings? _s;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _api.getMcpSettings();
      if (mounted) setState(() => (_s = v, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  /// Saves, then mirrors the switch into AppState (which shows the Ask
  /// Claude actions). A failure is a snackbar; the row stays usable.
  Future<void> _save({bool? enabled, String? folder}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final app = context.read<AppState?>();
    try {
      final v = await _api.putMcpSettings(enabled: enabled, folder: folder);
      app?.setClaudeCode(v.enabled);
      if (mounted) setState(() => _s = v);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Future<void> _chooseFolder() async {
    final dir = await NativeFiles.chooseDirectory(confirm: 'Open Claude Code Here');
    if (dir != null && mounted) await _save(folder: dir);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final s = _s;
    return SettingRow(
      label: 'Let Claude Code read this cluster',
      description: _description,
      trailing: _error != null
          ? Tooltip(message: _error!, child: Text('Unavailable', style: hint))
          : SettingSwitch(
              key: const ValueKey('claude-code-switch'),
              value: s?.enabled ?? false,
              onChanged: s == null ? null : (v) => _save(enabled: v),
            ),
      child: s == null || !s.enabled
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Claude Code opens in', style: hint),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(
                    child: Text(
                      s.folder.isEmpty ? '${s.defaultFolder} (k8sman\'s own folder)' : s.folder,
                      key: const ValueKey('claude-code-folder'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                  TextButton(key: const ValueKey('claude-code-choose-folder'), onPressed: _chooseFolder, child: const Text('Choose…')),
                  if (s.folder.isNotEmpty) TextButton(onPressed: () => _save(folder: ''), child: const Text('Use Default')),
                ]),
                const SizedBox(height: 10),
                if (s.addCommand.isNotEmpty) ...[
                  Text('To use the k8sman tools in your other Claude Code sessions too, run this once in a terminal:', style: hint),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: Row(children: [
                      Expanded(child: SelectableText(s.addCommand, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'))),
                      IconButton(
                        key: const ValueKey('claude-code-copy'),
                        tooltip: 'Copy command',
                        icon: const Icon(Icons.copy, size: 14),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => copyToClipboard(context, s.addCommand, label: 'command'),
                      ),
                    ]),
                  ),
                ],
              ]),
            ),
    );
  }
}
