import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/schedule_range.dart';

void main() {
  // A fixed reference time well in the past so clamp's not-past rule is testable.
  final base = DateTime(2026, 5, 28, 9, 0);
  DateTimeRange r({int durationMin = 30}) =>
      DateTimeRange(base, base.add(Duration(minutes: durationMin)));

  group('withDuration', () {
    test('moves end, keeps start', () {
      final out = withDuration(r(), const Duration(minutes: 90));
      expect(out.start, base);
      expect(out.end, base.add(const Duration(minutes: 90)));
    });
  });

  group('withStart', () {
    test('keeps duration, moves both ends', () {
      final out = withStart(r(durationMin: 60), const FTime(10, 0));
      expect(out.start, DateTime(2026, 5, 28, 10, 0));
      expect(out.end, DateTime(2026, 5, 28, 11, 0));
    });
  });

  group('withEnd', () {
    test('recomputes duration from new end', () {
      final out = withEnd(r(), const FTime(9, 45));
      expect(out.end, DateTime(2026, 5, 28, 9, 45));
      expect(out.duration, const Duration(minutes: 45));
    });
    test('end before start rolls to next day', () {
      final out = withEnd(r(), const FTime(8, 0));
      expect(out.end, DateTime(2026, 5, 29, 8, 0));
    });
  });

  group('withDate', () {
    test('keeps time-of-day and duration on the new date', () {
      final out = withDate(r(durationMin: 45), DateTime(2026, 6, 1));
      expect(out.start, DateTime(2026, 6, 1, 9, 0));
      expect(out.end, DateTime(2026, 6, 1, 9, 45));
    });
  });

  group('shiftedBy', () {
    test('shifts both ends, preserving duration', () {
      final out = shiftedBy(r(durationMin: 30), const Duration(minutes: 15));
      expect(out.start, base.add(const Duration(minutes: 15)));
      expect(out.end, base.add(const Duration(minutes: 45)));
    });
  });

  group('clampScheduleRange', () {
    test('enforces 15-min minimum duration', () {
      final tiny = DateTimeRange(base, base.add(const Duration(minutes: 5)));
      final out = clampScheduleRange(tiny, allowPast: true, now: base);
      expect(out.duration, const Duration(minutes: 15));
    });
    test('when allowPast is false, slides a past range forward keeping duration', () {
      final now = base.add(const Duration(hours: 1)); // 10:00, after start
      final out = clampScheduleRange(r(durationMin: 30), allowPast: false, now: now);
      expect(out.start, now);
      expect(out.duration, const Duration(minutes: 30));
    });
    test('when allowPast is true, leaves a past range alone', () {
      final now = base.add(const Duration(hours: 1));
      final out = clampScheduleRange(r(durationMin: 30), allowPast: true, now: now);
      expect(out.start, base);
    });
  });
}
