import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// [CustomEmoji.forScope] backs the reaction picker's "Workspace custom" group:
/// given a connection's opaque scope token (e.g. `slack:T0`), it returns the
/// non-archived custom-emoji rows whose `id` is `<scope>/<name>`. The scope is
/// treated as an opaque prefix — no provider/workspace parsing — so it works
/// for any future workspace-emoji connector.
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

  Future<void> insertEmoji(
    String id, {
    String provider = 'slack',
    String workspaceId = 'T0',
    String name = 'x',
    DateTime? archivedAt,
  }) async {
    await store.into(store.customEmojis).insert(
          CustomEmojisCompanion.insert(
            id: id,
            provider: provider,
            workspaceId: workspaceId,
            name: name,
            imageUrl: 'https://e/$name.gif',
            archivedAt: Value(archivedAt),
          ),
        );
  }

  test('forScope returns only the scope\'s non-archived emoji', () async {
    await insertEmoji('slack:T0/a', name: 'a');
    await insertEmoji('slack:T0/b', name: 'b');
    // Different scope (workspace T1) — must be excluded.
    await insertEmoji('slack:T1/c', workspaceId: 'T1', name: 'c');
    // Same scope but archived — must be excluded.
    await insertEmoji(
      'slack:T0/old',
      name: 'old',
      archivedAt: DateTime.now(),
    );

    final rows = await CustomEmoji.forScope('slack:T0');
    final ids = rows.map((r) => r.id).toList()..sort();

    expect(ids, ['slack:T0/a', 'slack:T0/b']);
  });

  test('forScope returns empty for a scope with no emoji', () async {
    await insertEmoji('slack:T0/a', name: 'a');
    final rows = await CustomEmoji.forScope('slack:T9');
    expect(rows, isEmpty);
  });
}
