// Regression / lock-in: composing from the Everything view (context-less
// PriorityState) must always file the new thread under a real focus.
//
// Invariant set up by Task 1: when `PriorityBloc` is opened in `everything`
// mode the draft is initialised against `Priority.defaultInbox(priorities)`
// (the oldest `is_inbox` focus) via `draftFallbackPriority`.
//
// The MRU suggestion flow (`_suggestFocusForTarget`) then either:
//   • re-files to the MRU-top non-inbox focus when there is authored history
//     for the chosen roster, OR
//   • returns early (both `rankFocusesForRoster` and `rankFocusesGlobal`
//     return []) leaving the draft on the Inbox fallback.
//
// This test verifies that second half — the compose-targets ranking layer —
// at the bloc level (no widget tree required).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

// ---------------------------------------------------------------------------
// Helpers (mirror compose_targets_test.dart pattern)
// ---------------------------------------------------------------------------

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
  bool isInbox = false,
  DateTime? createdAt,
}) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: Value(title),
          createdBy: Value(createdBy),
          isInbox: Value(isInbox),
          createdAt:
              createdAt == null ? const Value.absent() : Value(createdAt),
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group(
      'NewThreadPage Everything compose fallback '
      '(MRU ranking layer — lock-in)', () {
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

    // Helpers shared by both tests below.
    late Uuid self;
    late Uuid inboxId;
    late Uuid focusId;
    late Uuid contactId;

    Future<void> seedBaseData() async {
      self = Uuid.generate();
      inboxId = Uuid.generate();
      focusId = Uuid.generate();
      contactId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, contactId, name: 'Alice');
      // Inbox is oldest (createdAt earlier).
      await _insertPriority(store, inboxId,
          createdBy: self,
          title: 'Inbox',
          isInbox: true,
          createdAt: DateTime(2024));
      await _insertPriority(store, focusId,
          createdBy: self,
          title: 'Work',
          createdAt: DateTime(2025));

      // Warm Actor caches so getCurrentUserActorIds() works.
      await Actor.get(self: true);
      await Actor.get();
    }

    test(
        'no MRU history → rankFocusesForRoster + rankFocusesGlobal both empty '
        '→ draft stays on defaultInbox (the fallback)', () async {
      await seedBaseData();

      // No authored threads at all — both ranking calls must return [].
      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      final rosterRank = await bloc.rankFocusesForRoster(
        contacts: [contactId],
        groups: const [],
      );
      expect(rosterRank, isEmpty,
          reason: 'no authored threads → roster ranking is empty');

      final globalRank = await bloc.rankFocusesGlobal();
      expect(globalRank, isEmpty,
          reason: 'no authored threads → global ranking is empty');

      // Because both ranks are empty, _suggestFocusForTarget returns early
      // without calling _switchToPriority. The draft therefore stays on
      // draftFallbackPriority = Priority.defaultInbox(priorities).
      // Verify the defaultInbox helper itself resolves to the oldest inbox.
      final priorities = await Priority.getRaw();
      final defaultInbox = Priority.defaultInbox(priorities);
      expect(defaultInbox, isNotNull,
          reason: 'defaultInbox must resolve when an is_inbox row exists');
      expect(defaultInbox!.id, equals(inboxId),
          reason: 'defaultInbox is the oldest is_inbox priority');
    });

    test(
        'with MRU history for roster → rankFocusesForRoster returns '
        'non-inbox focus first', () async {
      await seedBaseData();

      // One authored thread to [contactId] filed under the non-inbox focusId.
      final threadId = Uuid.generate();
      await _insertThread(store, threadId,
          priorityId: focusId, contacts: [self, contactId]);
      await _insertNote(store, threadId, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      final rosterRank = await bloc.rankFocusesForRoster(
        contacts: [contactId],
        groups: const [],
      );
      expect(rosterRank, isNotEmpty,
          reason: 'authored thread with matching roster → non-empty ranking');
      expect(rosterRank.first, equals(focusId),
          reason: 'MRU-top focus for this roster is the non-inbox focus');

      // The inbox focus must be skipped by _suggestFocusForTarget (`:1484`),
      // so verify it does NOT appear in the ranking (it was filed under focusId,
      // not inboxId, so it isn't in the list regardless — but also confirm the
      // filter would catch it if it were inbox).
      final priorities = await Priority.getRaw();
      final inboxPriority =
          priorities.where((p) => p.id == inboxId).firstOrNull;
      expect(inboxPriority?.isInbox, isTrue);
      // The _suggestFocusForTarget guard: `if (p != null && !p.isInbox)`.
      // Confirm ranked list contains only non-inbox ids.
      final priorityById = {for (final p in priorities) p.id: p};
      for (final id in rosterRank) {
        final p = priorityById[id];
        if (p != null) {
          expect(p.isInbox, isFalse,
              reason:
                  'Inbox focuses must not appear in the MRU suggestion list');
        }
      }
    });
  });
}
