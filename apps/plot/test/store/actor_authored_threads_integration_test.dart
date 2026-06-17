import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Integration tests exercising the real Drift query path for the share
/// picker, against an in-memory database. The unit-level
/// [Actor.buildShareScan] test covers the banding math in isolation; these
/// cover the parts it can't — that the SQL (`existsQuery` correlation +
/// priority-subtree path filter) returns the right threads, and that the
/// full [Actor.getSortedShareCandidates] ranks contacts the user has
/// authored to above the inbound recency tail even when the scoped priority
/// is empty.
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
  });

  tearDown(() async {
    Actor.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<void> insertActor(
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

  Future<void> insertPriority(
    Uuid id,
    String path, {
    required Uuid createdBy,
    bool isInbox = false,
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(id),
            title: Value(path),
            createdBy: Value(createdBy),
            path: Value(Path(path)),
            order: const Value(Order(0)),
            isInbox: Value(isInbox),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  Future<void> insertThread(
    Uuid id, {
    required Uuid priorityId,
    required List<Uuid> contacts,
    DateTime? createdAt,
  }) async {
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(priorityId),
            contacts: Value(contacts),
            draft: const Value(false),
            // The reverse-feed recency key is MAX(..., createdAt, ...), so
            // drive the recent-window ordering through createdAt (otherwise
            // the CURRENT_TIMESTAMP default ties every row at ~now).
            createdAt:
                createdAt == null ? const Value.absent() : Value(createdAt),
          ),
        );
  }

  Future<void> insertNote(Uuid threadId, {required Uuid author}) async {
    await store.into(store.notes).insert(
          NotesCompanion(
            id: Value(Uuid.generate()),
            threadId: Value(threadId),
            authorId: Value(ActorId(author)),
            sourceCreatedAt: Value(DateTime(2026, 1, 1)),
          ),
        );
  }

  test('authoredThreadsForSharing returns only authored threads (null path)',
      () async {
    final self = Uuid.generate();
    final beth = Uuid.generate();
    final mailing = Uuid.generate();
    final priorityId = Uuid.generate();

    final authoredThread = Uuid.generate();
    final inboundThread = Uuid.generate();

    await insertThread(authoredThread,
        priorityId: priorityId, contacts: [self, beth]);
    await insertThread(inboundThread,
        priorityId: priorityId, contacts: [self, mailing]);
    await insertNote(authoredThread, author: self);

    final result = await Actor.authoredThreadsForSharing(
      selfIds: {self},
      priorityId: null,
      limit: 200,
    );

    expect(result.map((t) => t.id), [authoredThread]);
    expect(result.single.contacts, containsAll([self, beth]));
  });

  test('authoredThreadsForSharing scopes to the filed priority', () async {
    final self = Uuid.generate();
    final beth = Uuid.generate();

    final root = Uuid.generate();
    final child = Uuid.generate();
    final outside = Uuid.generate();

    await insertPriority(root, 'root', createdBy: self, isInbox: true);
    await insertPriority(child, 'root.child', createdBy: self);
    await insertPriority(outside, 'other', createdBy: self);

    final inChild = Uuid.generate();
    final inOutside = Uuid.generate();
    await insertThread(inChild, priorityId: child, contacts: [self, beth]);
    await insertThread(inOutside, priorityId: outside, contacts: [self, beth]);
    await insertNote(inChild, author: self);
    await insertNote(inOutside, author: self);

    // Flat model: a focus shows only what's filed directly in it (exact
    // filed-priority id). The thread filed in `child` is included; the one
    // filed in another priority is excluded.
    final result = await Actor.authoredThreadsForSharing(
      selfIds: {self},
      priorityId: child,
      limit: 200,
    );

    expect(result.map((t) => t.id), [inChild]);
  });

  test(
      'getSortedShareCandidates ranks globally-authored contacts above the '
      'recency tail when the scoped priority is empty', () async {
    // Reproduces the parent/root-priority bug: a new thread filed under an
    // empty priority yielded only the global recency tail (inbound mailing
    // lists), because the global *authored* signal was never consulted.
    final self = Uuid.generate();
    final authoredPerson = Uuid.generate();
    final mailingList = Uuid.generate();

    final root = Uuid.generate();
    final emptyChild = Uuid.generate(); // the compose target — no threads
    final otherChild = Uuid.generate(); // holds the user's real history

    await insertActor(self, name: 'Me', self: true);
    await insertActor(authoredPerson, name: 'Authored Person');
    await insertActor(mailingList, name: 'Mailing List');

    await insertPriority(root, 'root', createdBy: self, isInbox: true);
    await insertPriority(emptyChild, 'root.empty', createdBy: self);
    await insertPriority(otherChild, 'root.other', createdBy: self);

    // Authored thread (older) with the real person.
    final authoredThread = Uuid.generate();
    await insertThread(authoredThread,
        priorityId: otherChild,
        contacts: [self, authoredPerson],
        createdAt: DateTime(2026, 1, 1));
    await insertNote(authoredThread, author: self);

    // More-recent inbound thread with the mailing list — no self-authored
    // note. Being newer, it tops the pure-recency tail, so only the
    // global-authored band keeps the real person ranked above it.
    final inboundThread = Uuid.generate();
    await insertThread(inboundThread,
        priorityId: otherChild,
        contacts: [self, mailingList],
        createdAt: DateTime(2026, 5, 1));

    // Populate the Actor cache so getCurrentUserActorIds() resolves self.
    // Default archived:false keeps this a local query (no network pull).
    await Actor.get(self: true);

    final priority = await Priority.getOne(emptyChild);
    final result = await Actor.getSortedShareCandidates(priority: priority);

    final orderedIds = result
        .whereType<ActorShareCandidate>()
        .map((c) => c.actor.id.toUuid())
        .toList();
    final iAuthored = orderedIds.indexOf(authoredPerson);
    final iMailing = orderedIds.indexOf(mailingList);

    expect(iAuthored, isNonNegative, reason: 'authored contact must appear');
    expect(iMailing, isNonNegative, reason: 'mailing list must appear');
    expect(
      iAuthored,
      lessThan(iMailing),
      reason: 'a contact the user has authored to must outrank the '
          'recency-tail mailing list',
    );
  });
}
