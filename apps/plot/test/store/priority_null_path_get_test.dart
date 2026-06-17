import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Locks in the path-independence fix for [Priority._get]: a focus created
/// locally has `path == null` until the server sync synthesizes one. The
/// priority-tree query joins on `p.path LIKE base.path || '%'`, which is NULL
/// (zero rows) when `base.path` is null — so `getOne(id)` used to throw
/// "Priority not found" for a brand-new focus, silently redirecting the user
/// to the default focus. The fix self-joins on id when `base.path` is null.
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

  Future<void> insertPriority(
    Uuid id, {
    Path? path,
    String title = 'Focus',
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(id),
            title: Value(title),
            createdBy: Value(Uuid.generate()),
            path: Value(path),
            order: const Value(Order(0)),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  test('getOne resolves a focus with a NULL path to itself', () async {
    final id = Uuid.generate();
    await insertPriority(id, path: null, title: 'Brand new focus');

    final priority = await Priority.getOne(id);
    expect(priority.id, id);
    expect(priority.title, 'Brand new focus');
    expect(priority.path, isNull,
        reason: 'a freshly-created focus has no DB path until sync');
  });

  test('watchOne emits a focus with a NULL path', () async {
    final id = Uuid.generate();
    await insertPriority(id, path: null, title: 'Watched focus');

    final priority = await Priority.watchOne(id).first;
    expect(priority.id, id);
    expect(priority.title, 'Watched focus');
  });

  test('getOne still works for a focus with a synced (non-null) path',
      () async {
    final id = Uuid.generate();
    await insertPriority(id, path: Path('synced'), title: 'Synced focus');

    final priority = await Priority.getOne(id);
    expect(priority.id, id);
    expect(priority.path, Path('synced'));
  });

  test('NULL-path focus self-join returns only itself, no other rows',
      () async {
    final target = Uuid.generate();
    await insertPriority(target, path: null, title: 'Target');
    // A sibling with a real path must NOT leak into the null-path lookup.
    await insertPriority(Uuid.generate(),
        path: Path('other'), title: 'Other');

    final priority = await Priority.getOne(target);
    expect(priority.id, target);
    expect(priority.children, isEmpty);
  });
}
