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

  group('messageReplyAudienceBase', () {
    // Resolves the candidate recipients (and group count) behind the
    // "Reply all (N)" badge for a message-mode thread. The badge total is
    // derived from this base with self filtered out.
    final selfU = Uuid.generate();
    final otherA = Uuid.generate();
    final otherB = Uuid.generate();

    test('an explicit draft recipient subset drives the audience live — the '
        'badge updates when recipients are edited, before send', () {
      // Regression: the badge count used to come only from the last *sent*
      // note's audience, so editing recipients to add a second person left the
      // "Reply all" badge absent until after the reply was sent.
      final base = messageReplyAudienceBase(
        draftAccessContacts: [selfU, otherA, otherB],
        draftAccessGroups: const [],
        latestNoteAudience: {selfU, otherA}, // last note reached only one other
        threadActiveContacts: [selfU, otherA],
        threadGroupCount: 0,
      );
      expect(base.contacts, containsAll(<Uuid>[selfU, otherA, otherB]));
      expect(base.contacts.length, 3);
      expect(base.groupCount, 0);
    });

    test('no draft narrowing falls back to the latest note audience and '
        'thread group count', () {
      final base = messageReplyAudienceBase(
        draftAccessContacts: null,
        draftAccessGroups: null,
        latestNoteAudience: {selfU, otherA, otherB},
        threadActiveContacts: [selfU],
        threadGroupCount: 5,
      );
      expect(base.contacts, containsAll(<Uuid>[selfU, otherA, otherB]));
      expect(base.contacts.length, 3);
      expect(base.groupCount, 5);
    });

    test('no draft narrowing and no notes falls back to thread active contacts',
        () {
      final base = messageReplyAudienceBase(
        draftAccessContacts: null,
        draftAccessGroups: null,
        latestNoteAudience: const {},
        threadActiveContacts: [selfU, otherA],
        threadGroupCount: 0,
      );
      expect(base.contacts, [selfU, otherA]);
      expect(base.groupCount, 0);
    });

    test('a draft narrowed to a group subset uses the draft group count, not '
        'the thread default', () {
      final group = Uuid.generate();
      final base = messageReplyAudienceBase(
        draftAccessContacts: null,
        draftAccessGroups: [group],
        latestNoteAudience: {selfU, otherA, otherB},
        threadActiveContacts: [selfU],
        threadGroupCount: 9,
      );
      expect(base.contacts, isEmpty);
      expect(base.groupCount, 1);
    });
  });

  group('reserveEmptyTopBar', () {
    // The composer holds an empty, height-reserving placeholder bar only while
    // a *shared* thread's links load — a shared thread always resolves to a
    // bar, so reserving height avoids the plain-Plot→connector pill flash and a
    // layout shift. An unshared thread resolves to no bar, so a placeholder
    // there would flash a one-frame empty strip that then collapses (the
    // private-thread bug).

    test('unshared thread, links loading: no placeholder (the private-thread '
        'flash this guards against)', () {
      expect(
        reserveEmptyTopBar(linksLoaded: false, hasSharing: false),
        isFalse,
      );
    });

    test('shared thread, links loading: hold the placeholder', () {
      expect(
        reserveEmptyTopBar(linksLoaded: false, hasSharing: true),
        isTrue,
      );
    });

    test('links loaded: never a placeholder, regardless of sharing', () {
      expect(reserveEmptyTopBar(linksLoaded: true, hasSharing: false), isFalse);
      expect(reserveEmptyTopBar(linksLoaded: true, hasSharing: true), isFalse);
    });
  });

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
