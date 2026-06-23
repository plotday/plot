/// Verifies [ThreadBloc.sendWithUndo]: the publish-ready note is registered
/// with [PendingSend] instead of saved immediately, and [PendingSend.commit]
/// then writes it to the DB.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/base.dart';
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
final _threadId = Uuid.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');

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

Future<Thread> _insertThread(Store store) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(_threadId),
          priorityId: Value(_priorityId),
          contacts: Value([_selfId.value]),
          groups: const Value([]),
          draft: const Value(false),
        ),
      );
  return Thread.getOne(_threadId);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Store store;
  late LocalPreferencesBloc localPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();

    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);

    // Populate actor cache and Base.actorId for Note.draft() / ThreadBloc.
    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    await _insertActor(store, _selfId, self: true);
    await _insertPriority(store, _priorityId);
    await Actor.get(self: true); // primes Actor.getCurrentUserActorIds()

    Base.initForTesting(_selfId);

    localPreferences = LocalPreferencesBloc();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    // Leave PendingSend idle — undo() clears state without writing to DB.
    await PendingSend.instance.undo();
    await localPreferences.close();
    Actor.clearCache();
    TwistInstance.clearCache();
    Base.removeForTesting();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('sendWithUndo registers pending send but does not publish the note yet',
      () async {
    // Arrange: a saved (non-draft) thread + a ThreadBloc over it.
    final thread = await _insertThread(store);
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);

    // Construct a publish-ready note (draft=false) for this thread.
    final note = Note(
      id: NoteId.generate(),
      threadId: _threadId,
      authorId: _selfId,
      draft: false,
      content: 'hello',
      createdAt: DateTime(2026),
      sourceCreatedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    // Act
    await bloc.sendWithUndo(note);

    // Assert: pending, but no published note row in the DB yet.
    expect(PendingSend.instance.isPending, isTrue);
    final published = await (store.select(store.notes)
          ..where((n) => n.draft.equals(false)))
        .get();
    expect(published, isEmpty);

    // After the window commits, the note lands in the DB.
    await PendingSend.instance.commit();
    final after = await (store.select(store.notes)
          ..where((n) => n.draft.equals(false)))
        .get();
    expect(after, hasLength(1));
    expect(after.single.content, 'hello');

    await bloc.close();
  });
}
