import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/thread.dart';
import 'package:plot/util/time.dart';

void main() {
  group('SetThreadDuration.computeAt', () {
    final start = DateTime(2026, 5, 10, 9, 0);

    test('positive duration sets at.end to start + duration', () {
      final at = DateTimeRange(start, start.add(const Duration(minutes: 30)));
      final result = SetThreadDuration.computeAt(at, const Duration(hours: 1));
      expect(result, isNotNull);
      expect(result!.start, start);
      expect(result.end, start.add(const Duration(hours: 1)));
      expect(result.duration, const Duration(hours: 1));
    });

    test('positive duration on a start-only at sets the end', () {
      final at = DateTimeRange(start, null);
      final result =
          SetThreadDuration.computeAt(at, const Duration(minutes: 45));
      expect(result, isNotNull);
      expect(result!.start, start);
      expect(result.end, start.add(const Duration(minutes: 45)));
    });

    test('null duration clears at.end while preserving at.start', () {
      final at = DateTimeRange(start, start.add(const Duration(hours: 2)));
      final result = SetThreadDuration.computeAt(at, null);
      expect(result, isNotNull);
      expect(result!.start, start);
      expect(result.end, isNull);
      expect(result.duration, isNull);
    });

    test('returns null when at is null', () {
      expect(SetThreadDuration.computeAt(null, const Duration(hours: 1)),
          isNull);
      expect(SetThreadDuration.computeAt(null, null), isNull);
    });

    test('returns null when at has no start', () {
      final at = DateTimeRange(null, start);
      expect(SetThreadDuration.computeAt(at, const Duration(hours: 1)), isNull);
    });
  });
}
