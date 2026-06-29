import 'package:flutter_test/flutter_test.dart';

import 'package:plot/widget/note_editor.dart';

void main() {
  // Decides whether NoteEditor.didUpdateWidget resets the SuperEditor when the
  // draft note id changes. The composer is cleared after a send via a
  // "clear after send" flag rather than the content proxy, because an
  // interleaved ThreadBloc emit (the notes-watch firing when the just-sent note
  // is saved) can rebuild the editor with the OLD draft id and reset the
  // content proxy to '' before the fresh empty draft arrives — defeating the
  // proxy gate and stranding the just-sent reply on screen.
  group('shouldResetComposerOnDraftChange', () {
    test('after a send, clears the composer even when the saved-content proxy '
        'is stale-empty (the interleaved-emit race that stranded a sent reply)',
        () {
      // The clobbering emit reset lastSavedContent to '' before the fresh empty
      // draft arrived. The old content-proxy gate ('' == '') skipped the reset
      // and left the sent reply on screen. A send flag survives the same-id
      // emit, so the reset still fires.
      expect(
        shouldResetComposerOnDraftChange(
          draftIdChanged: true,
          clearAfterSendPending: true,
          incomingContent: '',
          lastSavedContent: '',
        ),
        isTrue,
      );
    });

    test('never resets when the draft id is unchanged (same-id content emits '
        'must not disturb the editor)', () {
      expect(
        shouldResetComposerOnDraftChange(
          draftIdChanged: false,
          clearAfterSendPending: true,
          incomingContent: '',
          lastSavedContent: 'a reply in progress',
        ),
        isFalse,
      );
    });

    test('a background draft reload with unchanged content does not reset '
        '(flicker guard preserved)', () {
      // During initial load the draft note is rebuilt several times, minting a
      // fresh id for the same content. Resetting each time flickers the editor.
      expect(
        shouldResetComposerOnDraftChange(
          draftIdChanged: true,
          clearAfterSendPending: false,
          incomingContent: 'same content',
          lastSavedContent: 'same content',
        ),
        isFalse,
      );
    });

    test('a draft change with genuinely new content resets to that content',
        () {
      expect(
        shouldResetComposerOnDraftChange(
          draftIdChanged: true,
          clearAfterSendPending: false,
          incomingContent: 'loaded from store',
          lastSavedContent: '',
        ),
        isTrue,
      );
    });
  });
}
