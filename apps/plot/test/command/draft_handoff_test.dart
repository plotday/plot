import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/twist.dart';

void main() {
  group('shouldOpenChannelSetupAfterConnect', () {
    test('OAuth connector (has providers) → open channel setup on the draft', () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: true,
          completedInSetupModal: false,
        ),
        isTrue,
      );
    });

    test('no draft id (user backed out before connecting) → do not open setup',
        () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: null,
          hasProviders: true,
          completedInSetupModal: false,
        ),
        isFalse,
      );
    });

    test('no providers (non-OAuth connector) → do not open OAuth channel setup',
        () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: false,
          completedInSetupModal: false,
        ),
        isFalse,
      );
    });

    test('completed inside the setup modal (no-provider) → do not re-open', () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: false,
          completedInSetupModal: true,
        ),
        isFalse,
      );
    });

    test('OAuth connector that completed in the setup modal → do not re-open',
        () {
      // The only path where completedInSetupModal actually gates the result
      // (hasProviders is true, so it is not short-circuited by the no-provider
      // check).
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: true,
          completedInSetupModal: true,
        ),
        isFalse,
      );
    });
  });
}
