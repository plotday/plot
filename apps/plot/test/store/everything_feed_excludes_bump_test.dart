import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// The flat "Everything" / search feed ([Thread.watchAllTabHead]) sorts by
/// real content recency only — note / link source times and a past event's
/// end — and must IGNORE the manual `bumped_at` reposition. Unlike a focus's
/// Done section (which excludes unread), the flat feed shows unread threads
/// inline, so letting `bumped_at` lift a row would yank an already-visible
/// thread to the top when it is read or completed. (The sectioned Done feed
/// still honors `bumped_at`.)
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
    required DateTime createdAt,
    DateTime? bumpedAt,
  }) async {
    final id = Uuid.generate();
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(priorityId),
            contacts: Value([Uuid.generate()]),
            draft: const Value(false),
            unread: const Value(false),
            importance: const Value(0),
            createdAt: Value(createdAt),
            bumpedAt: Value(bumpedAt),
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

  test('a bumped older thread does not float above a newer-content thread',
      () async {
    await seedSelf();
    await insertPriority();

    // Newer real content, never bumped.
    final newerContent = await insertThread(createdAt: DateTime(2026, 5, 1));
    // Older content, but bumped to "now" (e.g. just completed). It must NOT
    // jump to the top of Everything.
    final olderBumped = await insertThread(
      createdAt: DateTime(2026, 1, 1),
      bumpedAt: DateTime(2026, 6, 1),
    );

    final order = await feedOrder();

    expect(
      order.indexOf(newerContent),
      lessThan(order.indexOf(olderBumped)),
      reason: 'Everything sorts by content recency only; bumped_at must not '
          'lift an older thread above newer content',
    );
  });
}
