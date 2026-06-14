import 'package:flutter_test/flutter_test.dart';

import 'package:plot/base.dart';
import 'package:plot/util/uuid.dart';
import 'package:plot/widget/note_editor.dart';

void main() {
  // Resolves the active message-sharing reply pill from a draft's recipient
  // subset. These are the inputs `_activePillId` feeds in for a Gmail-style
  // (SharingModel.message) thread: the draft's accessContacts/accessGroups, the
  // current user's id, and the distinct original author (null when the
  // "Reply to [original]" pill isn't shown).
  final self = ActorId.fromUuid(Uuid.generate());
  final original = ActorId.fromUuid(Uuid.generate());
  final other = ActorId.fromUuid(Uuid.generate());

  group('messageReplyPillId', () {
    test('draft narrowed to self + original resolves to the replyOriginal pill',
        () {
      // Tapping "Reply to [original]" sets accessContacts to [self, original]
      // (see _activateReplyToOriginal). The highlight must follow it there.
      expect(
        messageReplyPillId(
          draftAccessContacts: [self, original],
          draftAccessGroups: const [],
          selfId: self,
          originalAuthorId: original,
        ),
        'replyOriginal',
      );
    });

    test('recipient order does not matter (set comparison)', () {
      expect(
        messageReplyPillId(
          draftAccessContacts: [original, self],
          draftAccessGroups: const [],
          selfId: self,
          originalAuthorId: original,
        ),
        'replyOriginal',
      );
    });

    test('thread-default draft (null recipients) resolves to the reply pill',
        () {
      expect(
        messageReplyPillId(
          draftAccessContacts: null,
          draftAccessGroups: null,
          selfId: self,
          originalAuthorId: original,
        ),
        'reply',
      );
    });

    test('reply to a broader audience resolves to the reply pill', () {
      expect(
        messageReplyPillId(
          draftAccessContacts: [self, original, other],
          draftAccessGroups: const [],
          selfId: self,
          originalAuthorId: original,
        ),
        'reply',
      );
    });

    test('no distinct original author always resolves to the reply pill', () {
      expect(
        messageReplyPillId(
          draftAccessContacts: [self, other],
          draftAccessGroups: const [],
          selfId: self,
          originalAuthorId: null,
        ),
        'reply',
      );
    });

    test('a narrowed reply that also targets a group is not reply-to-original',
        () {
      final group = ActorId.fromUuid(Uuid.generate());
      expect(
        messageReplyPillId(
          draftAccessContacts: [self, original],
          draftAccessGroups: [group],
          selfId: self,
          originalAuthorId: original,
        ),
        'reply',
      );
    });
  });
}
