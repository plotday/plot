import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('reordering an active thread marks state_pending so it pushes',
      () async {
    // The feed drag-to-position path routes through reorderTo →
    // _withThreadState → save(). The new state_order is persisted, but the
    // durable /sync/thread-state drain only sends rows WHERE state_pending =
    // true. If the reorder doesn't set that marker, the new order strands on
    // the originating device and never reaches the server — other devices
    // keep the old order forever. (Live-confirmed: a Doing reorder produced
    // state_order=<new> but state_pending=0 and never synced.)
    final thread = Thread(
      priority: _priority(),
      active: true,
      stateOn: Date(2026, 1, 1),
      stateOrder: Order.first(),
    );
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(thread.id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(0),
          statePending: const Value(false),
        ));

    await thread.reorderTo(Order.last(), date: Date(2026, 1, 2)).save();

    final row = await readRow(thread.id);
    expect(row.statePending, isTrue,
        reason: 'a reorder must set the durable /sync/thread-state marker; '
            'otherwise the new order never reaches the server');
  });

  test('a racing pull preserves an unpushed reorder (state_order + marker)',
      () async {
    // A broadcast can land a /sync/threads pull between a local reorder and
    // its /sync/thread-state push. The pull must NOT overwrite the unpushed
    // state_order with the server's older value or clear the push marker —
    // otherwise the reorder is lost and never reaches the server. Guards the
    // dirty-state preservation path for the reorder field specifically.
    final id = Uuid.generate();
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(0),
          stateOrder: const Value(Order(123)),
          statePending: const Value(true),
          updatedAt: Value(DateTime(2026, 1, 3, 10)),
        ));

    // Server snapshot still has the pre-reorder order.
    final serverRow = ThreadRow(
      id: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3, 11),
      priorityId: Uuid.generate(),
      draft: false,
      title: 'server title',
      unread: false,
      importance: 0,
      active: true,
      stateOrder: const Order(999),
      hasEmbedding: false,
      revoked: false,
      statePending: false,
    );

    final merged = await ThreadsBase().processPulledRows(store, [serverRow]);
    final row = merged.single as ThreadRow;

    expect(row.stateOrder?.value, 123,
        reason: 'the unpushed local reorder must survive the racing pull');
    expect(row.statePending, isTrue,
        reason: 'the push marker must survive so the reorder still syncs');
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

  test('a pull heals a stranded active read the server lost (re-pushes)',
      () async {
    // Stranded state: an active thread we read locally (read_at set) that was
    // already pushed once (state_pending = false), then the server lost the
    // read (a connector re-sync clobber nulled thread_state.read_at). The
    // /sync/thread-read drain excludes active threads and /sync/thread-state
    // only sends state_pending rows, so the read can never re-reach the
    // server — it strands and other devices stay unread. When a pull confirms
    // the server is unread AND there's no newer content than our read, re-
    // assert it: keep read locally and set state_pending so the durable drain
    // re-pushes. Self-terminating — once the server accepts it (unread =
    // false), this no longer fires.
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 3, 10);
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(0),
          readAt: Value(readAt),
          statePending: const Value(false),
          updatedAt: Value(DateTime(2026, 1, 3, 10)),
        ));

    // Server: unread (read_at clobbered), no content newer than our read
    // (latest content = createdAt Jan 1 < readAt Jan 3).
    final serverRow = ThreadRow(
      id: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3, 11),
      priorityId: Uuid.generate(),
      draft: false,
      title: 'server title',
      unread: true,
      importance: 0,
      active: true,
      hasEmbedding: false,
      revoked: false,
      statePending: false,
    );

    final merged = await ThreadsBase().processPulledRows(store, [serverRow]);
    final row = merged.single as ThreadRow;

    expect(row.readAt, readAt, reason: 'the remembered read survives');
    expect(row.unread, isFalse,
        reason: 'no newer content → the thread is still read');
    expect(row.statePending, isTrue,
        reason: 're-assert the marker so the durable drain re-pushes the read '
            'and other devices catch up');
  });

  test('a pull does NOT heal an active read when newer content arrived',
      () async {
    // Same stranded shape, but the server has content NEWER than our read —
    // the thread is legitimately unread now, so the heal must NOT fire (no
    // spurious "mark read", no re-push).
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 3, 10);
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(0),
          readAt: Value(readAt),
          statePending: const Value(false),
          updatedAt: Value(DateTime(2026, 1, 3, 10)),
        ));

    final serverRow = ThreadRow(
      id: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 4, 11),
      priorityId: Uuid.generate(),
      draft: false,
      title: 'server title',
      unread: true,
      importance: 0,
      active: true,
      // Newer than readAt → genuinely new content since we read.
      lastNoteSourceCreatedAt: DateTime(2026, 1, 4, 9),
      hasEmbedding: false,
      revoked: false,
      statePending: false,
    );

    final merged = await ThreadsBase().processPulledRows(store, [serverRow]);
    final row = merged.single as ThreadRow;

    expect(row.unread, isTrue,
        reason: 'newer content → the thread is legitimately unread');
    expect(row.statePending, isFalse,
        reason: 'must not re-push a thread that is genuinely unread');
  });
}
