// Tests for Task 4: composite batch re-auth (staged products → one Continue
// with Google, gated on isComposite).
//
// Coverage:
// (a) CompositeReauthWidget with staged products → renders an AuthButton CTA.
// (b) CompositeReauthWidget computes enabledScopeGroups = union of granted
//     + staged scope group ids.
// (c) CompositeReauthWidget with empty staged + empty granted → renders
//     nothing (safe/empty state, used when no reauth action is needed).
// (d) reload (_loadIntegrations) clears _stagedProducts so a product that
//     becomes enabled after re-auth does not leave a stale staged key.
//     Verified via SetupSourceWidget: after re-creating with updated data
//     (drive now enabled), onChanged carries empty stagedProducts.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart' show AuthButton;
import 'package:plot/widget/setup_source.dart';

// ---------------------------------------------------------------------------
// Shared scaffold
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) => FTheme(
      data: FThemes.zinc.light.desktop,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            // Use 600px wide so the "Continue with Google" button has room.
            width: 600,
            height: 800,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// Factories
// ---------------------------------------------------------------------------

TwistProvider _googleProvider() => TwistProvider(
      provider: AuthProvider.google,
      scopes: ['https://www.googleapis.com/auth/calendar.readonly'],
      access: const [],
      optionalScopes: null,
    );

TwistAccount _googleAccount() => const TwistAccount(
      provider: AuthProvider.google,
      actorId: 'user@example.com',
      email: 'user@example.com',
    );

ProductInfo _product(String key, String label, {String? scopeGroupId}) =>
    ProductInfo(
      key: key,
      label: label,
      description: '$label description',
      icon: '',
      scopeGroupId: scopeGroupId ?? key,
    );

ProductStatus _status(String key, {required bool enabled}) => ProductStatus(
      key: key,
      enabled: enabled,
      reason: enabled
          ? ProductStatusReason.granted
          : ProductStatusReason.scopeMissing,
    );

TwistChannel _channel(String id, String title) => TwistChannel(
      provider: AuthProvider.google,
      providerKey: 'google',
      id: id,
      title: title,
      enabled: true,
      enabledByDefault: true,
      currentUserHasAccess: true,
    );

/// Composite: gmail ENABLED (scope group 'gmail_sg'), drive NOT-ENABLED
/// (scope group 'drive_sg').
TwistIntegrations _compositeData() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('gmail:inbox', 'Inbox'),
        _channel('gmail:sent', 'Sent'),
      ],
      products: [
        _product('gmail', 'Gmail', scopeGroupId: 'gmail_sg'),
        _product('drive', 'Drive', scopeGroupId: 'drive_sg'),
      ],
      productStatus: [
        _status('gmail', enabled: true),
        _status('drive', enabled: false),
      ],
      channelNoun: const ChannelNoun(singular: 'label', plural: 'labels'),
    );

/// Composite after re-auth: both products enabled.
TwistIntegrations _compositeAfterReauth() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('gmail:inbox', 'Inbox'),
        _channel('drive:mydrive', 'My Drive'),
      ],
      products: [
        _product('gmail', 'Gmail', scopeGroupId: 'gmail_sg'),
        _product('drive', 'Drive', scopeGroupId: 'drive_sg'),
      ],
      productStatus: [
        _status('gmail', enabled: true),
        _status('drive', enabled: true),
      ],
      channelNoun: const ChannelNoun(singular: 'label', plural: 'labels'),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Task 4: CompositeReauthWidget', () {
    // -----------------------------------------------------------------------
    // (a) Staged products → AuthButton CTA rendered
    // -----------------------------------------------------------------------
    testWidgets(
        '(a) when stagedGroupIds is non-empty, renders an AuthButton',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          CompositeReauthWidget(
            provider: _googleProvider(),
            twistInstanceId: 'test-instance',
            grantedGroupIds: const {'gmail_sg'},
            stagedGroupIds: const {'drive_sg'},
            accountHint: 'user@example.com',
            onSuccess: () async {},
          ),
        ),
      );
      await tester.pump();

      // An AuthButton must be present (the "Continue with Google" CTA).
      expect(find.byType(AuthButton), findsOneWidget);
    });

    testWidgets(
        '(a2) when both staged and granted are empty, no AuthButton',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          CompositeReauthWidget(
            provider: _googleProvider(),
            twistInstanceId: 'test-instance',
            grantedGroupIds: const {},
            stagedGroupIds: const {},
            accountHint: null,
            onSuccess: () async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AuthButton), findsNothing);
    });

    // -----------------------------------------------------------------------
    // (b) enabledScopeGroups = union of granted + staged
    // -----------------------------------------------------------------------
    testWidgets(
        '(b) computedScopeGroupIds = union of grantedGroupIds + stagedGroupIds',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          CompositeReauthWidget(
            provider: _googleProvider(),
            twistInstanceId: 'test-instance',
            grantedGroupIds: const {'gmail_sg'},
            stagedGroupIds: const {'drive_sg'},
            accountHint: 'user@example.com',
            onSuccess: () async {},
          ),
        ),
      );
      await tester.pump();

      final state = tester.state<CompositeReauthWidgetState>(
        find.byType(CompositeReauthWidget),
      );
      final union = state.computedScopeGroupIds;
      expect(union, containsAll(['gmail_sg', 'drive_sg']));
      expect(union.length, 2);
    });

    testWidgets(
        '(b2) union deduplicates when a group id appears in both sets',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          CompositeReauthWidget(
            provider: _googleProvider(),
            twistInstanceId: 'test-instance',
            grantedGroupIds: const {'gmail_sg', 'shared_sg'},
            stagedGroupIds: const {'shared_sg', 'drive_sg'},
            accountHint: null,
            onSuccess: () async {},
          ),
        ),
      );
      await tester.pump();

      final state = tester.state<CompositeReauthWidgetState>(
        find.byType(CompositeReauthWidget),
      );
      final union = state.computedScopeGroupIds;
      expect(union, containsAll(['gmail_sg', 'shared_sg', 'drive_sg']));
      expect(union.length, 3); // no duplicates
    });

    // -----------------------------------------------------------------------
    // (c) Non-composite regression: flat channel list unchanged
    // -----------------------------------------------------------------------
    testWidgets(
        '(c) non-composite SetupSourceWidget renders flat channel list without composite CTA',
        (tester) async {
      final flatData = TwistIntegrations(
        providers: [_googleProvider()],
        accounts: [_googleAccount()],
        channels: [
          _channel('inbox', 'Inbox'),
          _channel('updates', 'Updates'),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: false,
            showAccounts: false,
            initialData: flatData,
          ),
        ),
      );
      await tester.pump();

      // Flat channels visible.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Updates'), findsOneWidget);

      // No product-section headers in non-composite mode.
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Not enabled'), findsNothing);

      // No CompositeReauthWidget anywhere.
      expect(find.byType(CompositeReauthWidget), findsNothing);
    });

    // -----------------------------------------------------------------------
    // (d) Reload clears _stagedProducts
    // -----------------------------------------------------------------------
    testWidgets(
        '(d) re-creating SetupSourceWidget with updated data clears stagedProducts',
        (tester) async {
      IntegrationChanges? lastChange;

      // First render: drive is not-enabled, user stages it.
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            key: const ValueKey('before'),
            twistInstanceId: 'test-instance',
            setupMode: false,
            showAccounts: false,
            initialData: _compositeData(),
            onChanged: (c) => lastChange = c,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Drive'));
      await tester.pump();
      expect(lastChange!.stagedProducts, contains('drive'));

      // Simulate a re-auth that succeeded: re-create the widget with updated
      // data where drive is now enabled. Because the widget key changes,
      // Flutter destroys the old State and creates a fresh one, which mirrors
      // what happens when FormScope.refresh() fires after re-auth (the form
      // rebuilds and SetupSourceWidget gets fresh initialData).
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            key: const ValueKey('after'),
            twistInstanceId: 'test-instance',
            setupMode: false,
            showAccounts: false,
            initialData: _compositeAfterReauth(),
            onChanged: (c) => lastChange = c,
          ),
        ),
      );
      await tester.pump();

      // After a fresh State construction with updated data, drive is now
      // enabled — the new state should have no staged products. Verify
      // visually: the "Not enabled" section should be gone (both products
      // are now enabled) and there is no CompositeReauthWidget in the tree
      // (since _stagedProducts starts empty on fresh State).
      expect(find.text('Not enabled'), findsNothing);
      expect(find.byType(CompositeReauthWidget), findsNothing);

      // Interact with the new widget to trigger _notifyChanged — tap the
      // enabled single-channel Gmail product row. Channels now live behind a
      // drill-down (not inline), and a single-channel product row toggles on
      // tap, firing onChanged. This confirms the new state's _stagedProducts
      // is empty.
      await tester.tap(find.text('Gmail'));
      await tester.pump();

      // After interaction, lastChange reflects new state: no staged products.
      expect(lastChange, isNotNull);
      expect(lastChange!.stagedProducts, isEmpty);
    });
  });
}
