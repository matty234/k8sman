import 'dart:async';

import 'package:flutter/material.dart';

import '../../addons/addon_status.dart' show compareChartVersions, sameChartVersion;
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import '../widgets/searchable_picker.dart';
import 'helm_api.dart';
import '../../api/error_info.dart' show errorText;

/// Version picker for an `oci://` chart reference: fetches the registry's
/// tags and shows a searchable dropdown with [current] marked and newer
/// versions highlighted. If the fetch fails it is a free-text field with
/// the error as its hint, so a version can still be typed.
class OciVersionField extends StatefulWidget {
  final HelmApi api;
  final String ref;

  /// The version the release runs now, if known.
  final String? current;
  final String version;
  final ValueChanged<String> onChanged;
  const OciVersionField({super.key, required this.api, required this.ref, required this.version, required this.onChanged, this.current});

  @override
  State<OciVersionField> createState() => _OciVersionFieldState();
}

class _OciVersionFieldState extends State<OciVersionField> {
  OciVersions? _versions;
  String? _error;
  Timer? _debounce;
  late final _text = TextEditingController(text: widget.version);

  @override
  void initState() {
    super.initState();
    _load(immediately: true);
  }

  @override
  void didUpdateWidget(OciVersionField old) {
    super.didUpdateWidget(old);
    if (old.ref != widget.ref) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _load({bool immediately = false}) {
    _debounce?.cancel();
    _versions = null;
    _error = null;
    final ref = widget.ref;
    _debounce = Timer(immediately ? Duration.zero : const Duration(milliseconds: 500), () async {
      try {
        final v = await widget.api.ociVersions(ref);
        if (mounted && ref == widget.ref) setState(() => _versions = v);
      } catch (e) {
        if (mounted && ref == widget.ref) setState(() => _error = errorText(e));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vs = _versions;
    if (vs == null && _error == null) {
      return InputDecorator(
        decoration: const InputDecoration(labelText: 'Version', isDense: true),
        child: Row(children: [
          Expanded(child: Text(widget.version.isEmpty ? 'loading versions…' : widget.version, style: monoStyle(context))),
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        ]),
      );
    }
    if (vs == null) {
      return TextField(
        controller: _text,
        onChanged: widget.onChanged,
        style: monoStyle(context),
        decoration: InputDecoration(
          labelText: 'Version',
          hintText: 'latest',
          isDense: true,
          helperText: "Couldn't list versions: $_error",
          helperMaxLines: 3,
          helperStyle: TextStyle(color: severityColor(context, Severity.warn)),
        ),
      );
    }
    final cur = widget.current;
    final newer = cur == null ? 0 : vs.versions.where((v) => compareChartVersions(v, cur) > 0).length;
    String? tag(String v) {
      if (cur != null && sameChartVersion(v, cur)) return 'current';
      if (cur != null && compareChartVersions(v, cur) > 0) return 'newer';
      return v == vs.latest ? 'latest' : null;
    }

    final items = [for (final v in vs.versions) PickerOption<String>(v, v, detail: tag(v))];
    return SearchablePicker<String>(
      items: () => items,
      selected: widget.version,
      hint: 'Search versions',
      onSelected: widget.onChanged,
      builder: (hovered) => InputDecorator(
        decoration: const InputDecoration(labelText: 'Version', isDense: true, suffixIcon: Icon(Icons.arrow_drop_down)),
        child: Row(children: [
          Expanded(child: Text(widget.version.isEmpty ? 'latest (${vs.latest})' : widget.version, style: monoStyle(context))),
          if (newer > 0)
            Text('$newer newer', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.ok), fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
