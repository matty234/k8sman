import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// A titled, collapsible block in the detail sidebar. Every panel section
/// should be one of these.
///
/// Sections render as quiet groups: a hairline above, a small title row and
/// the content flush below, with no boxed border. Pass [card] for a summary
/// treatment (a softly filled card, e.g. for the first, most important
/// section of a panel).
class DetailSection extends StatefulWidget {
  final String title;
  final IconData? icon;
  final Widget child;

  /// Shown right of the title (e.g. a count badge or action button).
  final Widget? trailing;
  final bool initiallyExpanded;

  /// Render as a filled summary card instead of a plain group.
  final bool card;

  /// Draw the hairline above the section.
  final bool divider;

  const DetailSection({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.initiallyExpanded = true,
    this.card = false,
    this.divider = true,
  });

  @override
  State<DetailSection> createState() => _DetailSectionState();
}

class _DetailSectionState extends State<DetailSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final header = Hoverable(
      onTap: () => setState(() => _expanded = !_expanded),
      builder: (hovered) => SizedBox(
        height: 26,
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.titleSmall?.copyWith(fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: _expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 120),
                child: Icon(Icons.chevron_right, size: 15, color: hovered || !_expanded ? theme.hintColor : colors.faint.withValues(alpha: 0.7)),
              ),
            ]),
          ),
          if (widget.trailing != null)
            DefaultTextStyle.merge(style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor), child: widget.trailing!),
        ]),
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (_expanded) Padding(padding: const EdgeInsets.only(top: 4), child: widget.child),
      ],
    );
    if (widget.card) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.separator, width: 0.5),
        ),
        child: body,
      );
    }
    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      decoration: widget.divider ? BoxDecoration(border: Border(top: BorderSide(color: colors.separator))) : null,
      child: body,
    );
  }
}

/// Click target with a hover state and no Material ink. [builder] receives
/// whether the pointer is over it.
class Hoverable extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;
  final MouseCursor? cursor;
  const Hoverable({super.key, required this.builder, this.onTap, this.cursor});

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor ?? (widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer),
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(_hover),
      ),
    );
  }
}

/// A native-feeling pop-up button: [builder] draws the control (given its
/// hover state); clicking opens [items] in a menu aligned under it.
class MenuButton<T> extends StatelessWidget {
  final List<PopupMenuEntry<T>> Function() items;
  final ValueChanged<T> onSelected;
  final Widget Function(bool hovered) builder;
  final String? tooltip;
  const MenuButton({super.key, required this.items, required this.onSelected, required this.builder, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final button = Builder(
      builder: (ctx) => Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () async {
          final box = ctx.findRenderObject() as RenderBox?;
          final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
          if (box == null || overlay == null) return;
          final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
          final v = await showMenu<T>(
            context: ctx,
            position: RelativeRect.fromLTRB(topLeft.dx, topLeft.dy, overlay.size.width - topLeft.dx - box.size.width, 0),
            constraints: BoxConstraints(minWidth: box.size.width, maxWidth: 420),
            items: items(),
          );
          if (v != null) onSelected(v);
        },
        builder: builder,
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Lets the user drag the window by this area (the unified titlebar/toolbar
/// rows). No-op outside the macOS app. Children such as buttons still get
/// their clicks; only drags move the window.
class WindowDragArea extends StatelessWidget {
  static const _channel = MethodChannel('k8sman/window');
  final Widget child;
  const WindowDragArea({super.key, required this.child});

  static void _invoke(String method) => _channel.invokeMethod<void>(method).catchError((Object _) {});

  @override
  Widget build(BuildContext context) {
    if (!nativeMacChrome) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _invoke('startDrag'),
      child: child,
    );
  }
}

/// A two-column key/value grid. Values may be Strings or Widgets; null and
/// empty-string values are skipped so callers can pass optional fields freely.
class KeyValueTable extends StatelessWidget {
  final List<(String, Object?)> entries;
  final double keyWidth;
  const KeyValueTable(this.entries, {super.key, this.keyWidth = 140});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = entries.where((e) => e.$2 != null && !(e.$2 is String && (e.$2 as String).isEmpty)).toList();
    if (visible.isEmpty) return Text('—', style: TextStyle(color: theme.hintColor));
    final keyStyle = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final valueStyle = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in visible)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: keyWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(k, style: keyStyle, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ),
              Expanded(
                child: v is Widget ? DefaultTextStyle.merge(style: valueStyle, child: v) : SelectableText('$v', style: valueStyle),
              ),
            ]),
          ),
      ],
    );
  }
}

/// Status indicator; colour is inferred via [severityOf].
///
/// Regular badges are a softly tinted capsule. [dense] ones (tables, condition
/// lists, events) are a coloured dot plus text, which keeps lists quiet: only
/// warnings and errors colour their text.
class StatusBadge extends StatelessWidget {
  final String text;
  final Severity? severity;
  final bool dense;
  const StatusBadge(this.text, {super.key, this.severity, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sev = severity ?? severityOf(text);
    final c = severityColor(context, sev);
    if (dense) {
      final loud = sev == Severity.error || sev == Severity.warn;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: loud ? c : theme.colorScheme.onSurface,
              fontWeight: loud ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ]);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: theme.brightness == Brightness.dark ? 0.15 : 0.11),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: c, fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.4)),
    );
  }
}

/// Wrap of `key=value` chips (key muted). Shows the first [maxVisible] with
/// a "+N more" toggle for the rest. Click a chip to copy it.
class LabelChips extends StatefulWidget {
  final Map<String, dynamic>? labels;
  final String emptyText;
  final int maxVisible;
  const LabelChips(this.labels, {super.key, this.emptyText = 'none', this.maxVisible = 8});

  @override
  State<LabelChips> createState() => _LabelChipsState();
}

class _LabelChipsState extends State<LabelChips> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = widget.labels ?? const {};
    if (l.isEmpty) return Text(widget.emptyText, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    final entries = l.entries.toList();
    final collapsible = entries.length > widget.maxVisible;
    final shown = _all || !collapsible ? entries : entries.take(widget.maxVisible).toList();
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final e in shown) _KeyValueChip(k: e.key, v: '${e.value}'),
      if (collapsible)
        Hoverable(
          onTap: () => setState(() => _all = !_all),
          builder: (h) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              _all ? 'Show less' : '+${entries.length - shown.length} more',
              style: theme.textTheme.labelSmall?.copyWith(color: h ? theme.colorScheme.primary : theme.hintColor),
            ),
          ),
        ),
    ]);
  }
}

class _KeyValueChip extends StatelessWidget {
  final String k;
  final String v;
  const _KeyValueChip({required this.k, required this.v});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = '$k=$v';
    final value = v.length > 60 ? '${v.substring(0, 57)}…' : v;
    final chip = Hoverable(
      onTap: () => copyToClipboard(context, full),
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: chipFill(context, hovered: h), borderRadius: BorderRadius.circular(4)),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$k=', style: TextStyle(color: theme.hintColor)),
            TextSpan(text: value),
          ]),
          style: monoStyle(context, size: 11),
        ),
      ),
    );
    return full.length > 60 ? Tooltip(message: full, child: chip) : chip;
  }
}

/// Background for chip-like elements; [color] tints it.
Color chipFill(BuildContext context, {Color? color, bool hovered = false}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (color != null) return color.withValues(alpha: hovered ? 0.30 : 0.20);
  return dark ? Color.fromARGB(hovered ? 0x26 : 0x14, 255, 255, 255) : Color.fromARGB(hovered ? 0x16 : 0x0B, 0, 0, 0);
}

/// Small monospace chip; click copies [copyValue] if given.
class Chipish extends StatelessWidget {
  final String text;
  final String? copyValue;
  final Color? color;
  const Chipish({super.key, required this.text, this.copyValue, this.color});

  @override
  Widget build(BuildContext context) {
    final display = text.length > 80 ? '${text.substring(0, 77)}…' : text;
    Widget chip(bool hovered) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: chipFill(context, color: color, hovered: hovered), borderRadius: BorderRadius.circular(4)),
          child: Text(display, style: monoStyle(context, size: 11)),
        );
    final body = copyValue == null ? chip(false) : Hoverable(onTap: () => copyToClipboard(context, copyValue!), builder: chip);
    return text.length > 80 ? Tooltip(message: text, child: body) : body;
  }
}

/// Table of status.conditions with status dots and relative times.
class ConditionsTable extends StatelessWidget {
  final List<dynamic>? conditions;
  const ConditionsTable(this.conditions, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conds = asMapList(conditions);
    if (conds.isEmpty) return Text('No conditions', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in conds)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text('${c['type']}', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 10),
                    StatusBadge('${c['status']}', dense: true, severity: _condSeverity(c)),
                    if (c['reason'] != null) ...[
                      const SizedBox(width: 8),
                      Flexible(child: Text('${c['reason']}', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                AgeText(c['lastTransitionTime'] ?? c['lastUpdateTime'] ?? c['lastHeartbeatTime'], suffix: ' ago'),
              ]),
              if ((c['message'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: SelectableText('${c['message']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                ),
            ]),
          ),
      ],
    );
  }

  /// Some condition types are "bad when True" (node pressure, Failed, etc.).
  static Severity _condSeverity(Json c) {
    final type = '${c['type']}';
    final status = '${c['status']}';
    const negative = {'MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable', 'Failed', 'ReplicaFailure', 'Stalled', 'Degraded', 'NonStructuralSchema', 'Terminating'};
    final bad = negative.contains(type) || type.endsWith('Failed') || type.endsWith('Error');
    if (status == 'Unknown') return Severity.warn;
    final good = (status == 'True') != bad;
    return good ? Severity.ok : (bad ? Severity.error : Severity.warn);
  }
}

/// Relative age that ticks; tooltip shows the absolute time.
class AgeText extends StatefulWidget {
  final dynamic timestamp;
  final String suffix;
  final TextStyle? style;
  const AgeText(this.timestamp, {super.key, this.suffix = '', this.style});

  @override
  State<AgeText> createState() => _AgeTextState();
}

class _AgeTextState extends State<AgeText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = parseTime(widget.timestamp);
    if (t == null) return const SizedBox.shrink();
    final style = widget.style ?? Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
    return Tooltip(message: t.toLocal().toString(), child: Text('${formatAge(t)}${widget.suffix}', style: style));
  }
}

/// Selectable monospace block with a copy button (shown on hover).
class CodeBlock extends StatefulWidget {
  final String text;
  final int? maxLines;
  final bool wrap;

  /// What the copy button copies (defaults to [text]); use when [text] is a
  /// truncated/pretty-printed rendering of a longer value.
  final String? copyValue;
  const CodeBlock(this.text, {super.key, this.maxLines, this.wrap = true, this.copyValue});

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final content = SelectableText(widget.text, style: monoStyle(context, size: 11.5), maxLines: widget.maxLines);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        decoration: BoxDecoration(
          color: dark ? const Color(0x0DFFFFFF) : const Color(0x08000000),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.separator, width: 0.5),
        ),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 30, 7),
            child: widget.wrap ? content : SingleChildScrollView(scrollDirection: Axis.horizontal, child: content),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0.35,
              duration: const Duration(milliseconds: 120),
              child: IconButton(
                iconSize: 13,
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () => copyToClipboard(context, widget.copyValue ?? widget.text),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Clickable reference to another object; opens it in the sidebar (with
/// back navigation). Renders as plain text if the kind isn't served.
class ResourceLink extends StatelessWidget {
  final ObjectRef ref;
  final String? label;
  const ResourceLink(this.ref, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final text = label ?? '${ref.kind}/${ref.name}';
    final known = app.typeFor(ref.group, ref.kind) != null;
    if (!known) return SelectableText(text, style: theme.textTheme.bodySmall);
    return Hoverable(
      onTap: () => app.openRef(ref),
      builder: (h) => Text(text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.primary,
            decoration: h ? TextDecoration.underline : TextDecoration.none,
            decorationColor: theme.colorScheme.primary.withValues(alpha: 0.6),
          )),
    );
  }
}

/// Collapsible tree for arbitrary JSON values (spec/status of CRs, etc.).
class JsonTree extends StatelessWidget {
  final dynamic value;
  final int initiallyExpandedDepth;
  const JsonTree(this.value, {super.key, this.initiallyExpandedDepth = 1});

  @override
  Widget build(BuildContext context) => _JsonNode(name: null, value: value, depth: 0, expandDepth: initiallyExpandedDepth);
}

class _JsonNode extends StatefulWidget {
  final String? name;
  final dynamic value;
  final int depth;
  final int expandDepth;
  const _JsonNode({required this.name, required this.value, required this.depth, required this.expandDepth});

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool _open = widget.depth < widget.expandDepth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.value;
    final keyStyle = monoStyle(context, size: 11.5, color: theme.hintColor);
    final isContainer = v is Map || v is List;
    if (!isContainer) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.name != null) Text('${widget.name}: ', style: keyStyle),
          Expanded(child: SelectableText(_scalar(v), style: monoStyle(context, size: 11.5, color: _scalarColor(context, v)))),
        ]),
      );
    }
    final entries = v is Map ? v.entries.map((e) => (e.key.toString(), e.value)).toList() : [for (var i = 0; i < (v as List).length; i++) ('[$i]', v[i])];
    if (widget.depth == 0 && widget.name == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (k, child) in entries) _JsonNode(name: k, value: child, depth: 1, expandDepth: widget.expandDepth),
        if (entries.isEmpty) Text(v is Map ? '{}' : '[]', style: monoStyle(context, size: 11.5)),
      ]);
    }
    final summary = v is Map ? '{${entries.length}}' : '[${entries.length}]';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Hoverable(
        onTap: () => setState(() => _open = !_open),
        builder: (h) => Row(children: [
          Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 16, color: h ? theme.colorScheme.onSurface : theme.hintColor),
          Text('${widget.name}', style: keyStyle.copyWith(color: h ? theme.colorScheme.onSurface : null)),
          const SizedBox(width: 6),
          Text(summary, style: monoStyle(context, size: 11.5, color: AppColors.of(context).faint)),
        ]),
      ),
      if (_open)
        Container(
          margin: const EdgeInsets.only(left: 7),
          padding: const EdgeInsets.only(left: 9),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: AppColors.of(context).separator))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (k, child) in entries) _JsonNode(name: k, value: child, depth: widget.depth + 1, expandDepth: widget.expandDepth),
          ]),
        ),
    ]);
  }

  static String _scalar(dynamic v) => v is String ? v : jsonEncode(v);

  static Color? _scalarColor(BuildContext context, dynamic v) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (v is num) return dark ? const Color(0xFFE9B04A) : const Color(0xFFA65F00);
    if (v is bool) return Theme.of(context).colorScheme.tertiary;
    if (v == null) return Theme.of(context).hintColor;
    return null;
  }
}

/// Placeholder / empty / error states for async sections.
class InlineMessage extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool isError;
  const InlineMessage(this.text, {super.key, this.icon = Icons.info_outline, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = isError ? theme.colorScheme.error : theme.hintColor;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(isError ? Icons.error_outline : icon, size: 14, color: c)),
      const SizedBox(width: 6),
      Expanded(child: SelectableText(text, style: theme.textTheme.bodySmall?.copyWith(color: c))),
    ]);
  }
}

/// Runs [future] and renders loading / error / data states.
class AsyncSection<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const AsyncSection({super.key, required this.future, required this.builder});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          if (snap.connectionState != ConnectionState.done && !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
            );
          }
          return builder(context, snap.data as T);
        },
      );
}

/// Copies [text]. The snackbar echoes the value unless [label] is given —
/// always pass a label for sensitive values (e.g. `label: 'decoded API_TOKEN'`).
void copyToClipboard(BuildContext context, String text, {String? label}) {
  Clipboard.setData(ClipboardData(text: text));
  final shown = label ?? (text.length > 40 ? '${text.substring(0, 40)}…' : text);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('Copied $shown'), duration: const Duration(seconds: 1)));
}
