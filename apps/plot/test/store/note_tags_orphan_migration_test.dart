import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// The v376 upgrade runs a one-time cleanup for the access-loss strand fixed in
/// `Thread._hardDeleteRevokedThreads`: revoking a thread used to hard-delete its
/// notes but leave their `note_tags` rows (keyed by note id) behind. An orphaned
/// note_tags row keeps its `pending` bit, so the sync loop re-pushed it to
/// /sync/note-tags/update forever — the server rejected each push with
/// 422 "User does not have access to this priority". The cleanup purges
/// note_tags rows that still carry a pending push but whose note no longer
/// exists locally. Live note_tags rows (note present) and stale-but-not-pending
/// orphans must survive.
///
/// v376 adds no columns, so we build the current schema, roll `user_version`
/// back to 375, seed the rows, then reopen so `onUpgrade` runs the `from < 376`
/// step.
void main() {
  test(
    'v376 upgrade purges pending orphan note_tags, keeps live + non-pending',
    () async {
      final raw = sqlite3.openInMemory();

      // 1. Build current schema (onCreate).
      final seed = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );

      final threadId = Uuid.generate();
      final liveNoteId = Uuid.generate(); // note exists locally
      final orphanPendingId = Uuid.generate(); // no note + pending → purged
      final orphanStaleId = Uuid.generate(); // no note, no pending → survives

      await seed.into(seed.notes).insert(
            NotesCompanion.insert(
              id: Value(liveNoteId),
              threadId: threadId,
              authorId: ActorId(Uuid.generate()),
              sourceCreatedAt: DateTime(2026, 1, 1),
            ),
          );
      // Live: pending tag edit on a note that still exists → must survive.
      await seed.into(seed.noteTags).insert(
            NoteTagsCompanion.insert(
              id: Value(liveNoteId),
              pending: const Value(1),
              tagsUpdated: const Value({'3': true}),
            ),
          );
      // Orphan with a pending push and no local note → the strand → purged.
      await seed.into(seed.noteTags).insert(
            NoteTagsCompanion.insert(
              id: Value(orphanPendingId),
              pending: const Value(1),
              tagsUpdated: const Value({'3': true}),
            ),
          );
      // Orphan with no pending push (stale synced display state, `pending`
      // NULL) → survives; it never re-pushes, so it isn't the spam we clear.
      await seed.into(seed.noteTags).insert(
            NoteTagsCompanion.insert(
              id: Value(orphanStaleId),
            ),
          );
      await seed.close();

      // 2. Roll back to v375 (v376 changed no columns).
      raw.execute('PRAGMA user_version = 375');

      // 3. Reopen → onUpgrade runs the from<376 step.
      final upgraded = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );

      Future<bool> exists(Uuid id) async =>
          (await (upgraded.select(upgraded.noteTags)
                    ..where((nt) => nt.id.equals(id.toBytes())))
                  .getSingleOrNull()) !=
              null;

      expect(await exists(liveNoteId), isTrue, reason: 'live note_tags survive');
      expect(
        await exists(orphanPendingId),
        isFalse,
        reason: 'pending orphan note_tags purged',
      );
      expect(
        await exists(orphanStaleId),
        isTrue,
        reason: 'non-pending orphan note_tags left alone',
      );

      await upgraded.close();
      raw.close();
    },
  );
}
