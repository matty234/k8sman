/// The Settings page: every user setting in one place, a section list on
/// the left and the section on the right, with a search across all of
/// them. Open it with [openSettings] (⌘, / Ctrl+,, the sidebar's gear,
/// the palette's "Settings…" or `:settings [section]`). Changes apply and
/// save as they're made.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../app/updates/update_controller.dart';
import '../../app/updates/update_ui.dart';
import '../../modules/modules.dart';
import '../../plugins/plugin_host.dart';
import '../../plugins/plugin_notices.dart';
import '../../plugins/plugins_settings.dart' show PluginsController;
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import '../addons/addons_view.dart';
import '../keyboard_help.dart';
import '../keys.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cluster_settings.dart';
import 'diagnostics_settings.dart';
import 'integrations_settings.dart';
import 'settings_widgets.dart';
import 'sidebar_settings.dart';
import 'table_settings.dart';
import 'views_settings.dart';

/// The sections, in the order of the section list.
enum SettingsSection {
  general('General', Icons.settings_outlined, 'Launch, updates and appearance.'),
  clusters('Clusters', Icons.cloud_outlined, 'Kubeconfig files, read-only contexts and icons.'),
  sidebar('Sidebar', Icons.view_sidebar_outlined, 'What the top of the sidebar shows, and in what order.'),
  views('Views', Icons.bookmark_outline, 'Saved views: order, names, contexts, import and export.'),
  integrations('Integrations', Icons.extension_outlined,
      'Turn off what you don\'t use, and add plugins from the Marketplace. Status is for the current cluster.'),
  addons('Add-ons', Icons.inventory_2_outlined, 'Cluster tools k8sman builds on (metrics-server, Prometheus, Trivy, …), installed with Helm on the current cluster.'),
  tables('Tables', Icons.table_rows_outlined, 'Each kind\'s table remembers its sort, column widths and filter.'),
  keyboard('Keyboard', Icons.keyboard_outlined, 'Shortcuts. Press ? outside a text field for this list anywhere.'),
  diagnostics('Diagnostics', Icons.bug_report_outlined,
      'Errors k8sman ran into, grouped. Kept on this computer and redacted; shared only if you copy the report or open an issue.'),
  about('About', Icons.info_outline, 'Version and updates.');

  final String title;
  final IconData icon;
  final String intro;
  const SettingsSection(this.title, this.icon, this.intro);

  /// The section `:settings <arg>` names (by a prefix of its name, or an
  /// alias), or null.
  static SettingsSection? parse(String arg) {
    final a = arg.trim().toLowerCase();
    if (a.isEmpty) return null;
    const aliases = {'add-ons': addons, 'add-on': addons, 'helm': addons, 'modules': integrations, 'plugins': integrations, 'marketplace': integrations, 'shortcuts': keyboard, 'keys': keyboard, 'updates': about, 'errors': diagnostics, 'report': diagnostics, 'kubeconfig': clusters, 'contexts': clusters};
    return aliases[a] ?? values.where((s) => s.name.startsWith(a)).firstOrNull;
  }
}

/// The sections shown: Add-ons only while that module (and Helm) is on.
List<SettingsSection> settingsSections(AppState app) => [
      for (final s in SettingsSection.values)
        if (s != SettingsSection.addons || moduleEnabled('addons', app.disabledModules)) s,
    ];

/// Shows the Settings page, at [section] if given (else where it was
/// left), with module [module]'s settings open under Integrations ▸
/// Installed, or at Integrations' sub-page [integrations].
void openSettings(BuildContext context, {SettingsSection? section, String? module, IntegrationsPage? integrations}) =>
    showSettings(context.read<AppState>(), section: section, module: module, integrations: integrations);

/// [openSettings] without a BuildContext (palette commands).
void showSettings(AppState app, {SettingsSection? section, String? module, IntegrationsPage? integrations}) {
  final page = module != null ? IntegrationsPage.installed : integrations;
  if (page != null) integrationsPage.value = page;
  final s = page != null ? SettingsSection.integrations : section;
  app.showView(MainView.settings, focus: s == null ? null : '$_focusPrefix${s.name}${module == null ? '' : '/$module'}');
}

const _focusPrefix = 'settings:';

/// Back from the Settings page to the page it was opened from (Esc).
void leaveSettings(AppState app) => app.showView(app.previousView == MainView.settings ? MainView.resources : app.previousView);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// Where the page was left, for the next time it opens.
  static SettingsSection _last = SettingsSection.general;

  SettingsSection _section = _last;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'settings search');
  final _focus = FocusNode(debugLabel: 'settings');
  final _scroll = ScrollController();
  final _modules = ModuleExpansion();
  late final PluginsController _plugins;

  @override
  void initState() {
    super.initState();
    _plugins = PluginsController(context.read<ApiClient?>());
    // Esc and ⌘F reach the page; `:` and `?` still bubble up to the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !textEntryFocused) _focus.requestFocus();
    });
    // Bundled plugins have rows under Integrations; their status (the
    // kinds the cluster serves) is fetched again for this cluster.
    pluginHost.addListener(_onPlugins);
    pluginHost.attach(context.read<AppState>().api);
    pluginHost.refresh();
  }

  void _onPlugins() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _focus.dispose();
    _scroll.dispose();
    pluginHost.removeListener(_onPlugins);
    _modules.dispose();
    _plugins.dispose();
    super.dispose();
  }

  void _clearSearch() => setState(_search.clear);

  void _show(SettingsSection s) {
    _last = s;
    setState(() {
      _section = s;
      _search.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// A deep link from [openSettings]: `settings:<section>[/<module>]`.
  void _takeFocus(AppState app) {
    final f = app.pageFocus;
    if (f == null || !f.startsWith(_focusPrefix)) return;
    app.pageFocus = null;
    final parts = f.substring(_focusPrefix.length).split('/');
    final section = settingsSections(app).where((s) => s.name == parts.first).firstOrNull;
    if (section == null) return;
    _last = _section = section;
    _search.clear();
    final module = parts.length > 1 ? parts[1] : null;
    // Quietly: the page is building, and rebuilds the rows anyway.
    if (module != null) _modules.open(module, notify: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final row = module == null ? null : _modules.keyFor(module).currentContext;
      if (row != null) {
        Scrollable.ensureVisible(row, alignment: 0.1);
      } else if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
  }

  void _back() => leaveSettings(context.read<AppState>());

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    if (_searchFocus.hasFocus) {
      if (_search.text.isNotEmpty) {
        _clearSearch();
      } else {
        _focus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    // A text field elsewhere on the page (a module's form): leave it first.
    if (textEntryFocused) {
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    _back();
    return KeyEventResult.handled;
  }

  List<SettingItem> _items(SettingsSection s) => switch (s) {
        SettingsSection.general => _generalSettings(),
        SettingsSection.clusters => clusterSettings(),
        SettingsSection.sidebar => sidebarSettings(),
        SettingsSection.views => viewSettings(),
        SettingsSection.integrations => integrationSettings(_modules, context.read<AppState>(), _plugins),
        SettingsSection.addons => _addonsSettings(),
        SettingsSection.tables => tableSettings(),
        SettingsSection.keyboard => _keyboardSettings(),
        SettingsSection.diagnostics => diagnosticsSettings(),
        SettingsSection.about => _aboutSettings(),
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    _takeFocus(app);
    final terms = _search.text.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final searching = terms.isNotEmpty;
    final matches = {
      if (searching)
        for (final s in settingsSections(app)) s: [for (final i in _items(s)) if (i.matches(terms, s.title)) i],
    };
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: CallbackShortcuts(
        bindings: {primaryShortcut(LogicalKeyboardKey.keyF): _searchFocus.requestFocus},
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(
            key: const ValueKey('settings-page'),
            title: 'Settings',
            leading: IconButton(
              key: const ValueKey('settings-back'),
              tooltip: 'Back (Esc)',
              iconSize: 18,
              icon: const Icon(Icons.arrow_back),
              onPressed: _back,
            ),
            actions: [
              SizedBox(
                width: 220,
                child: TextField(
                  key: const ValueKey('settings-search'),
                  controller: _search,
                  focusNode: _searchFocus,
                  onChanged: (_) => setState(() {}),
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, size: 15),
                    hintText: 'Search settings',
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            iconSize: 14,
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close),
                            onPressed: _clearSearch,
                          ),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: box.maxWidth < 760 ? 176 : 212,
                  child: _SectionList(
                    sections: settingsSections(app),
                    selected: searching ? null : (settingsSections(app).contains(_section) ? _section : SettingsSection.general),
                    counts: searching ? {for (final e in matches.entries) e.key: e.value.length} : null,
                    onTap: _show,
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: AppColors.of(context).separator),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 780),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(box.maxWidth < 760 ? 24 : 40, 28, box.maxWidth < 760 ? 24 : 40, 40),
                          child: SettingsSearchTerms(terms: terms, child: searching ? _results(matches) : _sectionBody(settingsSections(app).contains(_section) ? _section : SettingsSection.general)),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _sectionBody(SettingsSection s) {
    final theme = Theme.of(context);
    final title = Text(s.title, style: theme.textTheme.headlineSmall?.copyWith(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.3));
    final introStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor);
    final integrations = s == SettingsSection.integrations;
    return Column(key: ValueKey('settings-section-${s.name}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Integrations: Installed | Marketplace beside the title.
      if (integrations)
        Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [title, const IntegrationsPageSwitch()])
      else
        title,
      const SizedBox(height: 4),
      if (integrations)
        ValueListenableBuilder(valueListenable: integrationsPage, builder: (context, page, _) => Text(page.intro, style: introStyle))
      else
        Text(s.intro, style: introStyle),
      const SizedBox(height: 28),
      if (integrations) IntegrationsBody(items: _items(s), plugins: _plugins) else SettingCards(_items(s)),
    ]);
  }

  Widget _results(Map<SettingsSection, List<SettingItem>> matches) {
    final theme = Theme.of(context);
    final found = [for (final e in matches.entries) if (e.value.isNotEmpty) e];
    if (found.isEmpty) {
      // A calm empty state, not an error.
      return Padding(
        key: const ValueKey('settings-no-results'),
        padding: const EdgeInsets.only(top: 64),
        child: Column(children: [
          Icon(Icons.search_off_rounded, size: 30, color: AppColors.of(context).faint),
          const SizedBox(height: 12),
          Text('No settings match “${_search.text.trim()}”', textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Try another word, or pick a section on the left.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 10),
          TextButton(onPressed: _clearSearch, child: const Text('Clear search')),
        ]),
      );
    }
    final total = found.fold<int>(0, (n, e) => n + e.value.length);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(total == 1 ? '1 setting' : '$total settings', style: theme.textTheme.headlineSmall?.copyWith(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
      const SizedBox(height: 4),
      Text('Matching “${_search.text.trim()}”', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
      const SizedBox(height: 28),
      for (final (i, e) in found.indexed) ...[
        if (i > 0) const SizedBox(height: 26),
        SettingsGroupTitle(e.key.title, trailing: Text('${e.value.length}')),
        SettingCards(e.value, headings: false),
      ],
    ]);
  }

  // ---- General ----

  List<SettingItem> _generalSettings() => [
        SettingItem.row(
          key: const ValueKey('settings-launch'),
          group: 'Launch',
          label: 'Open at launch',
          description: 'Opens the Overview on the context you used last, or a saved view.',
          keywords: const ['startup', 'start', 'launch view', 'saved view', 'reconnect'],
          trailing: (context) => const _LaunchViewSelect(),
        ),
        SettingItem(
          key: const ValueKey('settings-auto-updates'),
          group: 'Updates',
          label: 'Check for updates automatically',
          description: 'Looks for a new release in the background every few hours.',
          keywords: const ['update', 'updates', 'sparkle', 'release', 'version'],
          builder: (context) => const _AutomaticUpdates(),
        ),
        SettingItem.row(
          key: const ValueKey('settings-logs-newest-first'),
          group: 'Logs',
          label: 'Newest line first',
          description: 'The log viewer shows the newest line at the top, and following stays pinned there. Also in the log toolbar\'s ⋯ menu.',
          keywords: const ['log', 'logs', 'order', 'reverse', 'newest', 'latest', 'descending'],
          trailing: (context) => SettingSwitch(
            key: const ValueKey('logs-newest-first-switch'),
            value: context.watch<LogDock>().newestFirst,
            onChanged: context.read<LogDock>().setNewestFirst,
          ),
        ),
        SettingItem.row(
          key: const ValueKey('settings-logs-colour-syntax'),
          group: 'Logs',
          label: 'Colour structured logs',
          description: 'Colours the keys, values and level of JSON and key=value (logfmt) log lines. Copy and download stay plain text.',
          keywords: const ['log', 'logs', 'json', 'logfmt', 'syntax', 'colour', 'color', 'highlight', 'structured'],
          trailing: (context) => SettingSwitch(
            key: const ValueKey('logs-colour-syntax-switch'),
            value: context.watch<LogDock>().colourSyntax,
            onChanged: context.read<LogDock>().setColourSyntax,
          ),
        ),
        SettingItem.row(
          key: const ValueKey('settings-app-links'),
          group: 'Links',
          label: 'Use links that open the app directly (k8sman://)',
          description: 'Copy link (on an object, a table\'s kind or a page) copies a k8sman.dev link that opens the same place in a '
              'colleague\'s k8sman, or offers the download. A link only names the context, a hash of the cluster\'s address, '
              'the namespace, kind and object, and '
              'opening one only navigates: switching context asks first. Hold ⌥ while choosing Copy link for the k8sman:// form.',
          keywords: const ['link', 'links', 'share', 'url', 'deep link', 'k8sman.dev', 'scheme', 'copy link'],
          trailing: (context) => SettingSwitch(
            key: const ValueKey('app-links-switch'),
            value: context.select<AppState, bool>((a) => a.appLinks),
            onChanged: context.read<AppState>().setAppLinks,
          ),
        ),
        SettingItem.row(
          group: 'Appearance',
          label: 'Appearance',
          description: 'k8sman follows the system\'s light or dark appearance.',
          keywords: const ['theme', 'dark', 'light', 'mode', 'colour', 'color'],
          trailing: (context) => Text(Theme.of(context).brightness == Brightness.dark ? 'Dark' : 'Light',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
        ),
      ];

  // ---- Add-ons ----

  List<SettingItem> _addonsSettings() => [
        SettingItem(
          key: const ValueKey('settings-addons'),
          label: 'Add-ons',
          description: 'Install, upgrade or remove cluster tools on the current cluster.',
          keywords: const ['addons', 'add-on', 'add-ons', 'helm', 'install', 'metrics-server', 'prometheus', 'trivy', 'argo cd', 'argocd', 'envoy gateway', 'cert-manager', 'catalog'],
          builder: (context) => const Padding(padding: EdgeInsets.fromLTRB(14, 12, 14, 18), child: AddonsView(embedded: true)),
        ),
      ];

  // ---- Keyboard ----

  List<SettingItem> _keyboardSettings() => [
        for (final (title, rows) in keyboardShortcutGroups)
          SettingItem(
            group: title,
            label: title,
            keywords: [for (final (keys, what) in rows) '$keys $what', 'shortcut', 'key'],
            builder: (_) => Padding(padding: const EdgeInsets.fromLTRB(14, 8, 14, 8), child: KeyboardShortcutGroup(null, rows)),
          ),
      ];

  // ---- About ----

  List<SettingItem> _aboutSettings() => [
        SettingItem(
          key: const ValueKey('settings-about'),
          label: 'k8sman',
          description: 'Version',
          keywords: const ['about', 'version', 'github'],
          builder: (context) => const _AboutRow(),
        ),
        SettingItem(
          key: const ValueKey('settings-check-updates'),
          label: 'Check for updates',
          description: 'Check now, or install a new version.',
          keywords: const ['update', 'updates', 'install', 'release'],
          builder: (context) {
            final updates = context.watch<UpdateController?>();
            return SettingRow(
              label: 'Updates',
              child: updates == null ? const SettingsEmpty('Updates are not available in this build.') : const UpdateStatus(automatic: false),
            );
          },
        ),
      ];
}

/// The section list on the left: an icon in a soft tile and the name per
/// section, the current one on a soft pill. While searching, [counts]
/// dims the sections without matches and counts the rest.
class _SectionList extends StatelessWidget {
  final List<SettingsSection> sections;
  final SettingsSection? selected;
  final Map<SettingsSection, int>? counts;
  final ValueChanged<SettingsSection> onTap;
  const _SectionList({required this.sections, required this.selected, required this.counts, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ColoredBox(
      color: colors.inspector,
      child: ListView(padding: const EdgeInsets.fromLTRB(10, 16, 10, 16), children: [
        for (final s in sections)
          Hoverable(
            key: ValueKey('settings-nav-${s.name}'),
            cursor: SystemMouseCursors.basic,
            onTap: () => onTap(s),
            builder: (h) {
              final on = s == selected;
              final n = counts?[s];
              final dim = n == 0;
              final fg = dim ? colors.faint : theme.colorScheme.onSurface;
              return Container(
                height: 34,
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  // A soft pill: a grey wash rather than the accent.
                  color: on ? theme.colorScheme.onSurface.withValues(alpha: dark ? 0.09 : 0.07) : (h ? colors.hover : null),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: on ? theme.colorScheme.primary.withValues(alpha: dark ? 0.22 : 0.14) : theme.colorScheme.onSurface.withValues(alpha: dim ? 0.03 : 0.06),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(s.icon, size: 14, color: on ? theme.colorScheme.primary : (dim ? colors.faint : theme.hintColor)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
                    ),
                  ),
                  // Integrations: the plugin updates waiting (outside a search).
                  if (counts == null && s == SettingsSection.integrations)
                    ListenableBuilder(
                      listenable: pluginNotices,
                      builder: (context, _) => pluginNotices.updates.isEmpty ? const SizedBox.shrink() : CountBadge(pluginNotices.updates.length),
                    ),
                  if (n != null && n > 0) Text('$n', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
              );
            },
          ),
      ]),
    );
  }
}

class _LaunchViewSelect extends StatelessWidget {
  const _LaunchViewSelect();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final small = Theme.of(context).textTheme.bodySmall;
    final ids = {for (final v in app.savedViews) v.id};
    return MenuSelect<String>(
      key: const ValueKey('launch-view-select'),
      value: ids.contains(app.launchViewId) ? app.launchViewId : '',
      options: [
        ('', Text('Overview, on the last context', style: small)),
        for (final v in app.savedViews) (v.id, Text(v.name, style: small, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (id) => app.setLaunchView(id).catchError((Object e) {
        if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }),
    );
  }
}

class _AutomaticUpdates extends StatelessWidget {
  const _AutomaticUpdates();

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateController?>();
    final reason = u == null ? 'not available in this build' : u.disabledReason;
    return SettingRow(
      label: 'Check for updates automatically',
      description: reason != null
          ? 'Updates are off: $reason.'
          : u!.manualInstall
              ? 'k8sman looks for a new release on GitHub every few hours.'
              : 'Looks for a new release in the background every few hours.',
      trailing: reason != null || u!.manualInstall
          ? null
          : SettingSwitch(key: const ValueKey('auto-updates-switch'), value: u.automaticChecks, onChanged: u.setAutomaticChecks),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    final info = context.watch<UpdateController?>()?.info;
    final version = info == null || info.version.isEmpty ? 'unknown' : info.displayVersion;
    return SettingRow(
      leading: const AppLogo(size: 34),
      label: 'k8sman',
      description: 'Version $version · A Kubernetes desktop app',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(onPressed: openSite, child: const Text('k8sman.dev')),
        TextButton(onPressed: openRepo, child: const Text('GitHub')),
      ]),
    );
  }
}
