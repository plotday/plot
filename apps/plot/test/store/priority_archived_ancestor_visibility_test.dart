import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Locks in the fix for live focuses being hidden by a path-derived
/// "archived ancestor" filter.
///
/// In the flat/role model a focus must NEVER be hidden because of where its
/// old ltree path sat. The previous `archived: false` query left-joined the
/// path-walking `priority_ancestry` view and dropped any focus with
/// `has_archived_ancestor = 1` — so archiving an old container focus silently
/// hid every live, correctly-roled focus still nested under it by path (seen
/// in prod for kris@plot.day). Visibility now depends only on the focus's own
/// `archived_at`.
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

  Future<void> insertPriority({
    required String path,
    bool archived = false,
    bool isInbox = false,
    String title = 'Focus',
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(Uuid.generate()),
            title: Value(title),
            createdBy: Value(Uuid.generate()),
            path: Value(Path(path)),
            order: const Value(Order(0)),
            isInbox: Value(isInbox),
            roleId: Value(Uuid.generate()),
            unread: const Value(false),
            role: const Value('member'),
            archivedAt:
                archived ? Value(DateTime(2026, 1, 2)) : const Value.absent(),
          ),
        );
  }

  test(
    'a live focus nested under an archived focus stays visible',
    () async {
      // The Inbox root, an archived old container, and a live focus still
      // sitting under that container by its old path.
      await insertPriority(path: 'inbox', isInbox: true, title: 'Inbox');
      await insertPriority(
        path: 'inbox.plot',
        archived: true,
        title: 'Plot (old container)',
      );
      await insertPriority(path: 'inbox.plot.product', title: 'Product');

      // getRaw exercises the same `_get(archived: false)` query (the bug's
      // location) without the signed-in status enrichment a unit test lacks.
      final active = await Priority.getRaw(archived: false);
      final titles = active.map((p) => p.title).toSet();

      expect(
        titles,
        contains('Product'),
        reason: 'a live focus must not be hidden by an archived path ancestor',
      );
      expect(
        titles,
        isNot(contains('Plot (old container)')),
        reason: 'the archived focus itself is still correctly excluded',
      );
    },
  );
}
