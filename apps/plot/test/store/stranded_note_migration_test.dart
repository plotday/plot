import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// v364 recovery: a published note (draft=false) whose parent thread is still a
/// local draft (draft=true) can never sync — the draft thread is excluded from
/// push, so it has no server-side thread_priority and POST /sync/notes 403s
/// forever. The upgrade honors the user's publish intent by promoting such a
/// parent thread to draft=false (so it and the note sync), but only when the
/// thread is valid (non-archived, has a focus). For threads that can't be
/// promoted, the stranded note is demoted back to draft so it stops looping.
/// Normal in-progress drafts (a draft thread with only draft notes) are left
/// untouched.
///
/// We build the current schema, roll `user_version` back to 363, seed the
/// states, then reopen so `onUpgrade` runs the `from < 364` step.
void main() {
  test('v364 upgrade recovers published notes stranded on draft threads',
      () async {
    final raw = sqlite3.openInMemory();
    final seed = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );

    final priorityId = Uuid.generate();
    final author = ActorId(Uuid.generate());

    // Case 1 — STRANDED: draft thread + published note -> promote thread.
    final strandedThread = Uuid.generate();
    final strandedNote = Uuid.generate();
    // Case 2 — normal in-progress draft (only a draft note) -> untouched.
    final draftThread = Uuid.generate();
    final draftNote = Uuid.generate();
    // Case 3 — archived draft thread + published note -> can't promote,
    // demote the note.
    final archivedThread = Uuid.generate();
    final archivedThreadNote = Uuid.generate();

    Future<void> insertThread(Uuid id,
        {required bool draft, DateTime? archivedAt}) async {
      await seed.into(seed.threads).insert(
            ThreadsCompanion.insert(
              id: Value(id),
              priorityId: priorityId,
              draft: Value(draft),
              archivedAt: Value(archivedAt),
            ),
          );
    }

    Future<void> insertNote(Uuid id, Uuid threadId,
        {required bool draft}) async {
      await seed.into(seed.notes).insert(
            NotesCompanion.insert(
              id: Value(id),
              threadId: threadId,
              authorId: author,
              sourceCreatedAt: DateTime.now(),
              draft: Value(draft),
            ),
          );
    }

    await insertThread(strandedThread, draft: true);
    await insertNote(strandedNote, strandedThread, draft: false);
    await insertThread(draftThread, draft: true);
    await insertNote(draftNote, draftThread, draft: true);
    await insertThread(archivedThread, draft: true, archivedAt: DateTime.now());
    await insertNote(archivedThreadNote, archivedThread, draft: false);
    await seed.close();

    // Roll back so the from<364 step runs on reopen.
    raw.execute('PRAGMA user_version = 363');

    final upgraded = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );

    Future<ThreadRow> thread(Uuid id) =>
        (upgraded.select(upgraded.threads)..where((t) => t.id.equals(id.toBytes())))
            .getSingle();
    Future<NoteRow> note(Uuid id) =>
        (upgraded.select(upgraded.notes)..where((n) => n.id.equals(id.toBytes())))
            .getSingle();

    final promoted = await thread(strandedThread);
    expect(promoted.draft, isFalse, reason: 'stranded thread is promoted');
    expect(promoted.pending, 2, reason: 'promoted thread marked for push');
    expect((await note(strandedNote)).draft, isFalse,
        reason: 'published note kept published');

    final normalDraft = await thread(draftThread);
    expect(normalDraft.draft, isTrue, reason: 'normal draft thread untouched');
    expect((await note(draftNote)).draft, isTrue,
        reason: 'normal draft note untouched');

    final archived = await thread(archivedThread);
    expect(archived.draft, isTrue, reason: 'archived thread not promoted');
    expect((await note(archivedThreadNote)).draft, isTrue,
        reason: 'note on unpromotable thread demoted to draft');

    await upgraded.close();
    raw.close();
  });
}
