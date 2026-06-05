import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/priorities_shell.dart';

void main() {
  group('navSlotsFor', () {
    test('includes the agenda slot when a calendar is connected', () {
      expect(navSlotsFor(hasCalendar: true), const [
        NavSlot.focuses,
        NavSlot.agenda,
        NavSlot.newThread,
        NavSlot.search,
        NavSlot.more,
      ]);
    });

    test('drops the agenda slot when no calendar is connected', () {
      expect(navSlotsFor(hasCalendar: false), const [
        NavSlot.focuses,
        NavSlot.newThread,
        NavSlot.search,
        NavSlot.more,
      ]);
    });
  });
}
