import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../externalsecrets/managed_by.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'usage.dart';
import 'values.dart';
import 'widgets.dart';

const _mask = '••••••••';

String _type(PanelContext ctx) => '${ctx.object['type'] ?? 'Opaque'}';

class SecretPanel extends ResourcePanel {
  const SecretPanel();

  @override
  Set<String> get kinds => {'/Secret'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final data = asMap(ctx.object['data']);
    return [
      _SecretHeader(ctx),
      ManagedByExternalSecret(key: ValueKey('${ctx.uid}/eso'), ctx: ctx),
      SecretBody(key: ValueKey('${ctx.uid}/secret'), ctx: ctx),
      UsedBySection(key: ValueKey('${ctx.uid}/usedby'), ctx: ctx, kind: RefKind.secret, existingKeys: {...data.keys}),
    ];
  }
}

/// Type, key count, size and who uses it; insights for type-specific keys
/// that are missing or malformed and for keys pods reference but lack.
class _SecretHeader extends StatelessWidget {
  final PanelContext ctx;
  const _SecretHeader(this.ctx);

  @override
  Widget build(BuildContext context) {
    final type = _type(ctx);
    final data = asMap(ctx.object['data']);
    final decoded = {for (final k in data.keys) k: decodeSecretValue(data[k])};
    final total = decoded.values.fold<int>(0, (s, d) => s + (d?.length ?? 0));
    final immutable = ctx.object['immutable'] == true;
    return UsageReportBuilder(
      ctx: ctx,
      kind: RefKind.secret,
      builder: (context, snap) => InspectorHeader(
        chips: [
          Chipish(text: type, copyValue: type),
          if (immutable) const StatusBadge('immutable', dense: true, severity: Severity.info),
        ],
        figures: [
          InspectorFigure('${data.length}', data.length == 1 ? 'key' : 'keys'),
          sizeFigure(total, 'size'),
          ...usedByFigures(snap),
        ],
        insights: _typeInsights(type, decoded),
        extraInsights: missingKeyInsights(snap, {...data.keys}, 'Secret'),
        facts: [?ownerFact(ctx.object), ('Type', secretTypeExplanation(type))],
        factsKeyWidth: 56,
      ),
    );
  }

  static List<Insight> _typeInsights(String type, Map<String, DecodedValue?> decoded) {
    switch (type) {
      case 'kubernetes.io/tls':
        return [
          for (final k in ['tls.crt', 'tls.key'])
            if (!decoded.containsKey(k))
              Insight(Severity.error, '$k is missing', 'A TLS secret needs both tls.crt and tls.key.')
            else if (pemBlocks(decoded[k]?.text).isEmpty)
              Insight(Severity.error, '$k is not PEM', 'Expected a PEM block (-----BEGIN …-----).'),
        ];
      case 'kubernetes.io/dockerconfigjson':
      case 'kubernetes.io/dockercfg':
        final key = type == 'kubernetes.io/dockercfg' ? '.dockercfg' : '.dockerconfigjson';
        return parseDockerConfig(decoded[key]?.text) == null ? [Insight(Severity.error, '$key is missing or not valid JSON.')] : const [];
      case 'kubernetes.io/basic-auth':
      case 'kubernetes.io/ssh-auth':
        final expected = type == 'kubernetes.io/basic-auth' ? ['username', 'password'] : ['ssh-privatekey'];
        final missing = expected.where((k) => !decoded.containsKey(k)).toList();
        return missing.isEmpty ? const [] : [Insight(Severity.error, 'Expected key${missing.length == 1 ? '' : 's'} missing: ${missing.join(', ')}')];
    }
    return const [];
  }
}

/// The masked key rows and the type's own section (certificate material,
/// registries, token). Holds the reveal state, which lives only in this
/// State and is never persisted.
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
    final type = _type(ctx);
    final data = _data;
    final keys = data.keys.toList()..sort();
    final decoded = {for (final k in keys) k: decodeSecretValue(data[k])};
    final total = decoded.values.fold<int>(0, (s, d) => s + (d?.length ?? 0));
    final theme = Theme.of(context);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InspectorSection(
        id: 'secret-data',
        title: 'Data',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: SectionSummary(keys.isEmpty ? 'empty' : '${plural(keys.length, 'key')} · ${formatBytes(total)}')),
          if (keys.isNotEmpty) ...[
            const SizedBox(width: 10),
            Hoverable(
              key: const ValueKey('secret-reveal-all'),
              onTap: () => setState(() {
                _revealAll = !_revealAll;
                _revealed.clear();
              }),
              builder: (h) => Text(_revealAll ? 'Hide all' : 'Reveal all',
                  style: TextStyle(color: h ? theme.colorScheme.onSurface : theme.hintColor, decoration: h ? TextDecoration.underline : null)),
            ),
          ],
        ]),
        child: keys.isEmpty
            ? const InlineMessage('This Secret has no data.')
            : TrimmedList(trimAbove: 12, keep: 10, [for (final k in keys) _keyRow(context, k, data[k], decoded[k])]),
      ),
      ..._typeSection(context, type, decoded),
    ]);
  }

  Widget _keyRow(BuildContext context, String key, dynamic raw, DecodedValue? d) {
    final theme = Theme.of(context);
    final revealed = _isRevealed(key);
    final meta = d == null ? 'invalid base64' : (d.isBinary ? 'binary · ${formatBytes(d.length)}' : formatBytes(d.length));
    final inline = revealed && d != null && !d.isBinary && !d.text!.contains('\n') && d.text!.length <= 60;
    Widget? body;
    if (revealed && d != null && !inline) {
      if (d.isBinary) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('binary · ${d.length} bytes', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 2),
          CodeBlock(hexPreview(d.bytes, max: 48)),
        ]);
      } else {
        body = LongValue(prettyValue(d.text!, detectFormat(d.text!)));
      }
    }
    // Key and controls on top (the key truncates, the controls never
    // move), the value underneath at full width.
    return InspectorRow(
      key: ValueKey('secret-key-$key'),
      actionsAlways: true,
      title: Tooltip(
        message: key.length > 28 ? key : '',
        child: Text(key, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
      ),
      subtitle: !revealed
          ? Text(_mask, overflow: TextOverflow.clip, style: monoStyle(context, size: 11.5, color: theme.hintColor))
          : inline
              ? Text(d.text!, style: monoStyle(context, size: 11.5, color: theme.colorScheme.onSurface))
              : null,
      trailing: [Text(meta, style: d == null ? TextStyle(color: severityColor(context, Severity.error)) : null)],
      actions: [
        RowAction(icon: revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined, tooltip: revealed ? 'Hide' : 'Reveal', onTap: () => _toggle(key)),
        RowAction(
          icon: Icons.copy,
          tooltip: d?.isBinary ?? false ? 'Copy (base64, binary value)' : 'Copy decoded',
          onTap: d == null ? null : () => _copy(key, d.isBinary ? '$raw' : d.text!),
        ),
      ],
      below: body,
    );
  }

  /// The type's own section: certificate material, registries, the token's
  /// account, the bootstrap token's settings.
  List<Widget> _typeSection(BuildContext context, String type, Map<String, DecodedValue?> decoded) {
    final ctx = widget.ctx;
    final theme = Theme.of(context);
    switch (type) {
      case 'kubernetes.io/tls':
        var complete = true;
        Widget row(String key, {bool required = true}) {
          final d = decoded[key];
          final present = d != null;
          final blocks = pemBlocks(d?.text);
          final ok = present && blocks.isNotEmpty;
          if (required && !ok) complete = false;
          final sev = ok ? Severity.ok : (present || required ? Severity.error : Severity.neutral);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(ok ? Icons.check_circle_outline : (present ? Icons.error_outline : Icons.remove_circle_outline), size: 14, color: severityColor(context, sev)),
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
        final rows = [row('tls.crt'), row('tls.key'), row('ca.crt', required: false)];
        return [
          InspectorSection(
            id: 'secret-tls',
            title: 'Certificate',
            trailing: SectionSummary(complete ? 'certificate and key' : 'incomplete', color: complete ? null : severityColor(context, Severity.error)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ];

      case 'kubernetes.io/dockerconfigjson':
      case 'kubernetes.io/dockercfg':
        final key = type == 'kubernetes.io/dockercfg' ? '.dockercfg' : '.dockerconfigjson';
        final regs = parseDockerConfig(decoded[key]?.text);
        if (regs == null) return const [];
        final revealed = _isRevealed(key);
        return [
          InspectorSection(
            id: 'secret-registries',
            title: 'Registries',
            trailing: SectionSummary(plural(regs.length, 'registry', 'registries')),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final r in regs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.cloud_outlined, size: 13, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Expanded(flex: 5, child: Text(r.registry, style: monoStyle(context, size: 11.5))),
                    const SizedBox(width: 8),
                    Expanded(flex: 3, child: Text(r.username ?? '—', style: monoStyle(context, size: 11.5))),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: Text(r.password == null ? '—' : (revealed ? r.password! : _mask), style: monoStyle(context, size: 11.5, color: revealed ? null : theme.hintColor)),
                    ),
                  ]),
                ),
            ]),
          ),
        ];

      case 'kubernetes.io/service-account-token':
        final sa = dig<String>(ctx.object, ['metadata', 'annotations', 'kubernetes.io/service-account.name']);
        final saUid = dig<String>(ctx.object, ['metadata', 'annotations', 'kubernetes.io/service-account.uid']);
        final populated = decoded.containsKey('token');
        return [
          InspectorSection(
            id: 'secret-token',
            title: 'Token',
            trailing: SectionSummary(populated ? (sa == null ? 'populated' : 'for $sa') : 'not yet populated',
                color: populated ? null : severityColor(context, Severity.warn)),
            child: KeyValueTable([
              ('ServiceAccount', sa == null ? 'annotation missing' : ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
              ('SA uid', saUid),
              ('token', populated ? (decoded['token'] == null ? 'invalid' : 'present · ${decoded['token']!.length} bytes') : 'not yet populated'),
              ('ca.crt', decoded.containsKey('ca.crt') ? describePem(pemBlocks(decoded['ca.crt']?.text)) : null),
            ], keyWidth: 110),
          ),
        ];

      case 'bootstrap.kubernetes.io/token':
        final exp = decoded['expiration']?.text;
        final usages = decoded.keys.where((k) => k.startsWith('usage-bootstrap-') && decoded[k]?.text == 'true').map((k) => k.substring(16)).toList();
        return [
          InspectorSection(
            id: 'secret-bootstrap',
            title: 'Bootstrap token',
            trailing: SectionSummary(exp == null ? 'no expiration' : 'expires $exp'),
            child: KeyValueTable([
              ('token-id', decoded['token-id']?.text),
              ('expiration', exp),
              ('usages', usages.isEmpty ? null : usages.join(', ')),
              ('description', decoded['description']?.text),
            ], keyWidth: 110),
          ),
        ];
    }
    return const [];
  }
}
