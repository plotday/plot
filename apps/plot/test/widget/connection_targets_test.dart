import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart' show CreateLinkUserAction;
import 'package:plot/widget/connection_targets.dart' show createLinkActionKey;

void main() {
  group('createLinkActionKey', () {
    test('channel-type form is twist|channel|linkType', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw1',
        channelId: 'ch1',
        linkType: 'thread',
        status: 'open',
        connectorName: 'Slack',
        linkTypeLabel: 'Message',
        channelName: 'general',
        dmTargets: 'channels',
      );
      expect(createLinkActionKey(action), 'tw1|ch1|thread');
    });

    test('DM-type form is twist||linkType|targets (no |null|)', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw1',
        channelId: null,
        linkType: 'dm',
        status: 'open',
        connectorName: 'Slack',
        linkTypeLabel: 'Direct message',
        channelName: 'Slack: Acme',
        dmTargets: 'contacts',
      );
      expect(createLinkActionKey(action), 'tw1||dm|contacts');
    });

    test('addresses-type is treated as DM form', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw2',
        channelId: null,
        linkType: 'email',
        status: 'open',
        connectorName: 'Gmail',
        linkTypeLabel: 'Email',
        channelName: 'Gmail',
        dmTargets: 'addresses',
      );
      expect(createLinkActionKey(action), 'tw2||email|addresses');
    });
  });
}
