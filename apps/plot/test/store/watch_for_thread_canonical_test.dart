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

  Future<void> insert(ThreadId threadId,
      {required int priority,
      required bool noteScoped,
      required DateTime createdAt}) async {
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(Uuid.generate()),
            sourceCreatedAt: createdAt,
            createdAt: Value(createdAt),
            threadId: Value(threadId),
            priority: Value(priority),
            noteScoped: Value(noteScoped),
          ),
        );
  }

  test('excludes note-scoped links and orders by priority desc, created asc',
      () async {
    final threadId = Uuid.generate();
    await insert(threadId,
        priority: 1, noteScoped: false, createdAt: DateTime(2026, 1, 3));
    await insert(threadId,
        priority: 5, noteScoped: false, createdAt: DateTime(2026, 1, 2));
    await insert(threadId,
        priority: 99, noteScoped: true, createdAt: DateTime(2026, 1, 1));

    final links = await Link.watchForThread(threadId).first;

    expect(links.every((l) => !l.noteScoped), isTrue);
    expect(links.map((l) => l.priority).toList(), [5, 1]);
  });
}
