import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Catch-up pulls run in parallel waves (thread+note first, everything else
/// concurrently after — see `sync_orchestrator.dart`'s `_incrementalPullWaves`),
/// so child rows can now land before the rows they reference: a note before
/// its thread, a thread before its priority, a threadTag before its thread.
///
/// These tests pin the two layers that make that safe:
///   1. SQLite foreign-key enforcement is OFF locally, so an orphan
///      insertOrReplace write can never throw.
///   2. The feed/query layer join-filters or null-tolerates a missing
///      referent instead of throwing, and self-heals (the row appears) once
///      the referent lands and the query re-runs.
///
/// Each orphan test seeds a REAL thread alongside the orphan row so the feed
/// query gets past its empty-page short-circuit (fetchAllTabPage returns
/// early when Phase 1 yields no ids) and hydration genuinely runs with the
/// orphan present.
///
/// Note-specific caveat: no Dart-side note→thread presence-assuming lookup
/// exists at all (note-consuming widgets start from an in-hand Thread via
/// ThreadBlocProvider), so the note test pins the query layer's tolerance,
/// not a lookup fix.
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
    // Priority.getRaw(archived: null) serves from a static snapshot kept
    // fresh by a watch bound to the store that first populated it. Each test
    // gets a fresh in-memory store, so drop the snapshot too (mirrors
    // sign-out) — otherwise a later test reads the previous store's
    // priorities and its threads are wrongly skipped as priority-less.
    Priority.clearCache();
  });

  tearDown(() async {
    Actor.clearCache();
    Priority.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  // Seed a `self` actor and prime the Actor cache so the thread hydration's
  // active-thread query resolves the current user locally (otherwise it
  // reaches into the unregistered [Base] singleton and throws). Copied from
  // activity_feed_done_order_test.dart.
  Future<void> seedSelf() async {
    await store.into(store.actors).insert(
          ActorsCompanion(
            id: Value(ActorId(Uuid.generate())),
            type: const Value(ActorType.contact),
            name: const Value('Me'),
            email: const Value('me@x.test'),
            self: const Value(true),
            inviteable: const Value(true),
            primary: const Value(true),
          ),
        );
    await Actor.get(self: true);
  }

  Future<void> insertPriority(PriorityId id) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(id),
            title: const Value('Social'),
            createdBy: Value(Uuid.generate()),
            path: Value(Path('social')),
            order: const Value(Order(0)),
            isInbox: const Value(true),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  Future<Uuid> insertThread({required PriorityId priorityId, Uuid? id}) async {
    final threadId = id ?? Uuid.generate();
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(threadId),
            priorityId: Value(priorityId),
            contacts: Value([Uuid.generate()]),
            draft: const Value(false),
            unread: const Value(false),
            importance: const Value(0),
            createdAt: Value(DateTime(2026, 5, 1)),
          ),
        );
    return threadId;
  }

  test('PRAGMA foreign_keys is OFF — orphan writes cannot throw', () async {
    final row = await store.customSelect('PRAGMA foreign_keys').getSingle();
    expect(row.data.values.first, 0,
        reason: 'parallel catch-up writes rely on unenforced FKs; if this '
            'ever flips ON, the wave ordering needs a rethink');
  });

  test('note without its thread: query with real rows does not throw, orphan '
      'is invisible, and its thread appears once it lands', () async {
    await seedSelf();
    final priorityId = Uuid.generate();
    await insertPriority(priorityId);

    // A real thread so the feed query actually returns ids and hydration
    // runs (with no thread rows fetchAllTabPage short-circuits on the empty
    // Phase-1 page and would never process the orphan).
    final realThreadId = await insertThread(priorityId: priorityId);

    // The orphan: a note whose thread hasn't synced yet.
    final missingThreadId = Uuid.generate();
    await store.into(store.notes).insert(
          NotesCompanion(
            id: Value(Uuid.generate()),
            threadId: Value(missingThreadId), // absent thread
            authorId: Value(ActorId(Uuid.generate())),
            sourceCreatedAt: Value(DateTime(2026, 5, 2)),
          ),
        );

    // Hydration processes the real thread alongside the orphan note without
    // throwing; the orphan's thread is not surfaced.
    final before = await Thread.fetchAllTabPage(limit: 50);
    expect(before.threads.map((t) => t.id), [realThreadId]);

    // Self-heal: once the note's thread lands, a fresh query surfaces both.
    await insertThread(priorityId: priorityId, id: missingThreadId);
    final after = await Thread.fetchAllTabPage(limit: 50);
    expect(
      after.threads.map((t) => t.id),
      containsAll([realThreadId, missingThreadId]),
    );
    expect(after.threads, hasLength(2));
  });

  test('thread without its priority: feed query does not throw and thread '
      'appears once the priority lands', () async {
    await seedSelf();
    final orphanPriorityId = Uuid.generate();

    final threadId = await insertThread(priorityId: orphanPriorityId);

    // Priority hasn't synced yet — the feed hydration must skip the thread
    // (Thread._mapResultsToThreads: "Skip activities with missing priority"),
    // not throw.
    final before = await Thread.fetchAllTabPage(limit: 50);
    expect(before.threads, isEmpty);

    // Once the priority lands, the same query self-heals and surfaces it.
    await insertPriority(orphanPriorityId);
    final after = await Thread.fetchAllTabPage(limit: 50);
    expect(after.threads.map((t) => t.id), contains(threadId));
  });

  test('threadTag without its thread: query with real rows does not throw, '
      'orphan is invisible, and its thread appears once it lands', () async {
    await seedSelf();
    final priorityId = Uuid.generate();
    await insertPriority(priorityId);

    // A real thread so the feed query returns ids and hydration (which
    // LEFT JOINs threadTags) actually runs with the orphan tag row present.
    final realThreadId = await insertThread(priorityId: priorityId);

    // ThreadTags is a sidecar table keyed directly on the thread's own id
    // (primary key is (id, occurrence) — see thread_tags.dart), so an
    // "orphan" tag row here is one whose id doesn't match any thread row.
    final missingThreadId = Uuid.generate();
    await store.into(store.threadTags).insert(
          ThreadTagsCompanion(
            id: Value(missingThreadId),
            tags: Value({
              Tag.done: [ActorId(Uuid.generate())],
            }),
          ),
        );

    // No throw; only the real thread surfaces — the orphan tag row never
    // joins in (LEFT JOIN keyed off the threads table).
    final before = await Thread.fetchAllTabPage(limit: 50);
    expect(before.threads.map((t) => t.id), [realThreadId]);

    // Self-heal: once the tag's thread lands, hydration now exercises the
    // tag row attached to a genuinely present thread and the thread appears.
    await insertThread(priorityId: priorityId, id: missingThreadId);
    final after = await Thread.fetchAllTabPage(limit: 50);
    expect(
      after.threads.map((t) => t.id),
      containsAll([realThreadId, missingThreadId]),
    );
    expect(after.threads, hasLength(2));
  });

  test('LIVE self-heal: the feed watch re-emits when a skipped thread\'s '
      'priority lands (no other feed-table write)', () async {
    // Under the parallel catch-up waves, a thread (wave 1) can land before
    // its brand-new priority (wave 2). The one-shot query self-heals on the
    // next call, but a LIVE feed watch only re-emits when a table in its
    // readsFrom set changes — so the priorities table must be in that set,
    // or the skipped thread stays invisible until an unrelated thread/
    // schedule/link write or a navigation re-query happens to fire.
    await seedSelf();
    final orphanPriorityId = Uuid.generate();
    final threadId = await insertThread(priorityId: orphanPriorityId);

    final firstEmission = Completer<List<Uuid>>();
    final sawThread = Completer<void>();
    final sub = Thread.watchAllTabHead(limit: 50).listen((page) {
      final ids = page.threads.map((t) => t.id).toList();
      if (!firstEmission.isCompleted) firstEmission.complete(ids);
      if (ids.contains(threadId) && !sawThread.isCompleted) {
        sawThread.complete();
      }
    });
    addTearDown(sub.cancel);

    // Initial emission: Phase 1 returns the thread id, but hydration skips
    // it (priority missing) — the page is empty.
    final initial = await firstEmission.future
        .timeout(const Duration(seconds: 5));
    expect(initial, isEmpty,
        reason: 'thread must be hidden while its priority is missing');

    // The ONLY write is the priority row itself — no thread/schedule/link/
    // tag write, no re-subscription. The live watch must re-emit with the
    // thread now present.
    await insertPriority(orphanPriorityId);
    await sawThread.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'feed watch never re-emitted after the missing priority landed — '
        'the priorities table is missing from the feed id-watch readsFrom '
        'set, so a thread synced before its priority stays invisible until '
        'an unrelated feed-table write',
      ),
    );
  });
}
