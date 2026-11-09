import 'package:flutter/material.dart';

import '../theme.dart';

/// A Cancel/Confirm dialog; true only when confirmed. [destructive] gives the
/// confirm button the red look; [width] fixes the body width; [confirmKey]
/// tags the confirm button for tests.
Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  double? width,
  Key? confirmKey,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : (width == null ? Text(message) : SizedBox(width: width, child: Text(message))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelLabel)),
        FilledButton(
          key: confirmKey,
          style: destructive ? destructiveButtonStyle(context) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Asks for one line of text; the trimmed value, or null when cancelled. While
/// [validator] returns a message the field shows it and confirming is disabled.
/// [description] sits above the field, [mono] sets it in the code font.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String? label,
  String? hint,
  String initial = '',
  String? Function(String text)? validator,
  String confirmLabel = 'OK',
  String? description,
  double width = 380,
  Key? fieldKey,
  bool mono = false,
  TextInputType? keyboardType,
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _TextPrompt(
        title: title,
        label: label,
        hint: hint,
        initial: initial,
        validator: validator,
        confirmLabel: confirmLabel,
        description: description,
        width: width,
        fieldKey: fieldKey,
        mono: mono,
        keyboardType: keyboardType,
      ),
    );

class _TextPrompt extends StatefulWidget {
  final String title, confirmLabel, initial;
  final String? label, hint, description;
  final String? Function(String text)? validator;
  final double width;
  final Key? fieldKey;
  final bool mono;
  final TextInputType? keyboardType;
  const _TextPrompt({
    required this.title,
    required this.label,
    required this.hint,
    required this.initial,
    required this.validator,
    required this.confirmLabel,
    required this.description,
    required this.width,
    required this.fieldKey,
    required this.mono,
    required this.keyboardType,
  });

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _error => widget.validator?.call(_controller.text.trim());

  void _submit() {
    if (_error == null) Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.width,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.description != null) ...[
            Text(widget.description!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
          ],
          TextField(
            key: widget.fieldKey,
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            style: widget.mono ? monoStyle(context) : null,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              isDense: widget.description != null,
              errorText: _controller.text.isEmpty ? null : error,
            ),
            onChanged: widget.validator == null ? null : (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: error == null ? _submit : null, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
