import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
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

  Future<Link> insertLink({
    required int priority,
    required bool noteScoped,
    required DateTime createdAt,
  }) async {
    final id = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(id),
            sourceCreatedAt: createdAt,
            createdAt: Value(createdAt),
            threadId: Value(Uuid.generate()),
            priority: Value(priority),
            noteScoped: Value(noteScoped),
          ),
        );
    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(id.toBytes())))
        .getSingle();
    return Link(row);
  }

  test('returns null for empty and for all-note-scoped lists', () async {
    expect(Thread.primaryLink([]), isNull);
    final noteOnly = await insertLink(
      priority: 9,
      noteScoped: true,
      createdAt: DateTime(2026, 1, 1),
    );
    expect(Thread.primaryLink([noteOnly]), isNull);
  });

  test('highest priority wins, note-scoped excluded', () async {
    final low = await insertLink(
      priority: 1, noteScoped: false, createdAt: DateTime(2026, 1, 1));
    final high = await insertLink(
      priority: 5, noteScoped: false, createdAt: DateTime(2026, 1, 2));
    final highestButNoteScoped = await insertLink(
      priority: 99, noteScoped: true, createdAt: DateTime(2026, 1, 3));
    final primary = Thread.primaryLink([low, high, highestButNoteScoped]);
    expect(primary!.id, high.id);
  });

  test('ties break on earliest created_at', () async {
    final later = await insertLink(
      priority: 3, noteScoped: false, createdAt: DateTime(2026, 2, 2));
    final earlier = await insertLink(
      priority: 3, noteScoped: false, createdAt: DateTime(2026, 1, 1));
    final primary = Thread.primaryLink([later, earlier]);
    expect(primary!.id, earlier.id);
  });
}
