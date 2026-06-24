import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/store/store.dart';

final _self = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _threadId = ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
final _noteId = NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd');

Future<void> _insertNote(
  Store store, {
  NoteId? id,
  bool draft = false,
  int? pending = 2,
  String content = 'hello',
}) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(id ?? _noteId),
          threadId: Value(_threadId),
          authorId: Value(_self),
          draft: Value(draft),
          content: Value(content),
          createdAt: Value(DateTime(2026)),
          sourceCreatedAt: Value(DateTime(2026)),
          updatedAt: Value(DateTime(2026)),
          pending: Value(pending),
        ),
      );
}

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();
  });

  tearDown(() async {
    await PendingSend.instance.undo();
    Store.pushHeldNoteIds.clear();
    Store.pushHeldThreadIds.clear();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('window is 5 seconds', () {
    expect(PendingSend.window, const Duration(seconds: 5));
  });

  test('start makes it pending and exposes the ids', () {
    PendingSend.instance.start(noteId: _noteId, threadId: _threadId);
    expect(PendingSend.instance.isPending, isTrue);
    expect(PendingSend.instance.pendingNoteId, _noteId);
    expect(PendingSend.instance.pendingThreadId, _threadId);
    expect(PendingSend.instance.promotedThreadFromDraft, isFalse);
  });

  test('start holds the note id from the push claim, using a hex that matches '
      'the stored blob', () async {
    // A real, non-draft, pending note that would otherwise be pushed.
    await _insertNote(store);
    PendingSend.instance.start(noteId: _noteId, threadId: _threadId);

    // The held id is in the registry, and its hex matches the row's id blob.
    final held = Store.pushHeldNoteIds.map((h) => "x'$h'").join(', ');
    final inHold = await store
        .customSelect(
          'SELECT count(*) AS c FROM notes WHERE pending IS NOT NULL '
          'AND id IN ($held)',
        )
        .getSingle();
    expect(inHold.read<int>('c'), 1, reason: 'held hex must match the id blob');

    // The push claim (pending rows minus held rows) excludes the note.
    final claimable = await store
        .customSelect(
          'SELECT count(*) AS c FROM notes WHERE pending IS NOT NULL '
          'AND id NOT IN ($held)',
        )
        .getSingle();
    expect(claimable.read<int>('c'), 0, reason: 'held note must not be pushed');
  });

  test('commit releases the hold and stops being pending', () async {
    await _insertNote(store);
    PendingSend.instance.start(noteId: _noteId, threadId: _threadId);
    expect(Store.pushHeldNoteIds, isNotEmpty);

    await PendingSend.instance.commit();

    expect(PendingSend.instance.isPending, isFalse);
    expect(Store.pushHeldNoteIds, isEmpty);
    // The note row itself is untouched by commit — it stays a real, non-draft
    // note; commit just lets it sync.
    final row = await (store.select(store.notes)
          ..where((n) => n.id.equals(_noteId.toBytes())))
        .getSingle();
    expect(row.draft, isFalse);
    expect(row.archivedAt, isNull);
  });

  test('undo hides the never-pushed note (draft + archived) and releases the '
      'hold, returning the note', () async {
    await _insertNote(store, content: 'draft text');
    PendingSend.instance.start(noteId: _noteId, threadId: _threadId);

    final returned = await PendingSend.instance.undo();

    expect(returned?.content, 'draft text');
    expect(PendingSend.instance.isPending, isFalse);
    expect(Store.pushHeldNoteIds, isEmpty);
    final row = await (store.select(store.notes)
          ..where((n) => n.id.equals(_noteId.toBytes())))
        .getSingle();
    expect(row.draft, isTrue, reason: 'undone note leaves the notes list');
    expect(row.archivedAt, isNotNull,
        reason: 'undone note never resurfaces as a draft');
  });

  test('start commits a prior pending send (one at a time)', () async {
    final firstId = NoteId.fromString('11111111-1111-1111-1111-111111111111');
    final secondId = NoteId.fromString('22222222-2222-2222-2222-222222222222');
    await _insertNote(store, id: firstId);
    await _insertNote(store, id: secondId);

    PendingSend.instance.start(noteId: firstId, threadId: _threadId);
    PendingSend.instance.start(noteId: secondId, threadId: _threadId);

    // The first was committed (hold released); only the second is held.
    expect(PendingSend.instance.pendingNoteId, secondId);
    expect(Store.pushHeldNoteIds, contains(secondId.toBytes()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()));
    expect(Store.pushHeldNoteIds.length, 1);
  });

  test('flush() with nothing pending is a no-op', () async {
    expect(PendingSend.instance.isPending, isFalse);
    await PendingSend.instance.flush();
    expect(PendingSend.instance.isPending, isFalse);
  });

  test('flush() commits a pending send (releases the hold)', () async {
    await _insertNote(store);
    PendingSend.instance.start(noteId: _noteId, threadId: _threadId);
    expect(PendingSend.instance.isPending, isTrue);
    await PendingSend.instance.flush();
    expect(PendingSend.instance.isPending, isFalse);
    expect(Store.pushHeldNoteIds, isEmpty);
  });
}
