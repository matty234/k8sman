/// The Settings page: every user setting in one place, a section list on
/// the left and the section on the right, with a search across all of
/// them. Open it with [openSettings] (⌘, / Ctrl+,, the sidebar's gear,
/// the palette's "Settings…" or `:settings [section]`). Changes apply and
/// save as they're made.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/updates/update_controller.dart';
import '../../app/updates/update_ui.dart';
import '../../state/app_state.dart';
import '../keyboard_help.dart';
import '../keys.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cluster_settings.dart';
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
      'Turn off what you don\'t use: its pages, panels and checks go away on every cluster. Status is for the current cluster.'),
  tables('Tables', Icons.table_rows_outlined, 'Each kind\'s table remembers its sort, column widths and filter.'),
  keyboard('Keyboard', Icons.keyboard_outlined, 'Shortcuts. Press ? outside a text field for this list anywhere.'),
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
    const aliases = {'modules': integrations, 'plugins': integrations, 'shortcuts': keyboard, 'keys': keyboard, 'updates': about, 'kubeconfig': clusters, 'contexts': clusters};
    return aliases[a] ?? values.where((s) => s.name.startsWith(a)).firstOrNull;
  }
}

/// Shows the Settings page, at [section] if given (else where it was
/// left), with module [module]'s settings open under Integrations.
void openSettings(BuildContext context, {SettingsSection? section, String? module}) =>
    showSettings(context.read<AppState>(), section: section, module: module);

/// [openSettings] without a BuildContext (palette commands).
void showSettings(AppState app, {SettingsSection? section, String? module}) {
  final s = module != null ? SettingsSection.integrations : section;
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

  @override
  void initState() {
    super.initState();
    // Esc and ⌘F reach the page; `:` and `?` still bubble up to the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !textEntryFocused) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _focus.dispose();
    _scroll.dispose();
    _modules.dispose();
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
    final section = SettingsSection.values.where((s) => s.name == parts.first).firstOrNull;
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
        SettingsSection.integrations => integrationSettings(_modules),
        SettingsSection.tables => tableSettings(),
        SettingsSection.keyboard => _keyboardSettings(),
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
        for (final s in SettingsSection.values) s: [for (final i in _items(s)) if (i.matches(terms, s.title)) i],
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
                  width: box.maxWidth < 760 ? 168 : 200,
                  child: _SectionList(
                    selected: searching ? null : _section,
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
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(box.maxWidth < 760 ? 20 : 28, 20, box.maxWidth < 760 ? 20 : 28, 32),
                          child: searching ? _results(matches) : _sectionBody(_section),
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
    return Column(key: ValueKey('settings-section-${s.name}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(s.title, style: theme.textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(s.intro, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      const SizedBox(height: 18),
      SettingCards(_items(s)),
    ]);
  }

  Widget _results(Map<SettingsSection, List<SettingItem>> matches) {
    final theme = Theme.of(context);
    final found = [for (final e in matches.entries) if (e.value.isNotEmpty) e];
    if (found.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(child: Text('No settings match “${_search.text.trim()}”.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor))),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, e) in found.indexed) ...[
        if (i > 0) const SizedBox(height: 26),
        Row(children: [
          Icon(e.key.icon, size: 16, color: theme.hintColor),
          const SizedBox(width: 8),
          Text(e.key.title, style: theme.textTheme.titleMedium),
        ]),
        const SizedBox(height: 10),
        SettingCards(e.value),
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
          group: 'Appearance',
          label: 'Appearance',
          description: 'k8sman follows the system\'s light or dark appearance.',
          keywords: const ['theme', 'dark', 'light', 'mode', 'colour', 'color'],
          trailing: (context) => Text(Theme.of(context).brightness == Brightness.dark ? 'Dark' : 'Light',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
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

/// The section list on the left. While searching, [counts] dims the
/// sections without matches.
class _SectionList extends StatelessWidget {
  final SettingsSection? selected;
  final Map<SettingsSection, int>? counts;
  final ValueChanged<SettingsSection> onTap;
  const _SectionList({required this.selected, required this.counts, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return ColoredBox(
      color: colors.inspector,
      child: ListView(padding: const EdgeInsets.fromLTRB(8, 12, 8, 12), children: [
        for (final s in SettingsSection.values)
          Hoverable(
            key: ValueKey('settings-nav-${s.name}'),
            cursor: SystemMouseCursors.basic,
            onTap: () => onTap(s),
            builder: (h) {
              final on = s == selected;
              final n = counts?[s];
              final dim = n == 0;
              final fg = on ? theme.colorScheme.onSurface : (dim ? colors.faint : theme.colorScheme.onSurface);
              return Container(
                height: 30,
                margin: const EdgeInsets.only(bottom: 1),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: on ? colors.selection : (h ? colors.hover : null),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  Icon(s.icon, size: 16, color: on ? theme.colorScheme.primary : (dim ? colors.faint : theme.hintColor)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: fg))),
                  if (n != null && n > 0) Text('$n', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
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
    final theme = Theme.of(context);
    final info = context.watch<UpdateController?>()?.info;
    final version = info == null || info.version.isEmpty ? 'unknown' : info.displayVersion;
    return SettingRow(
      leading: Icon(Icons.sailing_outlined, size: 30, color: theme.colorScheme.primary),
      label: 'k8sman',
      description: 'Version $version · A Kubernetes desktop app',
      trailing: TextButton(onPressed: openRepo, child: const Text('GitHub')),
    );
  }
}
