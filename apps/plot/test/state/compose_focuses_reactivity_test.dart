import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

/// Regression coverage for the new-thread picker's "Private notes" (focuses)
/// section. The focuses are derived from the priorities store, so the bloc must
/// react to priority changes — not only connection/twist changes. See the
/// `_watchConnections` priority watch in [ComposeTargetsBloc].

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

Future<void> _insertPriority(
  Store store,
  Uuid id, {
  required Uuid createdBy,
  required String title,
  String? path,
  bool root = false,
  bool isInbox = false,
  bool isFyi = false,
  Uuid? roleId,
}) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: Value(title),
          createdBy: Value(createdBy),
          path: path == null ? const Value.absent() : Value(Path(path)),
          root: Value(root),
          isInbox: Value(isInbox),
          isFyi: Value(isFyi),
          roleId: roleId == null ? const Value.absent() : Value(roleId),
        ),
      );
}

void main() {
  group('ComposeTargetsBloc focuses (Private notes) section', () {
    late Store store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
      store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance
          .registerSingleton<Store>(() => store, override: true);
      Actor.clearCache();
      TwistInstance.clearCache();
      Channel.populateCache(const []);
    });

    tearDown(() async {
      Actor.clearCache();
      TwistInstance.clearCache();
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    });

    test('loadSections surfaces every focus in the role model', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final personalRole = Uuid.generate();
      // Mirrors the real DB: a root Inbox (isInbox + role), role focuses, FYI.
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Everything',
          path: 'a',
          root: true,
          isInbox: true,
          roleId: personalRole);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: "Men's team",
          path: 'a.b',
          roleId: Uuid.generate());
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Facilities',
          path: 'a.c',
          roleId: Uuid.generate());
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'FYI', path: 'a.d', isFyi: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      final sections = await bloc.loadSections();

      expect(sections.focuses, hasLength(4),
          reason: 'every non-archived priority is offered as a focus note');
      // The view drops any focus that does not resolve in priorityById, so the
      // resolution map must be consistent with the focuses it returns.
      for (final t in sections.focuses) {
        expect(bloc.priorityById[t.priorityId], isNotNull);
      }
    });

    test('focuses still resolve for locally-created priorities (null path)',
        () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Everything', root: true, isInbox: true);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: "Men's team", roleId: Uuid.generate());

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      final sections = await bloc.loadSections();
      expect(sections.focuses, hasLength(2));
    });

    test(
        'focuses appear when priorities sync in AFTER the picker was warmed '
        '(bloc reacts to priority changes, not just connection/twist changes)',
        () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      // The shell warms the picker at mount — before priorities/roles have
      // synced (on the role model, priorities pull after roles). The context
      // is cached with no focuses yet.
      await bloc.warm();
      final early = await bloc.loadSections();
      expect(early.focuses, isEmpty);

      // Priorities/roles now arrive via sync (direct store writes, exactly as
      // the sync layer applies them).
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Everything', root: true, isInbox: true);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: "Men's team", roleId: Uuid.generate());

      // The priority watch triggers a debounced (250ms) refresh that rebuilds
      // the cached context. Without that watch the section stays empty forever.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final later = await bloc.loadSections();
      expect(later.focuses, isNotEmpty,
          reason: 'the Private notes section must appear once focuses sync in');
    });
  });
}
