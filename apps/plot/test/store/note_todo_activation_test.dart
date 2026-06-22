import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Marking a note as the current user's task (Tag.todo) activates its thread
/// via [Note.ensureTodoForUser]. A newly-activated to-do must append at the
/// BOTTOM of the Active section (above the inactive-unread cluster), exactly
/// like the thread-level "To do" toggle. Bottom placement uses [Order.last] —
/// a positive timestamp — so a positive `state_order` is a deterministic proxy
/// for "appended at the bottom"; [Order.first] (negative) is the TOP-placement
/// bug this guards against.
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
    Order? stateOrder,
    DateTime? readAt,
  }) async {
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(Uuid.generate()),
            active: Value(active),
            importance: const Value(0),
            stateOrder:
                stateOrder == null ? const Value.absent() : Value(stateOrder),
            readAt: Value(readAt),
            statePending: const Value(false),
          ),
        );
  }

  Future<ThreadRow> readRow(Uuid id) =>
      (store.select(store.threads)..where((t) => t.id.equalsValue(id)))
          .getSingle();

  test('activating a note-todo appends the thread at the BOTTOM of Active',
      () async {
    final id = Uuid.generate();
    // A freshly published thread: inactive, read, no per-user order yet.
    await insertThread(id, active: false, readAt: DateTime(2026, 1, 1));

    Map<String, dynamic>? pushed;
    await Note.ensureTodoForUser(
      id,
      post: (url, {body = const <String, dynamic>{}}) async {
        pushed = body as Map<String, dynamic>;
        return {'ok': true};
      },
    );

    final row = await readRow(id);
    expect(row.active, isTrue, reason: 'the thread becomes a to-do');
    expect(row.stateOrder, isNotNull);
    expect(row.stateOrder!.value, greaterThan(0),
        reason: 'Order.last() (positive) => bottom of Active, not the top');
    expect(row.statePending, isTrue,
        reason: 'the order must be durably pushed, not just optimistic');
    expect((pushed?['order'] as num?), isNotNull,
        reason: 'the push must carry the order so the server persists it — '
            'otherwise state_order stays NULL and the row snaps to the top');
    expect((pushed!['order'] as num).toDouble(), row.stateOrder!.value);
  });

  test('activating a note-todo preserves an explicitly-set order', () async {
    final id = Uuid.generate();
    await insertThread(id,
        active: false, stateOrder: const Order(-5), readAt: DateTime(2026, 1, 1));

    await Note.ensureTodoForUser(
      id,
      post: (url, {body = const <String, dynamic>{}}) async => {'ok': true},
    );

    final row = await readRow(id);
    expect(row.active, isTrue);
    expect(row.stateOrder!.value, -5,
        reason: 'an existing drag position is honored, not overwritten');
  });

  test('already-active unread thread is left untouched (no re-append)',
      () async {
    final id = Uuid.generate();
    await insertThread(id, active: true, stateOrder: const Order(123));

    var posted = false;
    await Note.ensureTodoForUser(
      id,
      post: (url, {body = const <String, dynamic>{}}) async {
        posted = true;
        return {'ok': true};
      },
    );

    final row = await readRow(id);
    expect(row.stateOrder!.value, 123, reason: 'position is preserved');
    expect(posted, isFalse, reason: 'guard short-circuits, no spurious push');
  });
}
