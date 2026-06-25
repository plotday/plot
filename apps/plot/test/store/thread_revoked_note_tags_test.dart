import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Access-loss cleanup: when a revoked thread (a `user.thread_redacted`
/// tombstone, `revoked=true`) arrives, ThreadsBase.processPulledRows
/// hard-deletes the thread and its dependent rows. `user_note_tags` rows are
/// keyed by note id (no thread_id column), so they must be resolved via the
/// thread's notes and deleted too. If they're left behind they keep their
/// `pending` bit and the sync loop re-pushes them to /sync/note-tags/update
/// forever — the server rejects each push with 422 P0001 "User does not have
/// access to this priority", which the client reports to error tracking on
/// every retry.
void main() {
  test(
    'revoked thread hard-deletes its note_tags rows along with notes',
    () async {
      final raw = sqlite3.openInMemory();
      final store = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(() async {
        await store.close();
        raw.close();
      });

      final threadId = Uuid.generate();
      final noteId = Uuid.generate();

      // Seed a local thread, a note in it, and a pending note_tags row for
      // that note (a tag edit the user made before losing access).
      await store.into(store.threads).insert(
            ThreadsCompanion.insert(
              id: Value(threadId),
              priorityId: Uuid.generate(),
            ),
          );
      await store.into(store.notes).insert(
            NotesCompanion.insert(
              id: Value(noteId),
              threadId: threadId,
              authorId: ActorId(Uuid.generate()),
              sourceCreatedAt: DateTime(2026, 1, 1),
            ),
          );
      await store.into(store.noteTags).insert(
            NoteTagsCompanion.insert(
              id: Value(noteId),
              pending: const Value(1),
              tagsUpdated: const Value({'3': true}),
            ),
          );

      final revoked = ThreadRow(
        id: threadId,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        priorityId: Uuid.generate(),
        draft: false,
        unread: false,
        importance: 0,
        active: false,
        hasEmbedding: false,
        revoked: true,
        statePending: false,
      );

      final processed = await ThreadsBase().processPulledRows(store, [revoked]);

      expect(processed, isEmpty); // revoked row excluded from upsert batch

      final thread = await (store.select(store.threads)
            ..where((t) => t.id.equals(threadId.toBytes())))
          .getSingleOrNull();
      expect(thread, isNull); // thread hard-deleted

      final note = await (store.select(store.notes)
            ..where((n) => n.id.equals(noteId.toBytes())))
          .getSingleOrNull();
      expect(note, isNull); // note hard-deleted

      final noteTags = await (store.select(store.noteTags)
            ..where((nt) => nt.id.equals(noteId.toBytes())))
          .getSingleOrNull();
      expect(
        noteTags,
        isNull,
        reason: 'orphaned note_tags rows would re-push to a revoked priority '
            'forever and spam error tracking',
      );
    },
  );
}
