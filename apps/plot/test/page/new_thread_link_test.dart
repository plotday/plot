import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/new_thread.dart';
import 'package:plot/store/store.dart';

void main() {
  Note emptyNote() => Note(
        id: Uuid.generate(),
        threadId: Uuid.generate(),
        authorId: ActorId.fromUuid(Uuid.generate()),
        draft: true,
        createdAt: DateTime(2026),
        sourceCreatedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  group('appendExternalLink', () {
    test('adds an ExternalUserAction with title/favicon', () {
      final note = appendExternalLink(
        emptyNote(),
        url: 'https://x.com/a',
        title: 'Hello',
        favicon: 'https://x.com/favicon.ico',
      );
      final actions = note.actions ?? const <UserAction>[];
      expect(actions.length, 1);
      final a = actions.first as ExternalUserAction;
      expect(a.url, 'https://x.com/a');
      expect(a.title, 'Hello');
      expect(a.favicon, 'https://x.com/favicon.ico');
    });

    test('falls back to url as title when none given', () {
      final note = appendExternalLink(emptyNote(), url: 'https://x.com/a');
      expect((note.actions!.first as ExternalUserAction).title, 'https://x.com/a');
    });

    test('is idempotent for the same url (dedup)', () {
      var note = appendExternalLink(emptyNote(), url: 'https://x.com/a');
      note = appendExternalLink(note, url: 'https://x.com/a', title: 'New');
      expect(note.actions!.whereType<ExternalUserAction>().length, 1);
    });
  });
}
