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

  test('priority and noteScoped round-trip through the links table', () async {
    final threadId = Uuid.generate();
    final linkId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(linkId),
            sourceCreatedAt: DateTime.now(),
            threadId: Value(threadId),
            priority: const Value(7),
            noteScoped: const Value(true),
          ),
        );

    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(linkId.toBytes())))
        .getSingle();
    final link = Link(row);

    expect(link.priority, 7);
    expect(link.noteScoped, isTrue);
  });

  test('priority defaults to 0 and noteScoped to false', () async {
    final linkId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(linkId),
            sourceCreatedAt: DateTime.now(),
          ),
        );
    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(linkId.toBytes())))
        .getSingle();
    final link = Link(row);

    expect(link.priority, 0);
    expect(link.noteScoped, isFalse);
  });
}
