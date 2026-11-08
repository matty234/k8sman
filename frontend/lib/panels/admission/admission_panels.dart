/// Panels of admission control (admissionregistration.k8s.io): validating
/// and mutating admission policies with their bindings, and the webhook
/// configurations. Readers tolerate the version differences (v1 and the
/// v1beta1/v1alpha1 mutating policy) by only touching fields they share.
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart';

const admissionGroup = 'admissionregistration.k8s.io';

const _vapKind = 'ValidatingAdmissionPolicy';
const _mapKind = 'MutatingAdmissionPolicy';

ObjectRef _ref(String kind, String name, [String? ns]) => ObjectRef(group: admissionGroup, kind: kind, name: name, namespace: ns);

/// One rule as a line: `CREATE, UPDATE apps/v1 deployments`.
String ruleLine(Json r) {
  List<String> l(String k) => [for (final v in (r[k] as List? ?? const [])) '$v'];
  final groups = l('apiGroups'), versions = l('apiVersions');
  final api = groups.every((g) => g.isEmpty) ? versions.join(',') : '${groups.map((g) => g.isEmpty ? 'core' : g).join(',')}/${versions.join(',')}';
  final names = l('resourceNames');
  return [
    l('operations').join(', '),
    api,
    l('resources').join(','),
    if (names.isNotEmpty) 'named ${names.join(',')}',
    if (r['scope'] != null && r['scope'] != '*') '(${r['scope']} scope)',
  ].where((s) => s.isNotEmpty).join(' ');
}

Widget _rules(List<Json> rules) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in rules) Padding(padding: const EdgeInsets.only(bottom: 2), child: MonoValue(ruleLine(r), size: 11)),
    ]);

Widget _selector(dynamic s) {
  final text = selectorToString(s);
  return text.isEmpty ? const Hint('everything') : MonoValue(text, size: 11);
}

/// Match constraints (policy) or match resources (binding), webhook-style
/// fields included.
Widget _match(Json m, {bool showEmpty = true}) {
  final rules = asMapList(m['resourceRules']);
  final excluded = asMapList(m['excludeResourceRules']);
  if (m.isEmpty && !showEmpty) return const SizedBox.shrink();
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (rules.isEmpty && excluded.isEmpty && m['namespaceSelector'] == null && m['objectSelector'] == null)
      const Hint('Matches every resource and namespace.'),
    KeyValueTable([
      ('Rules', rules.isEmpty ? null : _rules(rules)),
      ('Excluded', excluded.isEmpty ? null : _rules(excluded)),
      ('Namespaces', m['namespaceSelector'] == null ? null : _selector(m['namespaceSelector'])),
      ('Objects', m['objectSelector'] == null ? null : _selector(m['objectSelector'])),
      ('Match policy', m['matchPolicy'] as String?),
    ], keyWidth: 100),
  ]);
}

/// A CEL expression in a mono block with a copy button, optionally titled.
Widget _cel(String expression, {String? title}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (title != null && title.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 2), child: MonoValue(title, size: 11)),
      CodeBlock(expression),
    ]);

Widget _stack(List<Widget> children, {double gap = 8}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in children) Padding(padding: EdgeInsets.only(bottom: gap), child: c),
    ]);

/// The kind a policy's `paramKind` names: a link to its CRD when the kind
/// is a custom resource the cluster serves, else plain text.
Widget _paramKind(PanelContext ctx, Json pk) {
  final apiVersion = '${pk['apiVersion'] ?? ''}', kind = '${pk['kind'] ?? ''}';
  final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
  final t = ctx.app.typeFor(group, kind);
  final text = '$apiVersion $kind'.trim();
  return InlineWrap([
    MonoValue(text, size: 11),
    if (t != null && t.custom) ResourceLink(ObjectRef(group: 'apiextensions.k8s.io', kind: 'CustomResourceDefinition', name: '${t.resource}.${t.group}'), label: 'CRD'),
  ]);
}

/// ValidatingAdmissionPolicy and MutatingAdmissionPolicy.
class AdmissionPolicyPanel extends ResourcePanel {
  const AdmissionPolicyPanel();

  @override
  Set<String> get kinds => {'$admissionGroup/$_vapKind', '$admissionGroup/$_mapKind'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final mutating = ctx.type.kind == _mapKind;
    final spec = ctx.spec;
    final paramKind = asMap(spec['paramKind']);
    final conditions = asMapList(spec['matchConditions']);
    final variables = asMapList(spec['variables']);
    final validations = asMapList(spec['validations']);
    final audit = asMapList(spec['auditAnnotations']);
    final mutations = asMapList(spec['mutations']);
    final warnings = asMapList(dig(ctx.status, ['typeChecking', 'expressionWarnings']));
    final statusConds = asMapList(ctx.status['conditions']);
    return [
      DetailSection(
        title: 'Policy',
        icon: Icons.policy_outlined,
        child: KeyValueTable([
          ('Failure policy', spec['failurePolicy'] as String? ?? 'Fail'),
          if (mutating) ('Reinvocation', spec['reinvocationPolicy'] as String? ?? 'Never'),
          ('Param kind', paramKind.isEmpty ? null : _paramKind(ctx, paramKind)),
        ], keyWidth: 110),
      ),
      DetailSection(title: 'Match constraints', icon: Icons.filter_alt_outlined, child: _match(asMap(spec['matchConstraints']))),
      if (conditions.isNotEmpty)
        DetailSection(
          title: 'Match conditions',
          icon: Icons.rule,
          trailing: Hint('${conditions.length}'),
          child: _stack([for (final c in conditions) _cel('${c['expression'] ?? ''}', title: c['name'] as String?)]),
        ),
      if (variables.isNotEmpty)
        DetailSection(
          title: 'Variables',
          icon: Icons.data_object,
          trailing: Hint('${variables.length}'),
          child: _stack([for (final v in variables) _cel('${v['expression'] ?? ''}', title: v['name'] as String?)]),
        ),
      if (!mutating)
        DetailSection(
          title: 'Validations',
          icon: Icons.fact_check_outlined,
          trailing: Hint('${validations.length}'),
          child: validations.isEmpty ? const Hint('No validations.') : _stack([for (final v in validations) _Validation(v)], gap: 10),
        ),
      if (!mutating && audit.isNotEmpty)
        DetailSection(
          title: 'Audit annotations',
          icon: Icons.edit_note,
          trailing: Hint('${audit.length}'),
          child: _stack([for (final a in audit) _cel('${a['valueExpression'] ?? ''}', title: a['key'] as String?)]),
        ),
      if (mutating)
        DetailSection(
          title: 'Mutations',
          icon: Icons.build_outlined,
          trailing: Hint('${mutations.length}'),
          child: mutations.isEmpty ? const Hint('No mutations.') : _stack([for (final m in mutations) _Mutation(m)], gap: 10),
        ),
      DetailSection(
        title: 'Bindings using this policy',
        icon: Icons.link,
        child: _PolicyBindings(
          key: ValueKey('bindings-${ctx.uid}'),
          api: ctx.api,
          policy: ctx.name,
          mutating: mutating,
        ),
      ),
      if (warnings.isNotEmpty || statusConds.isNotEmpty)
        DetailSection(
          title: 'Status',
          icon: Icons.monitor_heart_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InlineMessage('Type check: ${w['warning']}${w['fieldRef'] != null ? '  (${w['fieldRef']})' : ''}', icon: Icons.warning_amber_rounded, isError: true),
              ),
            if (statusConds.isNotEmpty) ConditionsTable(statusConds),
          ]),
        ),
    ];
  }
}

class _Validation extends StatelessWidget {
  final Json v;
  const _Validation(this.v);

  @override
  Widget build(BuildContext context) {
    final message = v['message'] as String?;
    final messageExpr = v['messageExpression'] as String?;
    final reason = v['reason'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CodeBlock('${v['expression'] ?? ''}'),
      const SizedBox(height: 3),
      InlineWrap([
        if (message != null && message.isNotEmpty) Text(message, style: Theme.of(context).textTheme.bodySmall),
        if (reason != null) Chipish(text: reason),
      ]),
      if (messageExpr != null && messageExpr.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: CodeBlock(messageExpr)),
    ]);
  }
}

class _Mutation extends StatelessWidget {
  final Json m;
  const _Mutation(this.m);

  @override
  Widget build(BuildContext context) {
    final type = m['patchType'] as String? ?? '';
    final expr = dig<String>(m, ['applyConfiguration', 'expression']) ?? dig<String>(m, ['jsonPatch', 'expression']) ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (type.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 3), child: Align(alignment: Alignment.centerLeft, child: Chipish(text: type))),
      CodeBlock(expr),
    ]);
  }
}

/// Bindings whose `spec.policyName` is this policy, from one list of the
/// binding kind.
class _PolicyBindings extends StatelessWidget {
  final ApiClient api;
  final String policy;
  final bool mutating;
  const _PolicyBindings({super.key, required this.api, required this.policy, required this.mutating});

  @override
  Widget build(BuildContext context) {
    final kind = mutating ? 'MutatingAdmissionPolicyBinding' : 'ValidatingAdmissionPolicyBinding';
    return FetchOnce<List<Json>>(
      deps: '$kind/$policy',
      fetch: () async => [
        for (final b in await api.items(ResourceRef(group: admissionGroup, resource: '${kind.toLowerCase()}s')))
          if (dig<String>(b, ['spec', 'policyName']) == policy) b,
      ],
      errorBuilder: (context, e) => const Hint('Bindings could not be listed.'),
      builder: (context, bindings) {
        if (bindings.isEmpty) return const InlineMessage('No binding references this policy, so it is not enforced anywhere.');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final b in bindings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InlineWrap([
                ResourceLink(_ref(kind, '${dig<String>(b, ['metadata', 'name'])}'), label: dig<String>(b, ['metadata', 'name'])),
                for (final a in (dig<List>(b, ['spec', 'validationActions']) ?? const [])) _ActionChip('$a'),
              ]),
            ),
        ]);
      },
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String action;
  const _ActionChip(this.action);

  @override
  Widget build(BuildContext context) =>
      Chipish(text: action, color: switch (action) { 'Deny' => Colors.redAccent, 'Warn' => Colors.orange, _ => null });
}

/// ValidatingAdmissionPolicyBinding and MutatingAdmissionPolicyBinding.
class AdmissionBindingPanel extends ResourcePanel {
  const AdmissionBindingPanel();

  @override
  Set<String> get kinds => {'$admissionGroup/${_vapKind}Binding', '$admissionGroup/${_mapKind}Binding'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final mutating = ctx.type.kind.startsWith('Mutating');
    final spec = ctx.spec;
    final policy = spec['policyName'] as String?;
    final actions = [for (final a in (spec['validationActions'] as List? ?? const [])) '$a'];
    final param = asMap(spec['paramRef']);
    return [
      DetailSection(
        title: 'Binding',
        icon: Icons.link,
        child: KeyValueTable([
          ('Policy', policy == null || policy.isEmpty ? null : ResourceLink(_ref(mutating ? _mapKind : _vapKind, policy), label: policy)),
          if (!mutating) ('Actions', actions.isEmpty ? null : InlineWrap([for (final a in actions) _ActionChip(a)])),
        ], keyWidth: 90),
      ),
      if (param.isNotEmpty)
        DetailSection(
          title: 'Parameters',
          icon: Icons.tune,
          child: KeyValueTable([
            ('Name', param['name'] as String?),
            ('Namespace', param['namespace'] as String?),
            ('Selector', param['selector'] == null ? null : _selector(param['selector'])),
            ('If not found', param['parameterNotFoundAction'] as String?),
          ], keyWidth: 90),
        ),
      DetailSection(title: 'Match resources', icon: Icons.filter_alt_outlined, child: _match(asMap(spec['matchResources']))),
    ];
  }
}

/// ValidatingWebhookConfiguration and MutatingWebhookConfiguration.
class WebhookConfigPanel extends ResourcePanel {
  const WebhookConfigPanel();

  @override
  Set<String> get kinds => {'$admissionGroup/ValidatingWebhookConfiguration', '$admissionGroup/MutatingWebhookConfiguration'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final hooks = asMapList(ctx.object['webhooks']);
    return [
      DetailSection(
        title: 'Webhooks',
        icon: Icons.webhook,
        trailing: Hint('${hooks.length}'),
        child: hooks.isEmpty ? const Hint('No webhooks.') : _stack([for (final h in hooks) _Webhook(h)], gap: 12),
      ),
    ];
  }
}

class _Webhook extends StatelessWidget {
  final Json h;
  const _Webhook(this.h);

  @override
  Widget build(BuildContext context) {
    final cc = asMap(h['clientConfig']);
    final svc = asMap(cc['service']);
    final failure = h['failurePolicy'] as String? ?? 'Fail';
    final timeout = h['timeoutSeconds'];
    Widget target;
    if (svc.isNotEmpty) {
      final port = svc['port'] ?? 443;
      target = InlineWrap([
        ResourceLink(ObjectRef(kind: 'Service', name: '${svc['name']}', namespace: svc['namespace'] as String?), label: '${svc['namespace']}/${svc['name']}'),
        MonoValue('$port${svc['path'] != null ? ' ${svc['path']}' : ''}', size: 11),
      ]);
    } else if (cc['url'] != null) {
      target = MonoValue('${cc['url']}', copy: true, size: 11);
    } else {
      target = const Hint('no client config');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InlineWrap([
        Text('${h['name'] ?? ''}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        Chipish(text: 'failure: $failure', color: failure == 'Fail' ? Colors.orange : null),
      ]),
      const SizedBox(height: 4),
      KeyValueTable([
        ('Target', target),
        ('Rules', asMapList(h['rules']).isEmpty ? null : _rules(asMapList(h['rules']))),
        ('Side effects', h['sideEffects'] as String?),
        ('Timeout', timeout == null ? null : '${timeout}s'),
        ('Match policy', h['matchPolicy'] as String?),
        ('Reinvocation', h['reinvocationPolicy'] as String?),
        ('Namespaces', h['namespaceSelector'] == null ? null : _selector(h['namespaceSelector'])),
        ('Objects', h['objectSelector'] == null ? null : _selector(h['objectSelector'])),
        ('Review versions', (h['admissionReviewVersions'] as List?)?.join(', ')),
      ], keyWidth: 110),
    ]);
  }
}

final List<ResourcePanel> admissionPanels = [
  const AdmissionPolicyPanel(),
  const AdmissionBindingPanel(),
  const WebhookConfigPanel(),
];
