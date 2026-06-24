/// Verifies [ThreadBloc.sendWithUndo]: the note is saved immediately as a real
/// (non-draft) row but its remote push is HELD by [PendingSend] for the undo
/// window; [commit] releases the hold; [undo] hides the note again; and a
/// still-draft thread is promoted on send.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

// ---------------------------------------------------------------------------
// Fixed identities so rows can reference each other without generated UUIDs
// clashing across rebuilds.
// ---------------------------------------------------------------------------

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _priorityId = Uuid.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
final _threadId = ThreadId.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');
// A contact who is NOT the current user — makes a thread "shared" so sends get
// the undo window (unshared/solo threads skip it).
final _otherId = ActorId.fromString('ffffffff-ffff-ffff-ffff-ffffffffffff');

String _hex(Uuid id) =>
    id.toBytes().map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// DB insert helpers (mirror compose_targets_test.dart pattern)
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

Future<void> _insertPriority(Store store, Uuid id) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: const Value('Test Focus'),
          createdBy: Value(_selfId.value),
          isInbox: const Value(true),
        ),
      );
}

Future<Thread> _insertThread(
  Store store, {
  bool draft = false,
  bool shared = true,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(_threadId),
          priorityId: Value(_priorityId),
          contacts: Value(
            shared ? [_selfId.value, _otherId.value] : [_selfId.value],
          ),
          groups: const Value([]),
          draft: Value(draft),
        ),
      );
  return Thread.getOne(_threadId);
}

Note _note({String content = 'hello', bool private = false}) => Note(
      id: NoteId.generate(),
      threadId: _threadId,
      authorId: _selfId,
      draft: false,
      content: content,
      // A private note's accessContacts is just the author.
      accessContacts: private ? [_selfId] : null,
      createdAt: DateTime(2026),
      sourceCreatedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Binding so SchedulerBinding.scheduleTask (used by Thread.save's deferred
  // push) is controlled by the test harness instead of firing during
  // finalization with no API/Tracker configured.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Store store;
  late LocalPreferencesBloc localPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();

    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();

    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    await _insertActor(store, _selfId, self: true);
    await _insertPriority(store, _priorityId);
    await Actor.get(self: true);

    Base.initForTesting(_selfId);

    localPreferences = LocalPreferencesBloc();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await PendingSend.instance.undo();
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();
    await localPreferences.close();
    Actor.clearCache();
    TwistInstance.clearCache();
    Base.removeForTesting();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('saves the note immediately as a real (non-draft) row but holds its '
      'push for the undo window', () async {
    final thread = await _insertThread(store);
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
    final note = _note();

    await bloc.sendWithUndo(note);

    // The note is a real, non-draft row right away (appears in the list).
    final rows = await (store.select(store.notes)
          ..where((n) => n.draft.equals(false)))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.content, 'hello');

    // But its push is held, and the thread (already real) was not promoted.
    expect(PendingSend.instance.isPending, isTrue);
    expect(PendingSend.instance.pendingNoteId, note.id);
    expect(PendingSend.instance.promotedThreadFromDraft, isFalse);
    expect(Store.pushHeldNoteIds, contains(_hex(note.id)));
    // (commit's hold-release + push is covered network-free in
    // pending_send_test.dart; not exercised here to avoid a real push.)

    // Release the pending send now so the real 5s timer never fires a network
    // commit during the (slow) test run.
    await PendingSend.instance.undo();
    await bloc.close();
  });

  test('undo hides the never-pushed note (draft + archived)', () async {
    final thread = await _insertThread(store);
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
    final note = _note(content: 'oops');

    await bloc.sendWithUndo(note);
    await PendingSend.instance.undo();

    final row = await (store.select(store.notes)
          ..where((n) => n.id.equals(note.id.toBytes())))
        .getSingle();
    expect(row.draft, isTrue);
    expect(row.archivedAt, isNotNull);
    expect(Store.pushHeldNoteIds, isEmpty);

    await bloc.close();
  });

  test('promotes a still-draft thread on send (re-send after undo) and holds '
      'both pushes', () async {
    final draftThread = await _insertThread(store, draft: true);
    final bloc =
        ThreadBloc(thread: draftThread, localPreferences: localPreferences);
    final note = _note();

    await bloc.sendWithUndo(note);

    expect(PendingSend.instance.promotedThreadFromDraft, isTrue);
    final promoted = await Thread.getOne(_threadId);
    expect(promoted.draft, isFalse, reason: 'thread is no longer stranded');
    expect(Store.pushHeldNoteIds, contains(_hex(note.id)));
    expect(Store.pushHeldThreadIds, contains(_hex(_threadId)));

    // Release now so the real 5s timer never fires a network commit.
    await PendingSend.instance.undo();
    await bloc.close();
  });

  test('skips the undo window for a note on a solo (unshared) thread',
      () async {
    final thread = await _insertThread(store, shared: false);
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
    final note = _note();

    await bloc.sendWithUndo(note);

    // No undo window: nothing held, and the note is already a real non-draft
    // row (it sent immediately).
    expect(PendingSend.instance.isPending, isFalse);
    expect(Store.pushHeldNoteIds, isEmpty);
    final row = await (store.select(store.notes)
          ..where((n) => n.id.equals(note.id.toBytes())))
        .getSingle();
    expect(row.draft, isFalse);

    await bloc.close();
  });

  test('skips the undo window for a private note on a shared thread', () async {
    final thread = await _insertThread(store); // shared
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
    final note = _note(private: true);

    await bloc.sendWithUndo(note);

    expect(PendingSend.instance.isPending, isFalse);
    expect(Store.pushHeldNoteIds, isEmpty);

    await bloc.close();
  });
}
