import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Regression guard: `SchedulesBase.processPulledRows` intentionally drops a
/// pulled row when the local copy still has an in-flight `pending` edit, to
/// avoid clobbering the user's unsent change. Its comment claims "the next
/// pull after push completes will pick up the server's authoritative state"
/// — but `Store.pull()` advances the seq cursor (`syncStates.lastHorizon`)
/// from the raw server batch, not from the rows actually written. Once the
/// cursor passes the dropped row's seq, the server never re-sends it (it
/// only emits rows with `seq >= last_horizon`), so the update is lost
/// forever, not just deferred to "the next pull". This reproduces a
/// rescheduled calendar event getting permanently stuck at its old time on
/// a client that had an in-flight local edit racing the server's update.
void main() {
  test(
    'pull() does not advance the cursor past a row dropped for a pending local edit',
    () async {
      final raw = sqlite3.openInMemory();
      final store = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(() async {
        await store.close();
        raw.close();
      });

      final schedId = Uuid.generate();
      final oldStart = DateTime.utc(2026, 7, 1, 12);
      final newStart = DateTime.utc(2026, 7, 13, 17, 30);

      // Local row has an in-flight edit (pending != null).
      await store.into(store.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              startAt: Value(oldStart),
              pending: const Value(2),
            ),
          );

      final fakeTable = _FakeSchedulesBase(
        rows: [
          {
            'id': schedId.toString(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'at':
                '[${newStart.toIso8601String()},${newStart.add(const Duration(minutes: 45)).toIso8601String()})',
          },
        ],
        nextHorizon: '100',
      );

      await store.pull(store.schedules, fakeTable);

      // The dropped row must not have overwritten the local pending edit.
      // (startAt is stored/converted as local time, so compare instants.)
      final local = await (store.select(store.schedules)
            ..where((s) => s.id.equals(schedId.toBytes())))
          .getSingle();
      expect(local.startAt!.isAtSameMomentAs(oldStart), isTrue);

      // The cursor must NOT advance past the dropped row — otherwise the
      // server, which only re-emits seq >= last_horizon, will never resend
      // this update once the local pending edit clears.
      final syncState = await (store.select(store.syncStates)
            ..where((r) => r.entity.equals('schedules')))
          .getSingleOrNull();
      expect(
        syncState?.lastHorizon,
        isNot(100),
        reason:
            'cursor advanced past a row processPulledRows dropped for a '
            'pending local edit — that update is now permanently lost',
      );
    },
  );

  test(
    'pullTo() does not advance its boundary past a row dropped for a pending local edit',
    () async {
      // pullTo() is the agenda/feed pagination path (Thread.pullAgenda etc.)
      // — same drop mechanism, separate cursor-advance code path.
      final raw = sqlite3.openInMemory();
      final store = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(() async {
        await store.close();
        raw.close();
      });

      final schedId = Uuid.generate();
      final oldStart = DateTime.utc(2026, 7, 1, 12);
      final newStart = DateTime.utc(2026, 7, 13, 17, 30);

      await store.into(store.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              startAt: Value(oldStart),
              updatedAt: Value(oldStart),
              pending: const Value(2),
            ),
          );

      final fakeTable = _FakeSchedulesBase(
        rows: [
          {
            'id': schedId.toString(),
            'updated_at': newStart.toIso8601String(),
            'at':
                '[${newStart.toIso8601String()},${newStart.add(const Duration(minutes: 45)).toIso8601String()})',
          },
        ],
        nextHorizon: null,
        lastUpdated: newStart,
      );

      await store.pullTo(store.schedules, fakeTable, pullTo: newStart);

      final local = await (store.select(store.schedules)
            ..where((s) => s.id.equals(schedId.toBytes())))
          .getSingle();
      expect(local.startAt!.isAtSameMomentAs(oldStart), isTrue);

      final syncState = await (store.select(store.syncStates)
            ..where((r) => r.entity.equals(fakeTable.fullName)))
          .getSingleOrNull();
      expect(
        syncState?.last,
        isNull,
        reason:
            'pullTo boundary advanced past a row processPulledRows dropped '
            'for a pending local edit — that update is now permanently lost',
      );
    },
  );
}

class _FakeSchedulesBase extends SchedulesBase {
  _FakeSchedulesBase({
    required this.rows,
    required this.nextHorizon,
    this.lastUpdated,
  });

  final List<Map<String, dynamic>> rows;
  final String? nextHorizon;
  final DateTime? lastUpdated;

  @override
  Future<
    (
      Iterable<Map<String, dynamic>> rows,
      DateTime? lastUpdated,
      String? lastId,
      DateTimeRange? range,
      bool more,
      String? nextHorizon,
      ({String seq, String id})? nextPage,
    )
  >
  get({
    DateTimeRange? range,
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
    Map<String, dynamic>? prefetched,
    Map<String, String>? extraParams,
  }) async {
    return (rows, lastUpdated, null, null, false, nextHorizon, null);
  }
}
