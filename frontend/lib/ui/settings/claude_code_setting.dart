import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/error_info.dart' show errorText;
import '../widgets/common.dart' show copyToClipboard;
import 'settings_widgets.dart';

const _description = 'Adds a k8sman MCP server that Claude Code can use to list resources, read objects, events and logs, and see problems '
    'on the context k8sman shows. It can read but not change anything, and never sees Secrets. '
    'What Claude reads is sent to Anthropic. Off until you turn it on.';

/// Settings ▸ General: the opt-in MCP server for Claude Code.
SettingItem claudeCodeSetting() => SettingItem(
      key: const ValueKey('settings-claude-code'),
      group: 'Claude Code',
      label: 'Let Claude Code read this cluster',
      description: _description,
      keywords: const ['claude', 'claude code', 'mcp', 'ai', 'llm', 'agent', 'assistant', 'privacy'],
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
    _run(_api.getMcpSettings);
  }

  Future<void> _run(Future<McpSettings> Function() f) async {
    try {
      final v = await f();
      if (mounted) setState(() => (_s = v, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _s;
    return SettingRow(
      label: 'Let Claude Code read this cluster',
      description: _description,
      trailing: _error != null
          ? Tooltip(message: _error!, child: Text('Unavailable', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)))
          : SettingSwitch(
              key: const ValueKey('claude-code-switch'),
              value: s?.enabled ?? false,
              onChanged: s == null ? null : (v) => _run(() => _api.putMcpSettings(v)),
            ),
      child: s != null && s.enabled && s.addCommand.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Run this once in a terminal to add it to Claude Code:', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: SelectableText(s.addCommand, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                    ),
                    IconButton(
                      key: const ValueKey('claude-code-copy'),
                      tooltip: 'Copy command',
                      icon: const Icon(Icons.copy, size: 14),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => copyToClipboard(context, s.addCommand, label: 'command'),
                    ),
                  ]),
                ),
              ]),
            )
          : null,
    );
  }
}
