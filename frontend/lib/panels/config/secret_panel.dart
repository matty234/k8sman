import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'usage.dart';
import 'values.dart';
import 'widgets.dart';

const _mask = '••••••••';

class SecretPanel extends ResourcePanel {
  const SecretPanel();

  @override
  Set<String> get kinds => {'/Secret'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final data = asMap(ctx.object['data']);
    return [
      SecretBody(key: ValueKey('${ctx.uid}/secret'), ctx: ctx),
      UsedBySection(key: ValueKey('${ctx.uid}/usedby'), ctx: ctx, kind: RefKind.secret, existingKeys: {...data.keys}),
    ];
  }
}

/// Type summary, type-specific insight and the masked key list. Holds the
/// reveal state, which lives only in this State and is never persisted.
class SecretBody extends StatefulWidget {
  final PanelContext ctx;
  const SecretBody({super.key, required this.ctx});

  @override
  State<SecretBody> createState() => _SecretBodyState();
}

class _SecretBodyState extends State<SecretBody> {
  final Set<String> _revealed = {};
  bool _revealAll = false;

  bool _isRevealed(String key) => _revealAll || _revealed.contains(key);

  void _toggle(String key) => setState(() {
        if (_revealAll) {
          _revealAll = false;
          _revealed
            ..clear()
            ..addAll(_data.keys)
            ..remove(key);
        } else if (!_revealed.remove(key)) {
          _revealed.add(key);
        }
      });

  Json get _data => asMap(widget.ctx.object['data']);

  void _copy(String key, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Copied decoded $key'), duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final type = '${ctx.object['type'] ?? 'Opaque'}';
    final data = _data;
    final keys = data.keys.toList()..sort();
    final immutable = ctx.object['immutable'] == true;
    final decoded = {for (final k in keys) k: decodeSecretValue(data[k])};
    final total = decoded.values.fold<int>(0, (s, d) => s + (d?.length ?? 0));
    final theme = Theme.of(context);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DetailSection(
        title: 'Type',
        icon: Icons.category_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Chipish(text: type, copyValue: type),
            if (immutable) const StatusBadge('immutable', dense: true, severity: Severity.info),
          ]),
          const SizedBox(height: 4),
          Text(secretTypeExplanation(type), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ..._typeSpecific(context, type, decoded),
        ]),
      ),
      DetailSection(
        title: 'Data',
        icon: Icons.key,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CountPill('${keys.length} key${keys.length == 1 ? '' : 's'} · ${formatSize(total)}'),
          if (keys.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: Theme.of(context).textTheme.labelMedium),
              onPressed: () => setState(() {
                _revealAll = !_revealAll;
                _revealed.clear();
              }),
              icon: Icon(_revealAll ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 15),
              label: Text(_revealAll ? 'Hide all' : 'Reveal all'),
            ),
        ]),
        child: keys.isEmpty
            ? const InlineMessage('This Secret has no data.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final k in keys) _keyRow(context, k, data[k], decoded[k]),
              ]),
      ),
    ]);
  }

  Widget _keyRow(BuildContext context, String key, dynamic raw, DecodedValue? d) {
    final theme = Theme.of(context);
    final revealed = _isRevealed(key);
    final meta = d == null ? 'invalid base64' : (d.isBinary ? 'binary · ${formatSize(d.length)}' : formatSize(d.length));
    Widget? body;
    if (revealed && d != null) {
      if (d.isBinary) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('binary · ${d.length} bytes', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 2),
          CodeBlock(hexPreview(d.bytes, max: 48)),
        ]);
      } else {
        final f = detectFormat(d.text!);
        body = d.text!.isEmpty ? Text('(empty)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)) : CodeBlock(prettyValue(d.text!, f));
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      // Two lines: key + controls on top (key truncates, controls never move),
      // value underneath at full width — long keys can't squeeze the value.
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 1, 2, 0),
          child: Row(children: [
            Expanded(
              child: Tooltip(
                message: key.length > 28 ? key : '',
                child: Text(key, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context).copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Text(meta, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11)),
            IconButton(
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              tooltip: revealed ? 'Hide' : 'Reveal',
              icon: Icon(revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => _toggle(key),
            ),
            IconButton(
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              tooltip: d?.isBinary ?? false ? 'Copy (base64, binary value)' : 'Copy decoded',
              icon: const Icon(Icons.copy),
              onPressed: d == null ? null : () => _copy(key, d.isBinary ? '$raw' : d.text!),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: !revealed
              ? Text(_mask, maxLines: 1, overflow: TextOverflow.clip, style: monoStyle(context, size: 11.5, color: theme.hintColor))
              : revealed && d != null && !d.isBinary && !d.text!.contains('\n') && d.text!.length <= 60
                  ? Text(d.text!, style: monoStyle(context, size: 11.5))
                  : body ?? const SizedBox.shrink(),
        ),
      ]),
    );
  }

  List<Widget> _typeSpecific(BuildContext context, String type, Map<String, DecodedValue?> decoded) {
    final ctx = widget.ctx;
    final theme = Theme.of(context);
    Widget heading(String t) => Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(t, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
        );
    switch (type) {
      case 'kubernetes.io/tls':
        Widget row(String key, {bool required = true}) {
          final d = decoded[key];
          final present = d != null;
          final blocks = pemBlocks(d?.text);
          final ok = present && blocks.isNotEmpty;
          final sev = ok ? Severity.ok : (present || required ? Severity.error : Severity.neutral);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(ok ? Icons.check_circle_outline : (present ? Icons.error_outline : Icons.remove_circle_outline), size: 15, color: severityColor(context, sev)),
              const SizedBox(width: 6),
              SizedBox(width: 64, child: Text(key, style: monoStyle(context, size: 11.5))),
              Expanded(
                child: Text(
                  !present ? (required ? 'missing' : 'not present') : '${describePem(blocks)}${(blocks['CERTIFICATE'] ?? 0) > 1 ? '  (chain)' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: present ? null : theme.hintColor),
                ),
              ),
            ]),
          );
        }
        return [heading('Certificate material'), row('tls.crt'), row('tls.key'), row('ca.crt', required: false)];

      case 'kubernetes.io/dockerconfigjson':
      case 'kubernetes.io/dockercfg':
        final key = type == 'kubernetes.io/dockercfg' ? '.dockercfg' : '.dockerconfigjson';
        final regs = parseDockerConfig(decoded[key]?.text);
        if (regs == null) return [const SizedBox(height: 6), InlineMessage('$key is missing or not valid JSON.', isError: true)];
        final revealed = _isRevealed(key);
        return [
          heading('Registries (${regs.length})'),
          for (final r in regs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.cloud_outlined, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(flex: 5, child: Text(r.registry, style: monoStyle(context, size: 11.5))),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: Text(r.username ?? '—', style: monoStyle(context, size: 11.5))),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(r.password == null ? '—' : (revealed ? r.password! : _mask),
                      style: monoStyle(context, size: 11.5, color: revealed ? null : theme.hintColor)),
                ),
              ]),
            ),
        ];

      case 'kubernetes.io/service-account-token':
        final sa = dig<String>(ctx.object, ['metadata', 'annotations', 'kubernetes.io/service-account.name']);
        final saUid = dig<String>(ctx.object, ['metadata', 'annotations', 'kubernetes.io/service-account.uid']);
        return [
          const SizedBox(height: 8),
          KeyValueTable([
            ('ServiceAccount', sa == null ? 'annotation missing' : ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
            ('SA uid', saUid),
            ('token', decoded.containsKey('token') ? (decoded['token'] == null ? 'invalid' : 'present · ${decoded['token']!.length} bytes') : 'not yet populated'),
            ('ca.crt', decoded.containsKey('ca.crt') ? describePem(pemBlocks(decoded['ca.crt']?.text)) : null),
          ], keyWidth: 110),
        ];

      case 'kubernetes.io/basic-auth':
      case 'kubernetes.io/ssh-auth':
        final expected = type == 'kubernetes.io/basic-auth' ? ['username', 'password'] : ['ssh-privatekey'];
        final missing = expected.where((k) => !decoded.containsKey(k)).toList();
        if (missing.isEmpty) return const [];
        return [const SizedBox(height: 6), InlineMessage('Expected key${missing.length == 1 ? '' : 's'} missing: ${missing.join(', ')}', isError: true)];

      case 'bootstrap.kubernetes.io/token':
        final exp = decoded['expiration']?.text;
        final usages = decoded.keys.where((k) => k.startsWith('usage-bootstrap-') && decoded[k]?.text == 'true').map((k) => k.substring(16)).toList();
        return [
          const SizedBox(height: 8),
          KeyValueTable([
            ('token-id', decoded['token-id']?.text),
            ('expiration', exp),
            ('usages', usages.isEmpty ? null : usages.join(', ')),
            ('description', decoded['description']?.text),
          ], keyWidth: 110),
        ];
    }
    return const [];
  }
}
