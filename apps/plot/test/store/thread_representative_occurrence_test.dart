import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

ScheduleRow _row({
  required String occurrence,
  required DateTime start,
  required DateTime end,
  DateTime? archivedAt,
}) => ScheduleRow(
  id: Uuid.generate(),
  updatedAt: DateTime(2026, 1, 1),
  threadId: Uuid.generate(),
  occurrence: occurrence,
  startAt: start,
  endAt: end,
  outstandingTasks: false,
  archivedAt: archivedAt,
);

void main() {
  group('selectRepresentativeOccurrence', () {
    final now = DateTime(2026, 4, 17, 12, 0);

    test('returns earliest upcoming when any occurrence ends >= now', () {
      final future1 = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final future2 = _row(
        occurrence: '20260420T120000',
        start: DateTime(2026, 4, 20, 12, 0),
        end: DateTime(2026, 4, 20, 13, 0),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [past, future1, future2],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.row.occurrence, '20260418T120000');
      expect(result.isOverride, false);
    });

    test('returns latest past when no upcoming', () {
      final past1 = _row(
        occurrence: '20260401T120000',
        start: DateTime(2026, 4, 1, 12, 0),
        end: DateTime(2026, 4, 1, 13, 0),
      );
      final past2 = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [past1, past2],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
      expect(result.isOverride, false);
    });

    test('overrides replace generated instances at same occurrence key', () {
      final generated = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final override = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 14, 0),
        end: DateTime(2026, 4, 18, 15, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [generated],
        overrideRows: [override],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result!.row.startAt, DateTime(2026, 4, 18, 14, 0));
      expect(result.isOverride, true);
    });

    test('archived override keys remove matching generated instances', () {
      final futureGen = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [futureGen, past],
        overrideRows: const [],
        archivedOverrideKeys: const {'20260418T120000'},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
      expect(result.isOverride, false);
    });

    test('returns null when no candidates', () {
      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: const [],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result, isNull);
    });

    test('archived override row is treated as a removal (not a candidate)', () {
      final upcomingArchived = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
        archivedAt: DateTime(2026, 4, 17),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: const [],
        overrideRows: [upcomingArchived, past],
        archivedOverrideKeys: const {'20260418T120000'},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
    });
  });
}
