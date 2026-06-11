import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// [Session.revivableActiveFor] backs auto-start's idempotency: it returns the
/// most-recent non-archived `active` session for a priority whose *planned
/// pomodoro window* still covers `now`, even after the short `end` lookahead
/// has lapsed. Auto-start revives that session instead of spawning a duplicate
/// — the fix for focus-session spam.
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
    Time.unfreeze();
  });

  final priorityA = Uuid.generate();
  final priorityB = Uuid.generate();

  Future<void> insertSession({
    required Uuid priorityId,
    required DateTime start,
    required DateTime end,
    required DateTime pomodoroAt,
    required Duration pomodoro,
    String source = 'active',
    bool explicit = true,
    DateTime? archivedAt,
  }) async {
    await store.into(store.sessions).insert(
          SessionsCompanion.insert(
            id: Value(Uuid.generate()),
            start: start,
            end: end,
            priorityId: Value(priorityId),
            pomodoroAt: Value(pomodoroAt),
            pomodoro: Value(pomodoro),
            source: Value(source),
            explicit: Value(explicit),
            archivedAt: Value(archivedAt),
          ),
        );
  }

  test('returns a session whose planned window covers now even though its '
      'end lookahead has lapsed', () async {
    final now = DateTime(2026, 5, 1, 8, 30);
    Time.setFrozenTime(now);
    // Started 8:22 with a 53-minute pomodoro → window [8:22, 9:15]. Its `end`
    // lookahead (8:25) is already in the past relative to `now` (8:30).
    await insertSession(
      priorityId: priorityA,
      start: DateTime(2026, 5, 1, 8, 22),
      end: DateTime(2026, 5, 1, 8, 25),
      pomodoroAt: DateTime(2026, 5, 1, 8, 22),
      pomodoro: const Duration(minutes: 53),
    );

    final found = await Session.revivableActiveFor(priorityA, now);
    expect(found, isNotNull);
    expect(found!.pomodoroAt, DateTime(2026, 5, 1, 8, 22));
  });

  test('returns null when the planned window has fully elapsed', () async {
    final now = DateTime(2026, 5, 1, 9, 30);
    Time.setFrozenTime(now);
    // Window [8:22, 9:15] — fully elapsed at 9:30.
    await insertSession(
      priorityId: priorityA,
      start: DateTime(2026, 5, 1, 8, 22),
      end: DateTime(2026, 5, 1, 8, 25),
      pomodoroAt: DateTime(2026, 5, 1, 8, 22),
      pomodoro: const Duration(minutes: 53),
    );

    expect(await Session.revivableActiveFor(priorityA, now), isNull);
  });

  test('ignores sessions for a different priority', () async {
    final now = DateTime(2026, 5, 1, 8, 30);
    Time.setFrozenTime(now);
    await insertSession(
      priorityId: priorityB,
      start: DateTime(2026, 5, 1, 8, 22),
      end: DateTime(2026, 5, 1, 8, 25),
      pomodoroAt: DateTime(2026, 5, 1, 8, 22),
      pomodoro: const Duration(minutes: 53),
    );

    expect(await Session.revivableActiveFor(priorityA, now), isNull);
  });

  test('ignores archived sessions', () async {
    final now = DateTime(2026, 5, 1, 8, 30);
    Time.setFrozenTime(now);
    await insertSession(
      priorityId: priorityA,
      start: DateTime(2026, 5, 1, 8, 22),
      end: DateTime(2026, 5, 1, 8, 25),
      pomodoroAt: DateTime(2026, 5, 1, 8, 22),
      pomodoro: const Duration(minutes: 53),
      archivedAt: DateTime(2026, 5, 1, 8, 26),
    );

    expect(await Session.revivableActiveFor(priorityA, now), isNull);
  });

  test('when several rows cover now, returns the most recent by start',
      () async {
    final now = DateTime(2026, 5, 1, 8, 40);
    Time.setFrozenTime(now);
    await insertSession(
      priorityId: priorityA,
      start: DateTime(2026, 5, 1, 8, 22),
      end: DateTime(2026, 5, 1, 8, 25),
      pomodoroAt: DateTime(2026, 5, 1, 8, 22),
      pomodoro: const Duration(minutes: 53),
    );
    await insertSession(
      priorityId: priorityA,
      start: DateTime(2026, 5, 1, 8, 35),
      end: DateTime(2026, 5, 1, 8, 38),
      pomodoroAt: DateTime(2026, 5, 1, 8, 35),
      pomodoro: const Duration(minutes: 40),
    );

    final found = await Session.revivableActiveFor(priorityA, now);
    expect(found!.pomodoroAt, DateTime(2026, 5, 1, 8, 35));
  });
}
