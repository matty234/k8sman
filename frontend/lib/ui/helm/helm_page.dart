import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'helm_view.dart';
import 'market/charts_view.dart';
import 'market/repos_view.dart';

enum HelmMode { releases, charts, repositories }

/// The Helm page: installed releases, the charts browser (your repositories
/// and Artifact Hub) and your repositories, switched from the header.
class HelmPage extends StatefulWidget {
  const HelmPage({super.key});

  @override
  State<HelmPage> createState() => _HelmPageState();
}

class _HelmPageState extends State<HelmPage> {
  // Remembered while the app runs.
  static HelmMode _last = HelmMode.releases;
  HelmMode _mode = _last;

  void _set(HelmMode m) => setState(() => _mode = _last = m);

  Widget _switch(bool compact) => HelmModeSwitch(mode: _mode, compact: compact, onChanged: _set);

  @override
  Widget build(BuildContext context) {
    // A release to focus (Add-ons → View release) shows the releases.
    if (context.select<AppState, bool>((a) => a.pageFocus != null) && _mode != HelmMode.releases) _mode = _last = HelmMode.releases;
    return switch (_mode) {
      HelmMode.releases => HelmView(modeSwitch: _switch),
      HelmMode.charts => HelmChartsView(modeSwitch: _switch, onShowRepos: () => _set(HelmMode.repositories)),
      HelmMode.repositories => HelmReposView(modeSwitch: _switch),
    };
  }
}

/// Releases / Charts / Repositories, icons only when [compact].
class HelmModeSwitch extends StatelessWidget {
  final HelmMode mode;
  final bool compact;
  final ValueChanged<HelmMode> onChanged;
  const HelmModeSwitch({super.key, required this.mode, required this.onChanged, this.compact = false});

  static const _labels = {HelmMode.releases: 'Releases', HelmMode.charts: 'Charts', HelmMode.repositories: 'Repositories'};
  static const _icons = {HelmMode.releases: Icons.sailing_outlined, HelmMode.charts: Icons.storefront_outlined, HelmMode.repositories: Icons.dns_outlined};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 24,
      child: SegmentedButton<HelmMode>(
        key: const ValueKey('helm-mode'),
        style: ButtonStyle(
          visualDensity: const VisualDensity(horizontal: -3, vertical: -4),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: compact ? 6 : 10)),
          minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
          textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        showSelectedIcon: false,
        segments: [
          for (final m in HelmMode.values)
            ButtonSegment(
              value: m,
              tooltip: compact ? _labels[m] : null,
              label: compact ? Icon(_icons[m], size: 14) : Text(_labels[m]!, key: ValueKey('helm-mode-${m.name}')),
            ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}
