import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Helpers to build [Note] instances for testing without a live Drift
/// database.  All fields use fixed, recognisable UUIDs.
final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _aliceId = ActorId.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
final _groupId = ActorId.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');

Note _note({
  List<ActorId>? accessContacts,
  List<ActorId>? accessGroups,
}) {
  return Note(
    id: NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd'),
    threadId: ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'),
    authorId: _selfId,
    draft: false,
    accessContacts: accessContacts,
    accessGroups: accessGroups,
    createdAt: DateTime(2024),
    sourceCreatedAt: DateTime(2024),
    updatedAt: DateTime(2024),
  );
}

void main() {
  group('Note.isPrivate', () {
    test('accessContacts=null, accessGroups=null → not private', () {
      final note = _note();
      expect(note.isPrivate, isFalse);
    });

    test('accessContacts=[self], accessGroups=null → private', () {
      final note = _note(accessContacts: [_selfId]);
      expect(note.isPrivate, isTrue);
    });

    test('accessContacts=[self], accessGroups=[] → private', () {
      final note = _note(accessContacts: [_selfId], accessGroups: []);
      expect(note.isPrivate, isTrue);
    });

    test(
        'accessContacts=[self], accessGroups=[groupId] → NOT private (custom subset includes group)',
        () {
      final note = _note(accessContacts: [_selfId], accessGroups: [_groupId]);
      expect(note.isPrivate, isFalse);
    });

    test(
        'accessContacts=[self, alice], accessGroups=null → NOT private (custom subset, not the Private-pill state)',
        () {
      // isPrivate is specifically the "Private pill active" state: exactly
      // [authorId] with no groups.  A custom subset like [self, alice] is a
      // custom-recipients note, not a private note.
      final note = _note(accessContacts: [_selfId, _aliceId]);
      expect(note.isPrivate, isFalse);
    });

    test(
        'accessContacts=[alice] (not self), accessGroups=null → NOT private (author not the sole contact)',
        () {
      final note = _note(accessContacts: [_aliceId]);
      expect(note.isPrivate, isFalse);
    });
  });

  group('Note.isAuthorOnly', () {
    test('accessContacts=null → not author-only', () {
      final note = _note();
      expect(note.isAuthorOnly, isFalse);
    });

    test('accessContacts=[], accessGroups=null → author-only', () {
      final note = _note(accessContacts: []);
      expect(note.isAuthorOnly, isTrue);
    });

    test('accessContacts=[], accessGroups=[] → author-only', () {
      final note = _note(accessContacts: [], accessGroups: []);
      expect(note.isAuthorOnly, isTrue);
    });

    test(
        'accessContacts=[], accessGroups=[groupId] → NOT author-only (group can see it)',
        () {
      final note = _note(accessContacts: [], accessGroups: [_groupId]);
      expect(note.isAuthorOnly, isFalse);
    });

    test('accessContacts=[self], accessGroups=null → not author-only (self can see it)',
        () {
      final note = _note(accessContacts: [_selfId]);
      expect(note.isAuthorOnly, isFalse);
    });
  });

  group('Note.accessGroups field', () {
    test('null by default', () {
      final note = _note();
      expect(note.accessGroups, isNull);
    });

    test('preserved through copyWith when absent', () {
      final note = _note(accessGroups: [_groupId]);
      final copy = note.copyWith();
      expect(copy.accessGroups, equals([_groupId]));
    });

    test('overridable via copyWith', () {
      final note = _note(accessGroups: [_groupId]);
      final copy = note.copyWith(accessGroups: const Value(null));
      expect(copy.accessGroups, isNull);
    });
  });
}
