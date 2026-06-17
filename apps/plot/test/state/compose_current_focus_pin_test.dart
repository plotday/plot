import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

/// The "Private notes" section leads with the focus the user is currently
/// viewing (passed as `currentFocusId`), so the most likely note destination
/// is the first option — unless they're in the Everything view (no current
/// focus), where nothing is pinned. The pinned focus is MOVED to the front of
/// the MRU order, never duplicated lower down.

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

Future<void> _insertThread(
  Store store,
  Uuid id, {
  required Uuid priorityId,
  required List<Uuid> contacts,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(id),
          priorityId: Value(priorityId),
          contacts: Value(contacts),
          groups: const Value([]),
          draft: const Value(false),
        ),
      );
}

Future<void> _insertNote(
  Store store,
  Uuid threadId, {
  required Uuid author,
}) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(Uuid.generate()),
          threadId: Value(threadId),
          authorId: Value(ActorId(author)),
          sourceCreatedAt: Value(DateTime(2026, 1, 1)),
        ),
      );
}

void main() {
  group('Private notes pins the current focus', () {
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
    late Uuid inboxId;
    late Uuid workId;
    late Uuid errandsId;

    Future<ComposeTargetsBloc> seedAndBuild() async {
      self = Uuid.generate();
      inboxId = Uuid.generate();
      workId = Uuid.generate();
      errandsId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      await _insertPriority(store, inboxId,
          createdBy: self, title: 'Everything', path: 'a', isInbox: true);
      await _insertPriority(store, workId,
          createdBy: self, title: 'Work', path: 'a.b');
      await _insertPriority(store, errandsId,
          createdBy: self, title: 'Errands', path: 'a.c');

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      return bloc;
    }

    int countOf(ComposeSections s, Uuid id) =>
        s.focuses.where((t) => t.priorityId == id).length;

    test('the current focus is the first option and appears exactly once',
        () async {
      final bloc = await seedAndBuild();

      final sections = await bloc.loadSections(currentFocusId: errandsId);

      expect(sections.focuses.first.priorityId, errandsId,
          reason: 'the current focus leads the Private notes section');
      expect(countOf(sections, errandsId), 1,
          reason: 'the pinned focus is moved, not duplicated');
      // The other focuses are still present.
      final ids = sections.focuses.map((t) => t.priorityId).toSet();
      expect(ids, containsAll(<Uuid>[workId, inboxId]));
    });

    test('the Everything view (no current focus) pins nothing', () async {
      final bloc = await seedAndBuild();

      final sections = await bloc.loadSections(currentFocusId: null);

      // Every focus is still present, each exactly once.
      expect(countOf(sections, errandsId), 1);
      expect(countOf(sections, workId), 1);
      expect(countOf(sections, inboxId), 1);
    });

    test(
        'a current focus already in the MRU (note history) is not duplicated',
        () async {
      final bloc = await seedAndBuild();

      // Give the current focus authored Plot history so it lands in the MRU
      // portion of the focus order (not the trailing "no history" section).
      final threadId = Uuid.generate();
      await _insertThread(store, threadId,
          priorityId: errandsId, contacts: [self]);
      await _insertNote(store, threadId, author: self);

      // Rebuild the search context so the new thread is scanned into the MRU.
      await bloc.refresh();

      final sections = await bloc.loadSections(currentFocusId: errandsId);

      expect(sections.focuses.first.priorityId, errandsId);
      expect(countOf(sections, errandsId), 1,
          reason: 'a focus already in the MRU must not appear twice');
    });
  });
}
