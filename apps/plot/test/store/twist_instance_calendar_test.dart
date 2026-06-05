import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('TwistInstance.linkTypesIncludeSchedules', () {
    test('false for null', () {
      expect(TwistInstance.linkTypesIncludeSchedules(null), isFalse);
    });

    test('false when no link type includes schedules', () {
      expect(
        TwistInstance.linkTypesIncludeSchedules(const [
          LinkTypeConfig(type: 'message', label: 'Message'),
          LinkTypeConfig(type: 'issue', label: 'Issue'),
        ]),
        isFalse,
      );
    });

    test('true when a link type includes schedules', () {
      expect(
        TwistInstance.linkTypesIncludeSchedules(const [
          LinkTypeConfig(type: 'message', label: 'Message'),
          LinkTypeConfig(
            type: 'event',
            label: 'Event',
            includesSchedules: true,
          ),
        ]),
        isTrue,
      );
    });
  });
}
