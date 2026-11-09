import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/widgets/picker_kit.dart';

void main() {
  test('PickerKeys clamps moves to the list and ignores an empty one', () {
    int? got;
    KeyEventResult press(LogicalKeyboardKey k, int count, int active) {
      got = null;
      return PickerKeys.handle(
        KeyDownEvent(physicalKey: PhysicalKeyboardKey.abort, logicalKey: k, timeStamp: Duration.zero),
        count: count,
        active: active,
        page: 10,
        onActive: (i) => got = i,
        onEnter: () {},
        onEscape: () {},
      );
    }

    expect(press(LogicalKeyboardKey.pageDown, 5, 2), KeyEventResult.handled);
    expect(got, 4);
    press(LogicalKeyboardKey.arrowUp, 5, 0);
    expect(got, 0);
    press(LogicalKeyboardKey.arrowDown, 0, 0);
    expect(got, isNull);
    expect(press(LogicalKeyboardKey.keyA, 5, 0), KeyEventResult.ignored);
  });
}
