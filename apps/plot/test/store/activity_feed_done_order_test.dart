import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Integration tests for the unified ("Everything") activity feed's load
/// order ([Thread.watchAllTabHead] → `_watchAllTabIds`) against an in-memory
/// database.
///
/// Invariant under test: the flat feed (Everything / search / filter / icon)
/// loads and sorts purely by recency (`activity_at`), exactly like the Done
/// section of sectioned feeds. Read state and importance do NOT lift a thread
/// above a more recently-active one. (The unread cluster's importance/urgent
/// ordering lives in the sectioned feeds' `watchUnreadHead`, not here.)
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
  });

  tearDown(() async {
    Actor.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  final priorityId = Uuid.generate();

  // Seed a `self` actor and prime the Actor cache so the thread hydration's
  // active-thread query resolves the current user locally (otherwise it
  // reaches into the unregistered [Base] singleton and throws).
  Future<void> seedSelf() async {
    await store.into(store.actors).insert(
          ActorsCompanion(
            id: Value(ActorId(Uuid.generate())),
            type: const Value(ActorType.contact),
            name: const Value('Me'),
            email: const Value('me@x.test'),
            self: const Value(true),
            inviteable: const Value(true),
            primary: const Value(true),
          ),
        );
    await Actor.get(self: true);
  }

  Future<void> insertPriority() async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(priorityId),
            title: const Value('Social'),
            createdBy: Value(Uuid.generate()),
            path: Value(Path('social')),
            order: const Value(Order(0)),
            root: const Value(true),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  Future<Uuid> insertThread({
    required bool unread,
    required int importance,
    required DateTime createdAt,
  }) async {
    final id = Uuid.generate();
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(priorityId),
            contacts: Value([Uuid.generate()]),
            draft: const Value(false),
            unread: Value(unread),
            importance: Value(importance),
            // activity_at = MAX(..., createdAt, ...), so createdAt drives the
            // recency key when there are no notes/links.
            createdAt: Value(createdAt),
          ),
        );
    return id;
  }

  Future<List<Uuid>> feedOrder() async {
    final result = await Thread.watchAllTabHead(
      priorityId: priorityId,
      limit: 50,
    ).first;
    return result.threads.map((t) => t.id).toList();
  }

  test('flat feed loads by recency, not importance', () async {
    await seedSelf();
    await insertPriority();

    // Older but high-importance; a normal triaged email.
    final oldImportant = await insertThread(
      unread: false,
      importance: 50,
      createdAt: DateTime(2026, 1, 1),
    );
    // Newer but importance 0; mirrors a freshly self-authored thread that
    // never got an importance score.
    final newUnscored = await insertThread(
      unread: false,
      importance: 0,
      createdAt: DateTime(2026, 5, 1),
    );

    final order = await feedOrder();

    final iNew = order.indexOf(newUnscored);
    final iOld = order.indexOf(oldImportant);
    expect(iNew, isNonNegative, reason: 'newer read thread must load');
    expect(iOld, isNonNegative, reason: 'older read thread must load');
    expect(
      iNew,
      lessThan(iOld),
      reason: 'the newer thread must sort above the older one regardless of '
          'importance',
    );
  });

  test('an older unread thread does not float above a newer read thread',
      () async {
    await seedSelf();
    await insertPriority();

    // Newer, but already read.
    final newRead = await insertThread(
      unread: false,
      importance: 0,
      createdAt: DateTime(2026, 5, 30),
    );
    // Older, still unread and high-importance — under the old unread-first
    // ordering this would wrongly sort to the top of Everything.
    final oldUnread = await insertThread(
      unread: true,
      importance: 75,
      createdAt: DateTime(2026, 5, 25),
    );

    final order = await feedOrder();

    expect(
      order.indexOf(newRead),
      lessThan(order.indexOf(oldUnread)),
      reason: 'Everything sorts purely by activity_at: the more recently '
          'active thread leads, even if older threads are unread/important',
    );
  });

  test('unread threads order by recency, not importance', () async {
    await seedSelf();
    await insertPriority();

    // Newer but low importance.
    final newLow = await insertThread(
      unread: true,
      importance: 10,
      createdAt: DateTime(2026, 5, 2),
    );
    // Older but high importance.
    final oldHigh = await insertThread(
      unread: true,
      importance: 90,
      createdAt: DateTime(2026, 5, 1),
    );

    final order = await feedOrder();

    expect(
      order.indexOf(newLow),
      lessThan(order.indexOf(oldHigh)),
      reason: 'in the flat feed, recency wins over importance even among '
          'unread threads',
    );
  });
}
