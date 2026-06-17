import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';
import 'package:plot/widget_bridge/widget_data.dart';

void main() {
  test('widgetEventFrom(null) is null', () {
    expect(widgetEventFrom(null, hasCall: false), isNull);
  });

  test('todoRowsFrom maps id+title and caps at 5', () {
    final rows = todoRowsFrom([
      for (var i = 0; i < 8; i++) (id: 't$i', title: 'Task $i'),
    ]);
    expect(rows.length, 5);
    expect(rows.first, const WidgetTodo(threadId: 't0', title: 'Task 0'));
  });
}
