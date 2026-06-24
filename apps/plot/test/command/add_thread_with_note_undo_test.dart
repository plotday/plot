/// Verifies that [PriorityBloc.sendThreadWithUndo] promotes the new thread and
/// publishes the note immediately (so they appear in the feed/list/search) but
/// HOLDS both pushes via [PendingSend] for the undo window. Also verifies
/// [PriorityBloc.resetDraftAfterSend] emits a fresh compose surface.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/app_info.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

// ---------------------------------------------------------------------------
// Fixed identities so rows can reference each other without generated UUIDs
// clashing across rebuilds.
// ---------------------------------------------------------------------------

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _priorityId = Uuid.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
// A contact who is NOT the current user — makes the new thread "shared" so the
// send gets the undo window (unshared/solo threads skip it).
final _otherId = ActorId.fromString('ffffffff-ffff-ffff-ffff-ffffffffffff');

String _hex(Uuid id) =>
    id.toBytes().map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// DB insert helpers
// ---------------------------------------------------------------------------

Future<void> _insertActor(Store store, ActorId id, {required bool self}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(id),
          type: const Value(ActorType.contact),
          name: const Value('Me'),
          email: const Value('me@test.example'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<Priority> _insertPriority(Store store) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(_priorityId),
          title: const Value('Test Focus'),
          createdBy: Value(_selfId.value),
          isInbox: const Value(true),
        ),
      );
  return Priority.getOne(_priorityId);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal [NowBloc] for [PriorityBloc] construction.
/// [TestWidgetsFlutterBinding] must be initialized before calling this.
NowBloc _buildNowBloc() => NowBloc();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // NowBloc registers itself with WidgetsBinding in its constructor.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // AppInfo.version is a static late final used by the API client in the
    // background sync that PriorityBloc fires on construction. Initialize it
    // once so the sync call doesn't throw LateInitializationError in tests.
    try {
      AppInfo.version = '0.0.0-test';
      AppInfo.buildNumber = '0';
      AppInfo.platform = 'test';
      AppInfo.versionString = 'v0.0.0-test (test build 0)';
    } catch (_) {
      // Already initialized (e.g., when tests share a process).
    }
  });

  late Store store;
  late LocalPreferencesBloc localPreferences;
  late NowBloc nowBloc;
  late Priority priority;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();

    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();

    // Populate actor cache so Note.draft() / Base.actorId resolve.
    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    await _insertActor(store, _selfId, self: true);
    priority = await _insertPriority(store);
    await Actor.get(self: true); // primes Actor.getCurrentUserActorIds()

    Base.initForTesting(_selfId);

    localPreferences = LocalPreferencesBloc();
    nowBloc = _buildNowBloc();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await PendingSend.instance.undo();
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();
    await nowBloc.close();
    await localPreferences.close();
    Actor.clearCache();
    TwistInstance.clearCache();
    Base.removeForTesting();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  group('PriorityBloc.resetDraftAfterSend', () {
    test('emits a fresh draft thread (draft==true) and matching draftNote', () {
      // Use everything: true so _loadPriority sets context=null, which prevents
      // the per-focus background network sync from firing (and needing Env.apiRoot
      // / AppInfo.version / etc. to be initialized). resetDraftAfterSend is
      // called with the real priority so we can verify its output.
      final bloc = PriorityBloc(
        priority: priority,
        nowBloc: nowBloc,
        localPreferences: localPreferences,
        everything: true,
      );
      addTearDown(bloc.close);

      // Act
      bloc.resetDraftAfterSend(priority);

      // Assert: state has a new draft thread (draft==true) with a matching note
      expect(bloc.state.draft.draft, isTrue);
      expect(bloc.state.draftNote.threadId, bloc.state.draft.id);
    });
  });

  group('PriorityBloc.sendThreadWithUndo', () {
    test(
        'with a note: promotes the thread + publishes the note immediately '
        '(real rows) but holds both pushes for the undo window', () async {
      // everything: true prevents the per-focus background sync from needing
      // Env/AppInfo/network (those static late finals aren't set in unit tests).
      final bloc = PriorityBloc(
        priority: priority,
        nowBloc: nowBloc,
        localPreferences: localPreferences,
        everything: true,
      );
      addTearDown(bloc.close);

      // Shared (another contact) so the send gets the undo window.
      final draftThread = Thread(priority: priority, draft: true)
          .copyWith(contacts: Value([_selfId.value, _otherId.value]));
      final note = Note(
        id: NoteId.generate(),
        threadId: draftThread.id,
        authorId: _selfId,
        draft: false,
        content: 'hello undo',
        createdAt: DateTime(2026),
        sourceCreatedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      // Act
      final returned = await bloc.sendThreadWithUndo(draftThread, note: note);

      // The thread is promoted right away (so it appears in the feed/search).
      expect(returned.id, draftThread.id);
      expect(returned.draft, isFalse);

      // Both rows are real (non-draft) in the DB immediately.
      final publishedThreads = await (store.select(store.threads)
            ..where((t) => t.draft.equals(false)))
          .get();
      expect(publishedThreads, hasLength(1));
      final publishedNotes = await (store.select(store.notes)
            ..where((n) => n.draft.equals(false)))
          .get();
      expect(publishedNotes, hasLength(1));
      expect(publishedNotes.single.content, 'hello undo');

      // But both pushes are held for the undo window.
      expect(PendingSend.instance.isPending, isTrue);
      expect(PendingSend.instance.pendingNoteId, note.id);
      expect(PendingSend.instance.pendingThreadId, draftThread.id);
      expect(PendingSend.instance.promotedThreadFromDraft, isTrue);
      expect(Store.pushHeldNoteIds, contains(_hex(note.id)));
      expect(Store.pushHeldThreadIds, contains(_hex(draftThread.id)));

      // Release now so the real 5s timer never fires a network commit.
      // (commit's hold-release is covered network-free in pending_send_test.)
      await PendingSend.instance.undo();
    });

    test('with no note: falls back to immediate add (thread published, no pending)',
        () async {
      final bloc = PriorityBloc(
        priority: priority,
        nowBloc: nowBloc,
        localPreferences: localPreferences,
        everything: true,
      );
      addTearDown(bloc.close);

      // Insert the draft thread so add() can save it.
      final draftThread = Thread(priority: priority, draft: true);
      await store.into(store.threads).insert(
            ThreadsCompanion(
              id: Value(draftThread.id),
              priorityId: Value(_priorityId),
              contacts: Value([_selfId.value]),
              groups: const Value([]),
              draft: const Value(true),
            ),
          );

      // Act
      final returned = await bloc.sendThreadWithUndo(draftThread, note: null);

      // Immediate path: thread is published now; no pending send.
      expect(returned.draft, isFalse);
      expect(PendingSend.instance.isPending, isFalse);
    });
  });
}
