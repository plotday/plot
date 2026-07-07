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
    required List<UserAction> actions,
  }) async {
    final id = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(id),
            sourceCreatedAt: DateTime(2026, 1, 1),
            createdAt: Value(DateTime(2026, 1, 1)),
            threadId: Value(Uuid.generate()),
            priority: Value(priority),
            noteScoped: const Value(false),
            actions: Value(actions),
          ),
        );
    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(id.toBytes())))
        .getSingle();
    return Link(row);
  }

  const meet = ConferencingUserAction(
    url: 'https://meet.google.com/zoe-ecjq-ggc',
    provider: ConferencingProvider.googleMeet,
  );

  test('empty for no links / no conferencing actions', () async {
    expect(Thread.conferencingActions([]), isEmpty);
    final plain = await insertLink(priority: 0, actions: const []);
    expect(Thread.conferencingActions([plain]), isEmpty);
  });

  test('the same join URL across two links yields one action', () async {
    // An event thread commonly carries the same conferencing action on more
    // than one link (e.g. a base calendar link and a link-schedule instance).
    final a = await insertLink(priority: 1, actions: const [meet]);
    final b = await insertLink(priority: 0, actions: const [meet]);
    final actions = Thread.conferencingActions([a, b]);
    expect(actions, hasLength(1));
    expect(actions.single.url, meet.url);
  });

  test('distinct join URLs are all kept', () async {
    const zoom = ConferencingUserAction(
      url: 'https://zoom.us/j/123',
      provider: ConferencingProvider.zoom,
    );
    final a = await insertLink(priority: 1, actions: const [meet]);
    final b = await insertLink(priority: 0, actions: const [zoom]);
    expect(
      Thread.conferencingActions([a, b]).map((c) => c.url),
      [meet.url, zoom.url],
    );
  });
}
