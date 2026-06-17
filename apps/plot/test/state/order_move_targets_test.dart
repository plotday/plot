import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/move_recency.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

Future<void> _insertActor(Store store, Uuid id,
    {required String name, bool self = false}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(ActorId(id)),
          type: const Value(ActorType.contact),
          name: Value(name),
          email: Value('${name.replaceAll(' ', '.').toLowerCase()}@x.test'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<void> _insertRole(Store store, Uuid id,
    {required Uuid createdBy, required String name}) async {
  await store.into(store.roles).insert(
        RolesCompanion(
          id: Value(id),
          createdBy: Value(createdBy),
          name: Value(name),
        ),
      );
}

Future<void> _insertPriority(Store store, Uuid id,
    {required Uuid createdBy,
    required String title,
    required String path,
    bool isInbox = false,
    Uuid? roleId}) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: Value(title),
          createdBy: Value(createdBy),
          path: Value(Path(path)),
          isInbox: Value(isInbox),
          roleId: roleId == null ? const Value.absent() : Value(roleId),
        ),
      );
}

List<String> _titles(List<Priority> ps) => ps.map((p) => p.title).toList();

void main() {
  group('orderMoveTargets', () {
    late Store store;
    late Uuid self;
    late Uuid roleA;
    late Uuid roleB;
    late Map<String, Priority> byTitle;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
      store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance.registerSingleton<Store>(() => store, override: true);
      Actor.clearCache();
      Role.clearCache();
      Priority.clearCache();

      self = Uuid.generate();
      roleA = Uuid.generate();
      roleB = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertRole(store, roleA, createdBy: self, name: 'Role A');
      await _insertRole(store, roleB, createdBy: self, name: 'Role B');

      // Base order = ascending path (no sessions => recent-order ties break on path).
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Everything',
          path: 'a',
          isInbox: true,
          roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Alpha', path: 'a.b', roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Beta', path: 'a.c', roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Gamma', path: 'a.d', roleId: roleB);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Delta', path: 'a.e', roleId: roleB);

      final all = await Priority.getRaw(order: PriorityOrder.recent);
      byTitle = {for (final p in all) p.title: p};
    });

    tearDown(() async {
      Actor.clearCache();
      Role.clearCache();
      Priority.clearCache();
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    });

    test('base order is ascending path (sanity)', () {
      // byTitle is a LinkedHashMap (insertion order); we re-sort by path below.
      expect(_titles(byTitle.values.toList()..sort((a, b) =>
          (a.path?.toString() ?? '').compareTo(b.path?.toString() ?? ''))),
          ['Everything', 'Alpha', 'Beta', 'Gamma', 'Delta']);
    });

    test('empty recency: same-role focuses lead, then base order', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: const [],
        currentRoleId: roleA,
      );
      // Tier 1 (roleA, base order): Everything, Alpha, Beta.
      // Tier 2 (roleB, base order): Gamma, Delta. Inbox is NOT pinned.
      expect(_titles(ordered), ['Everything', 'Alpha', 'Beta', 'Gamma', 'Delta']);
    });

    test('recent moves float above same-role, in MRU order', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Delta']!.id, byTitle['Gamma']!.id], // Delta newest
        currentRoleId: roleA,
      );
      // Tier 0 (MRU): Delta, Gamma. Then Tier 1 roleA: Everything, Alpha, Beta.
      expect(_titles(ordered), ['Delta', 'Gamma', 'Everything', 'Alpha', 'Beta']);
    });

    test('a recent + same-role focus appears once, in Tier 0', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Beta']!.id], // Beta is roleA AND recent
        currentRoleId: roleA,
      );
      // Tier 0: Beta. Tier 1 roleA: Everything, Alpha. Tier 2 roleB: Gamma, Delta.
      expect(_titles(ordered), ['Beta', 'Everything', 'Alpha', 'Gamma', 'Delta']);
    });

    test('null currentRoleId: no same-role tier, base order after recents', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Gamma']!.id],
        currentRoleId: null,
      );
      // Tier 0: Gamma. Tier 2 (everyone else, base order): Everything, Alpha, Beta, Delta.
      expect(_titles(ordered), ['Gamma', 'Everything', 'Alpha', 'Beta', 'Delta']);
    });
  });
}
