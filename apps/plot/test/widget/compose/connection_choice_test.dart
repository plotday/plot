import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/connection_choice.dart';

void main() {
  group('ConnectionChoice.plotThread', () {
    test('has a stable key', () {
      expect(ConnectionChoice.plotThread.key, 'plot:thread');
    });

    test('displays "Plot thread" as label', () {
      expect(ConnectionChoice.plotThread.label, 'Plot thread');
    });

    test('toUserAction returns null', () {
      expect(ConnectionChoice.plotThread.toUserAction(), isNull);
    });
  });
}
