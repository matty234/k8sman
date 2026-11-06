/// How k8sman signs in to the Argo CD API server (for per-resource diffs):
/// the argocd CLI's login, the initial admin password, or a pasted token.
/// One form, opened from the Integrations dialog and from the inspector's
/// "Connect…" prompt on an Application. Saved per kube context in
/// settings.json (moduleSettings.argocd); the token is never shown again.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../modules/modules.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart' show Severity;
import 'app_diff.dart';

/// Opens the form for the current kube context. [namespace] is where the
/// Application lives (a hint for finding argocd-server). True when the
/// sign-in changed.
Future<bool> showArgoCdSettings(BuildContext context, {String? namespace}) async {
  final api = context.read<ApiClient>();
  final app = context.read<AppState>();
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: Dialog(insetPadding: const EdgeInsets.all(32), child: SizedBox(width: 460, child: ArgoCdSettingsForm(namespace: namespace))),
    ),
  );
  return changed == true;
}

class ArgoCdSettingsForm extends StatefulWidget {
  final String? namespace;
  const ArgoCdSettingsForm({super.key, this.namespace});

  @override
  State<ArgoCdSettingsForm> createState() => _ArgoCdSettingsFormState();
}

class _ArgoCdSettingsFormState extends State<ArgoCdSettingsForm> {
  final _token = TextEditingController();
  ArgoApiStatus? _st;
  bool _busy = false;
  bool _changed = false;
  String? _error;

  ArgoDiffApi get _api => ArgoDiffApi.of(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    _run(() async => _st = await _api.status(namespace: widget.namespace), changes: false);
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  /// Runs [fn] (an API call that returns the new status); [changes] marks
  /// the sign-in as changed so callers refresh.
  Future<void> _run(Future<void> Function() fn, {bool changes = true}) async {
    final api = context.read<ApiClient>();
    final kubeContext = context.read<AppState>().currentContext;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
      if (changes) {
        _changed = true;
        ArgoDiffCache.invalidateAll();
        moduleStatuses.refresh(builtInModules.firstWhere((m) => m.id == 'argocd'), api, kubeContext);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useInitialAdmin(ArgoApiStatus st) async {
    final ok = await confirmAction(
      context,
      title: 'Use the initial admin password?',
      message: 'Use the initial admin password from ${st.secretRef}? k8sman logs in to Argo CD as admin and keeps the '
          'session in memory until the app quits. The password is never stored.',
      kubeContext: context.read<AppState>().currentContext,
      objectName: 'argocd-initial-admin-secret',
      confirmLabel: 'Use it',
    );
    if (ok != true || !mounted) return;
    await _run(() async => _st = await _api.useInitialAdmin(namespace: widget.namespace));
  }

  Future<void> _saveToken() async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    final kubeContext = context.read<AppState>().currentContext;
    await _run(() async {
      _st = await _api.setToken(t, context: kubeContext, namespace: widget.namespace);
      _token.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final st = _st;
    Widget cmd(String c) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Align(alignment: Alignment.centerLeft, child: Chipish(text: c, copyValue: c)),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Argo CD settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'For ${context.read<AppState>().currentContext}. Applications are read and synced through the Kubernetes API alone; '
            'signing in to the Argo CD API adds per-resource diffs.',
            style: hint,
          ),
          const SizedBox(height: 14),
          if (st == null && _busy)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else if (st != null && !st.found)
            const InlineMessage('argocd-server wasn\'t found in the cluster, so there is nothing to sign in to.')
          else if (st != null) ...[
            if (st.auth != 'none')
              Row(children: [
                Icon(Icons.link, size: 14, color: severityColor(context, Severity.ok)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Signed in via ${switch (st.auth) { 'session' => 'the initial admin session', 'cli' => 'the argocd CLI login', _ => 'a saved token' }}'
                    '${st.username == null || st.username!.isEmpty ? '' : ' as ${st.username}'}',
                    style: small,
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _run(() async => _st = await _api.clearToken(namespace: widget.namespace)),
                  child: const Text('Disconnect'),
                ),
              ])
            else
              Text('Not signed in.', style: small),
            if (st.error != null && st.auth != 'none') Padding(padding: const EdgeInsets.only(top: 6), child: InlineMessage(st.error!, isError: true)),
            const SizedBox(height: 10),
            if (st.cliLogin == null && st.cliLoginCommand != null) ...[
              Text('Log in with the argocd CLI (opens your browser for SSO), then connect:', style: hint),
              const SizedBox(height: 4),
              CodeBlock(st.cliLoginCommand!),
              const SizedBox(height: 6),
            ],
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (st.cliLogin != null || st.cliLoginCommand != null)
                ArgoActionButton(
                  label: st.cliLogin != null ? 'Use argocd CLI login' : 'I\'ve logged in',
                  icon: Icons.terminal,
                  tooltip: st.cliLogin != null
                      ? 'Use the argocd CLI login for ${st.argoUrl} (CLI context "${st.cliLogin}"). The token stays in the CLI config.'
                      : 'Connect using the argocd CLI login once you have run the command above',
                  onTap: _busy ? null : () => _run(() async => _st = await _api.useCli(namespace: widget.namespace)),
                ),
              if (st.initialAdminAvailable)
                ArgoActionButton(
                  label: 'Use initial admin password',
                  icon: Icons.admin_panel_settings_outlined,
                  tooltip: 'Log in with ${st.secretRef} (asks first)',
                  onTap: _busy ? null : () => _useInitialAdmin(st),
                ),
            ]),
            const SizedBox(height: 14),
            Text('Or paste an API token. It is saved for this context in ~/.config/k8sman/settings.json (readable only by you) '
                'and sent only to argocd-server, through the Kubernetes API.', style: hint),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('argocd-token'),
                  controller: _token,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(isDense: true, labelText: st.auth == 'configured' ? 'Replace the saved token' : 'Token', border: const OutlineInputBorder()),
                  style: monoStyle(context),
                  onSubmitted: (_) => _saveToken(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _busy ? null : _saveToken, child: const Text('Save')),
            ]),
            const SizedBox(height: 10),
            Text('To create one, log in with the argocd CLI and run:', style: hint),
            cmd('argocd account generate-token'),
            const SizedBox(height: 6),
            Text('Or for a dedicated local account, give it the apiKey capability in argocd-cm and run:', style: hint),
            cmd('accounts.k8sman: apiKey'),
            cmd('argocd account generate-token --account k8sman'),
            const SizedBox(height: 6),
            Text('It needs Argo RBAC to get applications (e.g. role:readonly).', style: hint),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: InlineMessage(_error!, isError: true)),
          const SizedBox(height: 14),
          Row(children: [
            if (_busy && st != null) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const Spacer(),
            OutlinedButton(onPressed: () => Navigator.of(context).pop(_changed), child: const Text('Close')),
          ]),
        ]),
      ),
    );
  }
}
