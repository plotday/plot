import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

final _noteId = NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd');
final _threadId = ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
final _self = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

Future<void> _insertNote(Store store, {required bool draft}) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(_noteId),
          threadId: Value(_threadId),
          authorId: Value(_self),
          draft: Value(draft),
          content: const Value('hi'),
          createdAt: Value(DateTime(2026)),
          sourceCreatedAt: Value(DateTime(2026)),
          updatedAt: Value(DateTime(2026)),
          pending: const Value(2),
        ),
      );
}

Future<void> _insertReaction(Store store) async {
  await store.into(store.noteReactions).insert(
        NoteReactionsCompanion(
          id: Value(_noteId),
          pending: const Value(2),
        ),
      );
}

/// Count of note_reactions rows the push claim would send, applying the
/// draft filter exactly as `Store.push` does.
Future<int> _claimable(Store store) async {
  final filter = Store.buildDraftFilter(store.noteReactions);
  final row = await store
      .customSelect(
        'SELECT count(*) AS c FROM note_reactions '
        'WHERE pending IS NOT NULL $filter',
      )
      .getSingle();
  return row.read<int>('c');
}

void main() {
  late Store store;

  setUp(() => store = Store.forTesting(NativeDatabase.memory()));
  tearDown(() async => store.close());

  test('a draft note\'s reaction is excluded from the push claim', () async {
    await _insertNote(store, draft: true);
    await _insertReaction(store);
    expect(await _claimable(store), 0,
        reason: 'reaction on a draft note must not push (would 404)');
  });

  test('a published note\'s reaction stays claimable', () async {
    await _insertNote(store, draft: false);
    await _insertReaction(store);
    expect(await _claimable(store), 1,
        reason: 'reaction on a real note must still sync');
  });
}
