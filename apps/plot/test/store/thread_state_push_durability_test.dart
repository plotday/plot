import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/store/store.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<void> insertThread(
    Uuid id, {
    bool active = false,
    bool statePending = true,
    DateTime? readAt,
    DateTime? updatedAt,
  }) async {
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(Uuid.generate()),
            active: Value(active),
            importance: const Value(0),
            readAt: Value(readAt),
            statePending: Value(statePending),
            updatedAt:
                updatedAt == null ? const Value.absent() : Value(updatedAt),
          ),
        );
  }

  Future<ThreadRow> readRow(Uuid id) =>
      (store.select(store.threads)..where((t) => t.id.equalsValue(id)))
          .getSingle();

  ApiException api(int status) => ApiException(
        statusCode: status,
        endpoint: '/sync/thread-state',
        title: 't',
        description: 'd',
      );

  test('transient failure keeps the row dirty, then a retry clears it',
      () async {
    final id = Uuid.generate();
    await insertThread(id);

    // 503 is not a permanent status → transient → rethrow, keep the marker.
    await expectLater(
      Thread.pushPendingThreadState(
        post: (url, {body = const <String, dynamic>{}}) async => throw api(503),
      ),
      throwsA(isA<ApiException>()),
    );
    expect((await readRow(id)).statePending, isTrue,
        reason: 'a transient failure must not drop the change');

    // Next cycle succeeds → marker cleared.
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => {'ok': true},
    );
    expect((await readRow(id)).statePending, isFalse);
  });

  test(
      'a successful push clears the marker without clearing an active '
      "thread's read_at", () async {
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 2, 9);
    await insertThread(id, active: true, readAt: readAt);

    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => {'ok': true},
    );

    final row = await readRow(id);
    expect(row.statePending, isFalse);
    expect(row.readAt, readAt,
        reason: 'an active thread keeps read_at as its Doing "finished" marker');
  });

  test('a permanent rejection clears the marker and reports', () async {
    final id = Uuid.generate();
    await insertThread(id);

    var reported = 0;
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => throw api(422),
      report: (error, stack, count) => reported += count,
    );

    expect((await readRow(id)).statePending, isFalse,
        reason: 'a permanent rejection will never succeed — stop retrying');
    expect(reported, 1, reason: 'permanent rejections must be reported');
  });

  test('an edit during the in-flight POST is not lost (updated_at guard)',
      () async {
    final id = Uuid.generate();
    final t0 = DateTime(2026, 1, 1, 8);
    await insertThread(id, updatedAt: t0);

    // The poster mutates the row mid-flight (a concurrent local edit bumps
    // updated_at and re-sets the marker) before returning success.
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async {
        await (store.update(store.threads)..where((t) => t.id.equalsValue(id)))
            .write(ThreadsCompanion(
          updatedAt: Value(t0.add(const Duration(minutes: 1))),
          statePending: const Value(true),
        ));
        return {'ok': true};
      },
    );

    expect((await readRow(id)).statePending, isTrue,
        reason: 'the newer edit (different updated_at) must survive to re-push');
  });

  test('a racing pull preserves unpushed per-user state while dirty', () async {
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 3, 10);
    // Local: an unpushed "active + importance 80 + read" edit.
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(80),
          readAt: Value(readAt),
          statePending: const Value(true),
          updatedAt: Value(DateTime(2026, 1, 3, 10)),
        ));

    // Server snapshot (pre-edit): inactive, importance 0, no read.
    final serverRow = ThreadRow(
      id: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3, 11),
      priorityId: Uuid.generate(),
      draft: false,
      title: 'server title',
      unread: true,
      importance: 0,
      active: false,
      hasEmbedding: false,
      revoked: false,
      statePending: false,
    );

    final merged = await ThreadsBase().processPulledRows(store, [serverRow]);

    expect(merged, hasLength(1));
    final row = merged.single as ThreadRow;
    expect(row.active, isTrue, reason: 'unpushed active survives the pull');
    expect(row.importance, 80, reason: 'unpushed importance survives');
    expect(row.readAt, readAt, reason: 'unpushed read survives');
    expect(row.statePending, isTrue, reason: 'still needs to push');
    expect(row.title, 'server title',
        reason: 'server-authoritative content fields still update');
  });
}
