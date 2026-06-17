import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

/// The new-thread picker's "Private notes" (focuses) section filters via
/// [ComposeTargetsBloc.searchSections]. When the user has more than one role,
/// a focus must be findable by its owning role name too (e.g. typing "marlow"
/// surfaces every focus under the "AFC Marlow" role), consistent with the
/// other focus pickers. Gated on 2+ roles, mirroring [FocusLabel]'s role
/// prefix.

Future<void> _insertActor(
  Store store,
  Uuid id, {
  required String name,
  bool self = false,
}) async {
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

Future<void> _insertRole(
  Store store,
  Uuid id, {
  required Uuid createdBy,
  required String name,
}) async {
  await store.into(store.roles).insert(
        RolesCompanion(
          id: Value(id),
          createdBy: Value(createdBy),
          name: Value(name),
        ),
      );
}

Future<void> _insertPriority(
  Store store,
  Uuid id, {
  required Uuid createdBy,
  required String title,
  String? path,
  bool isInbox = false,
  Uuid? roleId,
}) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: Value(title),
          createdBy: Value(createdBy),
          path: path == null ? const Value.absent() : Value(Path(path)),
          isInbox: Value(isInbox),
          roleId: roleId == null ? const Value.absent() : Value(roleId),
        ),
      );
}

/// Pumps the event queue until the synchronous role cache (which
/// [Priority.matchesSearch] reads) reflects [expected] roles. Reading
/// [Role.cachedCount] starts the lazy watch on the store.
Future<void> _warmRoleCache({int expected = 2}) async {
  for (var i = 0; i < 100 && Role.cachedCount < expected; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('searchSections focus filtering by role name', () {
    late Store store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
      store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance
          .registerSingleton<Store>(() => store, override: true);
      Actor.clearCache();
      TwistInstance.clearCache();
      Role.clearCache();
      Channel.populateCache(const []);
    });

    tearDown(() async {
      Actor.clearCache();
      TwistInstance.clearCache();
      Role.clearCache();
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    });

    late Uuid self;
    late Uuid marlowRole;
    late Uuid personalRole;
    late Uuid financesId; // under AFC Marlow
    late Uuid budgetId; // under Personal

    Future<ComposeTargetsBloc> seedAndBuild() async {
      self = Uuid.generate();
      marlowRole = Uuid.generate();
      personalRole = Uuid.generate();
      financesId = Uuid.generate();
      budgetId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      await _insertRole(store, marlowRole, createdBy: self, name: 'AFC Marlow');
      await _insertRole(store, personalRole, createdBy: self, name: 'Personal');

      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Everything',
          path: 'a',
          isInbox: true,
          roleId: personalRole);
      await _insertPriority(store, financesId,
          createdBy: self, title: 'Finances', path: 'a.b', roleId: marlowRole);
      await _insertPriority(store, budgetId,
          createdBy: self, title: 'Budget', path: 'a.c', roleId: personalRole);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await _warmRoleCache();
      return bloc;
    }

    test('typing a role name surfaces only that role\'s focuses', () async {
      final bloc = await seedAndBuild();
      expect(Role.cachedCount, 2, reason: 'both roles must warm the cache');

      final sections = await bloc.searchSections('marlow');
      final focusIds =
          sections.focuses.map((t) => t.priorityId).whereType<Uuid>().toSet();

      expect(focusIds, contains(financesId),
          reason: 'a focus under "AFC Marlow" matches the role name');
      expect(focusIds, isNot(contains(budgetId)),
          reason: 'a focus under a different role must not match');
    });

    test('focus name search still works alongside role search', () async {
      final bloc = await seedAndBuild();

      final byName = await bloc.searchSections('budget');
      final byNameIds =
          byName.focuses.map((t) => t.priorityId).whereType<Uuid>().toSet();
      expect(byNameIds, contains(budgetId));
      expect(byNameIds, isNot(contains(financesId)));
    });

    test('a single role does not make focuses match the role name', () async {
      self = Uuid.generate();
      final onlyRole = Uuid.generate();
      financesId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);
      await _insertRole(store, onlyRole, createdBy: self, name: 'AFC Marlow');
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Everything',
          path: 'a',
          isInbox: true,
          roleId: onlyRole);
      await _insertPriority(store, financesId,
          createdBy: self, title: 'Finances', path: 'a.b', roleId: onlyRole);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await _warmRoleCache(expected: 1);

      final sections = await bloc.searchSections('marlow');
      final focusIds =
          sections.focuses.map((t) => t.priorityId).whereType<Uuid>().toSet();
      expect(focusIds, isNot(contains(financesId)),
          reason: 'with one role the role name is not part of focus search');
    });
  });
}
