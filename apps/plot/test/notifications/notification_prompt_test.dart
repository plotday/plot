import 'package:flutter_test/flutter_test.dart';

import 'package:plot/notifications/notification_prompt.dart';

void main() {
  group('notificationPromptStateKey', () {
    test('is namespaced per user', () {
      expect(notificationPromptStateKey('u1'), 'notif_prompt_state:u1');
    });
  });

  group('parse/serialize round-trip', () {
    test('each state survives a round-trip', () {
      for (final s in NotificationPromptState.values) {
        expect(
          parseNotificationPromptState(serializeNotificationPromptState(s)),
          s,
        );
      }
    });

    test('null / unknown parses to unset', () {
      expect(parseNotificationPromptState(null), NotificationPromptState.unset);
      expect(
        parseNotificationPromptState('garbage'),
        NotificationPromptState.unset,
      );
    });
  });

  group('decidePromptAction', () {
    test('granted → none regardless of stored state', () {
      for (final s in NotificationPromptState.values) {
        expect(
          decidePromptAction(osGranted: true, state: s),
          NotificationPromptAction.none,
        );
      }
    });

    test('not granted + unset → showPriming', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.unset,
        ),
        NotificationPromptAction.showPriming,
      );
    });

    test('not granted + optedIn → showReEnable (had it, lost it)', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.optedIn,
        ),
        NotificationPromptAction.showReEnable,
      );
    });

    test('not granted + declined → none (respect opt-out)', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.declined,
        ),
        NotificationPromptAction.none,
      );
    });
  });

  group('mapRequestOutcome', () {
    test('granted → granted', () {
      expect(
        mapRequestOutcome(granted: true, wasFirstAsk: true),
        NotificationPromptOutcome.granted,
      );
      expect(
        mapRequestOutcome(granted: true, wasFirstAsk: false),
        NotificationPromptOutcome.granted,
      );
    });

    test('denied on first ask → declined', () {
      expect(
        mapRequestOutcome(granted: false, wasFirstAsk: true),
        NotificationPromptOutcome.declined,
      );
    });

    test('denied after a prior ask → openSettings', () {
      expect(
        mapRequestOutcome(granted: false, wasFirstAsk: false),
        NotificationPromptOutcome.openSettings,
      );
    });
  });
}
