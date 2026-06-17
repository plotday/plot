import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';

void main() {
  test('single role: no prefix', () {
    expect(focusLabelFor('Marketing', 'AFC Marlow', 1), 'Marketing');
  });
  test('null role: no prefix', () {
    expect(focusLabelFor('Marketing', null, 3), 'Marketing');
  });
  test('2+ roles: Role › Focus', () {
    expect(focusLabelFor('Marketing', 'AFC Marlow', 2),
        'AFC Marlow › Marketing');
  });
}
