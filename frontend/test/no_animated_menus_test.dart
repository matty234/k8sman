import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard: every popup menu in the app must open without Material's
/// grow/fade animation (native macOS menus appear instantly).
void main() {
  test('all showMenu/PopupMenuButton calls disable the popup animation', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r'(showMenu<\w+>\(|PopupMenuButton<\w+>\()').allMatches(src)) {
        // Look within the call's first ~600 chars for the style argument.
        final window = src.substring(m.start, (m.start + 600).clamp(0, src.length));
        if (!window.contains('popUpAnimationStyle: AnimationStyle.noAnimation')) {
          offenders.add('${f.path}:${'\n'.allMatches(src.substring(0, m.start)).length + 1}');
        }
      }
      if (RegExp(r'\bDropdownButton(FormField)?<').hasMatch(src)) offenders.add('${f.path}: uses DropdownButton (use MenuSelect)');
    }
    expect(offenders, isEmpty);
  });
}
