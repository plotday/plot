import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_limits.dart';
import 'package:plot/store/store.dart';

Priority _testPriority({
  String title = 'Test',
  String path = 'test',
  double order = 0,
}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(path),
    order: Order(order),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

List<Thread> _threadsFor(Priority p, int count) =>
    List.generate(count, (_) => Thread(priority: p, title: 'x'));

int _capForTests = kAgendaThreadsPerDayPerPriorityDefault;

void main() {
  group('cascadeActivityFeedByPriority', () {
    final today = Date(2026, 5, 12);
    final tomorrow = today.addDays(1);
    final dayAfter = today.addDays(2);

    test('empty input returns empty output', () {
      final result = cascadeActivityFeedByPriority(
        today: today,
        active: const [],
        scheduledByDate: const {},
      );
      expect(result.active, isEmpty);
      expect(result.scheduledByDate, isEmpty);
    });

    test('under-cap day is unchanged', () {
      final p = _testPriority();
      final threads = _threadsFor(p, 5);
      final result = cascadeActivityFeedByPriority(
        today: today,
        active: threads,
        scheduledByDate: const {},
      );
      expect(result.active.length, 5);
      expect(result.scheduledByDate, isEmpty);
    });

    test('15 threads on today spills 5 onto tomorrow (synthesized)', () {
      final p = _testPriority();
      final threads = _threadsFor(p, 15);
      final result = cascadeActivityFeedByPriority(
        today: today,
        active: threads,
        scheduledByDate: const {},
      );
      expect(result.active.length, _capForTests);
      // One synthesized day with the overflow.
      expect(result.scheduledByDate.length, 1);
      expect(result.scheduledByDate[tomorrow]?.length, 15 - _capForTests);
    });

    test(
      'two priorities are capped independently on the same day',
      () {
        final a = _testPriority(title: 'A', path: 'a');
        final b = _testPriority(title: 'B', path: 'b');
        final aThreads = _threadsFor(a, 12);
        final bThreads = _threadsFor(b, 12);
        final result = cascadeActivityFeedByPriority(
          today: today,
          active: [...aThreads, ...bThreads],
          scheduledByDate: const {},
        );
        // Each priority caps at 10 → today has 10 + 10 = 20.
        expect(result.active.length, 2 * _capForTests);
        final byPriority = <PriorityId, int>{};
        for (final t in result.active) {
          byPriority[t.priority.id] = (byPriority[t.priority.id] ?? 0) + 1;
        }
        expect(byPriority[a.id], _capForTests);
        expect(byPriority[b.id], _capForTests);
        // Tomorrow synthesized with 2 + 2 = 4.
        expect(result.scheduledByDate[tomorrow]?.length, 4);
      },
    );

    test('cascade chains across multiple days', () {
      final p = _testPriority();
      final threads = _threadsFor(p, 25);
      final result = cascadeActivityFeedByPriority(
        today: today,
        active: threads,
        scheduledByDate: const {},
      );
      // 25 -> 10 today, 10 tomorrow, 5 day after.
      expect(result.active.length, 10);
      expect(result.scheduledByDate[tomorrow]?.length, 10);
      expect(result.scheduledByDate[dayAfter]?.length, 5);
    });

    test(
      'spillover merges with native threads on the destination day',
      () {
        final p = _testPriority();
        // Today is over capacity, tomorrow has its own natives.
        final todayThreads = _threadsFor(p, 12);
        final tomorrowNatives = _threadsFor(p, 6);
        final result = cascadeActivityFeedByPriority(
          today: today,
          active: todayThreads,
          scheduledByDate: {tomorrow: tomorrowNatives},
        );
        // Today caps at 10; 2 spill to tomorrow. Tomorrow had 6 → 8 total,
        // still under cap → tomorrow shows 8, no further spill.
        expect(result.active.length, 10);
        expect(result.scheduledByDate[tomorrow]?.length, 8);
        expect(result.scheduledByDate[dayAfter], isNull);
      },
    );

    test(
      'three different priorities, mix of over- and under-cap',
      () {
        final a = _testPriority(title: 'A', path: 'a');
        final b = _testPriority(title: 'B', path: 'b');
        final c = _testPriority(title: 'C', path: 'c');
        final result = cascadeActivityFeedByPriority(
          today: today,
          active: [
            ..._threadsFor(a, 20),
            ..._threadsFor(b, 3),
            ..._threadsFor(c, 11),
          ],
          scheduledByDate: const {},
        );
        // A: 10 today, 10 tomorrow. B: 3 today. C: 10 today, 1 tomorrow.
        expect(result.active.length, 10 + 3 + 10);
        expect(result.scheduledByDate[tomorrow]?.length, 10 + 1);
        // No further cascade — tomorrow per-priority counts: A=10, C=1 — both
        // under cap.
        expect(result.scheduledByDate[dayAfter], isNull);
      },
    );

    test(
      'safety bound dumps residual onto the last day rather than '
      'looping forever',
      () {
        final p = _testPriority();
        // Push far beyond the synthesis horizon: 1 + 14 days × 10 cap =
        // 141 threads still cleanly distribute. To trigger the bound we
        // need overflow to remain after the horizon's worth of days.
        final huge = (1 + kAgendaCascadeSynthesisHorizonDays) *
                kAgendaThreadsPerDayPerPriorityDefault +
            5;
        final threads = _threadsFor(p, huge);
        final result = cascadeActivityFeedByPriority(
          today: today,
          active: threads,
          scheduledByDate: const {},
        );
        // Day count: today (1) + horizon days = 15 sections rendered.
        expect(result.scheduledByDate.length,
            kAgendaCascadeSynthesisHorizonDays);
        // Every day except possibly the last sits at the cap.
        final lastDate = today.addDays(kAgendaCascadeSynthesisHorizonDays);
        expect(result.active.length, _capForTests);
        for (final entry in result.scheduledByDate.entries) {
          if (entry.key == lastDate) {
            // Last day absorbs the cap plus the residual safety dump.
            expect(entry.value.length, greaterThanOrEqualTo(_capForTests));
          } else {
            expect(entry.value.length, _capForTests);
          }
        }
        // Total thread count is preserved end-to-end.
        final total = result.active.length +
            result.scheduledByDate.values
                .fold<int>(0, (acc, list) => acc + list.length);
        expect(total, huge);
      },
    );
  });
}
