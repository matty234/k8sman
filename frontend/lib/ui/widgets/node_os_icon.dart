import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../util/node_os.dart';

/// A node's base OS as a small monochrome glyph in the hint colour, with
/// the OS image, platform and runtime in its tooltip. Bundled glyphs are
/// in assets/icons/os/ (sources in assets/icons/ATTRIBUTION.md); OSes
/// without a usable logo get a letter badge. Nothing when the node reports
/// no OS.
class NodeOsIcon extends StatelessWidget {
  final Json node;
  final double size;
  const NodeOsIcon(this.node, {super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final os = nodeOsOf(node);
    if (os == null) return const SizedBox.shrink();
    return Tooltip(message: os.tooltip, child: NodeOsGlyph(os.mark, size: size));
  }
}

/// Just the glyph for [mark], tinted [color] (default: the hint colour).
class NodeOsGlyph extends StatelessWidget {
  final NodeOsMark mark;
  final double size;
  final Color? color;
  const NodeOsGlyph(this.mark, {super.key, this.size = 14, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).hintColor;
    final key = ValueKey('node-os/${mark.name}');
    if (mark == NodeOsMark.windows) return Icon(Icons.window, key: key, size: size, color: c);
    final asset = mark.asset;
    if (asset != null) {
      return Image.asset(
        'assets/icons/os/$asset.png',
        key: key,
        width: size,
        height: size,
        color: c,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
      );
    }
    return Container(
      key: key,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(size * 0.24)),
      child: Text(
        mark.letter ?? '?',
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: c, fontSize: size * 0.66, height: 1, fontWeight: FontWeight.w700),
      ),
    );
  }
}
