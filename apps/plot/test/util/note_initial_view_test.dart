import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/note_initial_view.dart';

Note _note(DateTime sourceCreatedAt) => Note(
  id: Uuid.generate(),
  threadId: Uuid.generate(),
  authorId: ActorId(Uuid.generate()),
  draft: false,
  createdAt: sourceCreatedAt,
  sourceCreatedAt: sourceCreatedAt,
  updatedAt: sourceCreatedAt,
);

void main() {
  final t1 = DateTime(2026, 1, 1, 9);
  final t2 = DateTime(2026, 1, 1, 10);
  final t3 = DateTime(2026, 1, 1, 11);

  group('noteIsUnread', () {
    test('read thread (unread flag false) has no unread notes', () {
      expect(
        noteIsUnread(_note(t3), threadUnread: false, readAt: t1),
        isFalse,
      );
    });

    test('null readAt with unread thread treats note as unread', () {
      expect(
        noteIsUnread(_note(t1), threadUnread: true, readAt: null),
        isTrue,
      );
    });

    test('note after readAt is unread; at-or-before is read', () {
      expect(noteIsUnread(_note(t3), threadUnread: true, readAt: t2), isTrue);
      expect(noteIsUnread(_note(t2), threadUnread: true, readAt: t2), isFalse);
      expect(noteIsUnread(_note(t1), threadUnread: true, readAt: t2), isFalse);
    });
  });

  group('noteInitiallyExpanded', () {
    test('single note always expanded, even when read', () {
      expect(
        noteInitiallyExpanded(
          _note(t1),
          noteCount: 1,
          threadUnread: false,
          readAt: t3,
        ),
        isTrue,
      );
    });

    test('multiple notes: unread expands, read collapses', () {
      expect(
        noteInitiallyExpanded(
          _note(t3),
          noteCount: 3,
          threadUnread: true,
          readAt: t2,
        ),
        isTrue,
      );
      expect(
        noteInitiallyExpanded(
          _note(t1),
          noteCount: 3,
          threadUnread: true,
          readAt: t2,
        ),
        isFalse,
      );
    });
  });

  group('initialScrollTargetIndex', () {
    test('empty list -> null', () {
      expect(
        initialScrollTargetIndex([], threadUnread: true, readAt: null),
        isNull,
      );
    });

    test('single note -> index 0', () {
      expect(
        initialScrollTargetIndex(
          [_note(t1)],
          threadUnread: false,
          readAt: t3,
        ),
        0,
      );
    });

    test('multiple with unread -> oldest unread (min sourceCreatedAt)', () {
      // notes in arbitrary order; t2 and t3 are unread (readAt = t1).
      final notes = [_note(t3), _note(t1), _note(t2)];
      // Oldest unread is t2, at index 2.
      expect(
        initialScrollTargetIndex(notes, threadUnread: true, readAt: t1),
        2,
      );
    });

    test('multiple, none unread -> null', () {
      final notes = [_note(t1), _note(t2), _note(t3)];
      expect(
        initialScrollTargetIndex(notes, threadUnread: false, readAt: t1),
        isNull,
      );
    });
  });
}
