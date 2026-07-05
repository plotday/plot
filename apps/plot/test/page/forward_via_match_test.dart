/// Tests [forwardLinkMatchesTarget] — the rule that defaults a forwarded
/// thread's compose "Via" to the connection the source note came from.
///
/// Regression: a received Gmail email link carries `channelId` "INBOX"/"SENT",
/// but Gmail's compose target is connection-scoped (`compose.targets:
/// addresses`) with a null channel. Requiring the channel to match made
/// "INBOX" != null, so Gmail never matched and the forward silently fell back
/// to plain Plot. Connection-scoped targets must ignore the source's channel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/new_thread.dart';

void main() {
  group('forwardLinkMatchesTarget', () {
    const gmailConn = 'gmail-connection-id';

    test('Gmail (connection-scoped) matches despite INBOX channel', () {
      expect(
        forwardLinkMatchesTarget(
          linkConnection: gmailConn,
          linkType: 'email',
          linkChannelId: 'INBOX',
          targetConnection: gmailConn,
          targetLinkType: 'email',
          targetIsChannelScoped: false, // addresses-mode Gmail target
          targetChannelId: null,
        ),
        isTrue,
      );
    });

    test('Gmail matches a SENT-channel source too', () {
      expect(
        forwardLinkMatchesTarget(
          linkConnection: gmailConn,
          linkType: 'email',
          linkChannelId: 'SENT',
          targetConnection: gmailConn,
          targetLinkType: 'email',
          targetIsChannelScoped: false,
          targetChannelId: null,
        ),
        isTrue,
      );
    });

    test('no match when the connection differs', () {
      expect(
        forwardLinkMatchesTarget(
          linkConnection: gmailConn,
          linkType: 'email',
          linkChannelId: 'INBOX',
          targetConnection: 'a-different-connection',
          targetLinkType: 'email',
          targetIsChannelScoped: false,
          targetChannelId: null,
        ),
        isFalse,
      );
    });

    test('no match when the link type differs', () {
      expect(
        forwardLinkMatchesTarget(
          linkConnection: gmailConn,
          linkType: 'email',
          linkChannelId: 'INBOX',
          targetConnection: gmailConn,
          targetLinkType: 'task',
          targetIsChannelScoped: false,
          targetChannelId: null,
        ),
        isFalse,
      );
    });

    group('channel-scoped targets (e.g. Slack channel) still require the channel',
        () {
      const slackConn = 'slack-connection-id';

      test('matches when the channel matches', () {
        expect(
          forwardLinkMatchesTarget(
            linkConnection: slackConn,
            linkType: 'thread',
            linkChannelId: 'C123',
            targetConnection: slackConn,
            targetLinkType: 'thread',
            targetIsChannelScoped: true,
            targetChannelId: 'C123',
          ),
          isTrue,
        );
      });

      test('no match when the channel differs', () {
        expect(
          forwardLinkMatchesTarget(
            linkConnection: slackConn,
            linkType: 'thread',
            linkChannelId: 'C123',
            targetConnection: slackConn,
            targetLinkType: 'thread',
            targetIsChannelScoped: true,
            targetChannelId: 'C999',
          ),
          isFalse,
        );
      });
    });
  });
}
