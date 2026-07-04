import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

void main() {
  // Note.draft reads Base.actorId for the author, so a minimal Base must be
  // registered for the test environment.
  setUp(() {
    Base.initForTesting(_selfId);
  });

  tearDown(() {
    Base.removeForTesting();
  });

  test('fwdNoteId round-trips through copyWith', () {
    final source = NoteId.generate();
    final note = Note.draft(threadId: ThreadId.generate());
    expect(note.fwdNoteId, isNull);

    final forwarded = note.copyWith(fwdNoteId: source);
    expect(forwarded.fwdNoteId, source);

    // clearing works
    final cleared = forwarded.copyWith(clearFwdNoteId: true);
    expect(cleared.fwdNoteId, isNull);
  });

  // Sync-seam regression: the local Drift column is `fwdNoteId`, so
  // NoteRow.toJson()/fromJson() (Drift-generated) use the key `fwd_note_id`.
  // But the remote DB column, the user.note view, and the server's
  // POST /sync/notes handler all read/write `fwd_note` (no `_id`). Without
  // NotesBase remapping the key on the way in/out, a forwarded note's pointer
  // is sent as `fwd_note_id`, the server always reads `body.fwd_note` as
  // undefined, and the forward snapshot never materializes server-side.
  test('toBase serializes fwdNoteId under the wire key `fwd_note`, not '
      '`fwd_note_id`', () {
    final source = NoteId.generate();
    final note = Note.draft(
      threadId: ThreadId.generate(),
    ).copyWith(fwdNoteId: source);
    final row = note.toRow();

    final payload = NotesBase().toBase(row);

    expect(
      payload['fwd_note'],
      source.toString(),
      reason: 'the wire payload must carry the forward pointer as fwd_note '
          'so the server (which reads body.fwd_note) actually sees it',
    );
    expect(
      payload.containsKey('fwd_note_id'),
      isFalse,
      reason: 'fwd_note_id is a local-only Drift column name and must never '
          'reach the wire',
    );
  });

  test('fromBase maps the wire key `fwd_note` back onto the local '
      'fwdNoteId column', () {
    final source = NoteId.generate();
    final note = Note.draft(
      threadId: ThreadId.generate(),
    ).copyWith(fwdNoteId: source);
    final row = note.toRow();

    // Simulate a pulled server payload: start from the Drift-generated JSON
    // (which would key this `fwd_note_id`) and rewrite it to the server's
    // actual wire key, `fwd_note`.
    final wireJson = row.toJson();
    wireJson['fwd_note'] = wireJson.remove('fwd_note_id');

    final result = NotesBase().fromBase(wireJson) as NoteRow;

    expect(
      result.fwdNoteId,
      source,
      reason: 'a pulled fwd_note must land in the local fwdNoteId column',
    );
  });
}
