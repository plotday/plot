// Tests for the composite-connection product-status UI in SetupSourceWidget.
//
// Coverage:
// (a) Single flat product list with no "Enabled"/"Not enabled" section headers.
// (b) Product rows present with trailing toggles reflecting enabled/not status.
// (c) Channels are NOT rendered inline — a channel title like 'Inbox' is absent
//     until the drill-down is opened.
// (d) Tapping an enabled product with channels opens a drill-down showing its
//     channels.
// (e) Non-composite data still renders the existing flat channel list (regression).
// (f) Toggling a not-enabled product fires onChanged with stagedProducts.
// (g) Toggling a currently-synced product OFF does not flip its subtitle to
//     "Not synced" — the label reflects server sync state, not the staged toggle.
// (h) Clicking a channel row in the drill-down toggles it (mouse tap must
//     rebuild the modal subtree, not just the parent's state).

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/setup_source.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wraps widget in minimal scaffold: FTheme + Directionality + MediaQuery.
/// Does NOT include a ModalProvider — use [_wrapWithModal] for tests that
/// need to open drill-down modals.
Widget _wrap(Widget child) => FTheme(
      data: FThemes.zinc.light.desktop,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 400,
            height: 800,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

/// Like [_wrap] but provides [Navigator] + [ModalProvider] so drill-down modals
/// can be pushed via FormModal.run in widget tests.
///
/// Wraps with [MaterialApp] (which provides Navigator) then layers on FTheme +
/// ModalProvider. Test files may import material — the constraint is on app code.
Widget _wrapWithModal(Widget child) => MaterialApp(
      home: FTheme(
        data: FThemes.zinc.light.desktop,
        child: ModalProvider(
          child: SizedBox(
            width: 900,
            height: 900,
            child: child,
          ),
        ),
      ),
    );

TwistProvider _googleProvider() => const TwistProvider(
      provider: AuthProvider.google,
      scopes: [],
    );

TwistAccount _googleAccount() => const TwistAccount(
      provider: AuthProvider.google,
      actorId: 'user@example.com',
      email: 'user@example.com',
    );

ProductInfo _product(String key, String label) => ProductInfo(
      key: key,
      label: label,
      description: '$label description',
      icon: '',
      scopeGroupId: key,
    );

ProductStatus _status(String key, {required bool enabled}) => ProductStatus(
      key: key,
      enabled: enabled,
      reason:
          enabled ? ProductStatusReason.granted : ProductStatusReason.scopeMissing,
    );

/// Like [_status] but with an explicit [reason] — used to model the real
/// fresh-connect state where scope IS granted but nothing is enabled
/// server-side yet (`no-channels`), distinct from `scope-missing`.
ProductStatus _statusReason(
  String key, {
  required bool enabled,
  required ProductStatusReason reason,
}) =>
    ProductStatus(key: key, enabled: enabled, reason: reason);

TwistChannel _channel(
  String id,
  String title, {
  bool? enabledByDefault = true,
  bool enabled = true,
}) =>
    TwistChannel(
      provider: AuthProvider.google,
      providerKey: 'google',
      id: id, // namespaced: "productKey:rawId"
      title: title,
      enabled: enabled,
      enabledByDefault: enabledByDefault,
      currentUserHasAccess: true,
    );

/// Builds a minimal composite [TwistIntegrations] with:
/// - Gmail enabled product, channels: gmail:inbox, gmail:sent
/// - Drive not-enabled product, no channels
/// - Contacts enabled product, no channels (channelless)
TwistIntegrations _compositeData() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('gmail:inbox', 'Inbox'),
        _channel('gmail:sent', 'Sent'),
      ],
      products: [
        _product('gmail', 'Gmail'),
        _product('drive', 'Drive'),
        _product('contacts', 'Contacts'),
      ],
      productStatus: [
        _status('gmail', enabled: true),
        _status('drive', enabled: false),
        _status('contacts', enabled: true),
      ],
      channelNoun: const ChannelNoun(singular: 'label', plural: 'labels'),
    );

/// The REAL fresh-connect composite state: every product's scope is granted,
/// but NOTHING is enabled server-side yet (the draft hasn't been saved), so
/// productStatus.reason is `no-channels` for all. The channels carry
/// `enabledByDefault: true` so `_applySuggestedDefaults` seeds them locally on.
/// (server `enabled: false` is irrelevant in setup mode — the seed keys off
/// enabledByDefault, not server enabled.)
TwistIntegrations _freshConnectData() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('calendar:primary', 'Personal', enabled: false),
        _channel('mail:inbox', 'Inbox', enabled: false),
        _channel('mail:sent', 'Sent', enabled: false),
      ],
      products: [
        _product('calendar', 'Calendar'),
        _product('mail', 'Mail'),
      ],
      productStatus: [
        _statusReason('calendar',
            enabled: false, reason: ProductStatusReason.noChannels),
        _statusReason('mail',
            enabled: false, reason: ProductStatusReason.noChannels),
      ],
      channelNoun: const ChannelNoun(singular: 'label', plural: 'labels'),
    );

/// A composite state where Mail's scope is granted with its owned channel
/// seeded ON, while Calendar's scope is ALSO granted (`no-channels`) but its
/// only channel is `enabledByDefault: false` so it starts OFF locally — lets us
/// assert that toggling a scope-granted product ON enables channels locally
/// (no staged re-auth), in contrast to a scope-MISSING product.
TwistIntegrations _scopeGrantedOffData() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('mail:inbox', 'Inbox', enabled: false),
        _channel('calendar:primary', 'Personal',
            enabled: false, enabledByDefault: false),
      ],
      products: [
        _product('mail', 'Mail'),
        _product('calendar', 'Calendar'),
      ],
      productStatus: [
        _statusReason('mail',
            enabled: false, reason: ProductStatusReason.noChannels),
        _statusReason('calendar',
            enabled: false, reason: ProductStatusReason.noChannels),
      ],
      channelNoun: const ChannelNoun(singular: 'label', plural: 'labels'),
    );

/// Non-composite data: a single provider with flat (non-namespaced) channels.
TwistIntegrations _flatData() => TwistIntegrations(
      providers: [_googleProvider()],
      accounts: [_googleAccount()],
      channels: [
        _channel('inbox', 'Inbox'),
        _channel('updates', 'Updates'),
      ],
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SetupSourceWidget composite mode', () {
    testWidgets(
        '(a) single flat product list — no "Enabled"/"Not enabled" section headers',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump(); // settle postFrameCallback

      // NO section headers
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Not enabled'), findsNothing);

      // All three product labels are present in one flat list
      expect(find.text('Gmail'), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
    });

    testWidgets(
        '(b) product rows have trailing toggles reflecting enabled/not status',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump();

      // There are three product rows — each has a trailing FSwitch.
      final switches = tester.widgetList<FSwitch>(find.byType(FSwitch)).toList();

      // Gmail and Contacts are enabled → at least two ON switches.
      final onSwitches = switches.where((s) => s.value == true).toList();
      // Drive is not-enabled → at least one OFF switch.
      final offSwitches = switches.where((s) => s.value == false).toList();

      expect(onSwitches, isNotEmpty);
      expect(offSwitches, isNotEmpty);
    });

    testWidgets(
        '(c) channels are NOT rendered inline — "Inbox" absent before drill-down',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump();

      // Channel titles must NOT appear inline (they live in the drill-down modal).
      expect(find.text('Inbox'), findsNothing);
      expect(find.text('Sent'), findsNothing);
    });

    testWidgets(
        '(d) tapping an enabled product with channels opens the drill-down with '
        'its channels', (tester) async {
      await tester.pumpWidget(
        _wrapWithModal(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump();

      // Verify channels are absent before tap.
      expect(find.text('Inbox'), findsNothing);

      // Tap the Gmail product row (label text).
      await tester.tap(find.text('Gmail'));
      await tester.pumpAndSettle();

      // After tap, the drill-down modal should have opened showing Gmail's channels.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
    });

    testWidgets(
        '(e) non-composite data still renders the existing flat channel list',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _flatData(),
          ),
        ),
      );
      await tester.pump();

      // Flat channels must be visible
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Updates'), findsOneWidget);

      // No product-section headers in non-composite mode
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Not enabled'), findsNothing);
    });

    testWidgets(
        '(f) toggling a not-enabled product fires onChanged with stagedProducts',
        (tester) async {
      IntegrationChanges? lastChange;

      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
            onChanged: (c) => lastChange = c,
          ),
        ),
      );
      await tester.pump();

      // Drive is not-enabled. Tap the "Drive" product row to stage it.
      await tester.tap(find.text('Drive'));
      await tester.pump();

      expect(lastChange, isNotNull);
      expect(lastChange!.stagedProducts, contains('drive'));
    });

    testWidgets(
        '(g) toggling a synced product off does NOT flip its subtitle to '
        '"Not synced"', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump();

      // Only Drive (not-enabled) reads "Not synced" initially.
      expect(find.text('Not synced'), findsOneWidget);

      // Gmail is the first product row and starts synced (its switch is on).
      final gmailSwitch = tester.widget<FSwitch>(find.byType(FSwitch).first);
      expect(gmailSwitch.value, isTrue,
          reason: 'Gmail (first product) starts synced/on');

      // Tap Gmail's trailing switch to toggle it off (stages a disable).
      await tester.tap(find.byType(FSwitch).first);
      await tester.pump();

      // The bug: this used to add a second "Not synced" (Gmail's) because the
      // label keyed off the staged toggle. It must still be just Drive's —
      // "Not synced" reflects the current server state, not the toggle.
      expect(find.text('Not synced'), findsOneWidget);
    });

    testWidgets(
        '(h) clicking a channel row in the drill-down toggles it (mouse tap '
        'rebuilds the modal)', (tester) async {
      await tester.pumpWidget(
        _wrapWithModal(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _compositeData(),
          ),
        ),
      );
      await tester.pump();

      // Open Gmail's drill-down (Inbox + Sent, both selected by default).
      await tester.tap(find.text('Gmail'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);

      int onSwitchCount() => tester
          .widgetList<FSwitch>(find.byType(FSwitch))
          .where((s) => s.value == true)
          .length;

      final before = onSwitchCount();

      // Click the Inbox channel row with the mouse. The tap is handled by the
      // row's ancestor GestureDetector (opaque), not the Text itself, so the
      // hit-test "missed" warning is expected — silence it.
      await tester.tap(find.text('Inbox'), warnIfMissed: false);
      await tester.pump();

      // The modal must rebuild so exactly one switch flips off. Without the
      // onAfterTap rebuild, the parent's setState wouldn't repaint this modal
      // subtree and the tap would appear to do nothing (count unchanged).
      expect(onSwitchCount(), before - 1);
    });

    testWidgets(
        '(i) on connect, scope-granted no-channels products show their toggles '
        'ON (seeded owned channels), not OFF', (tester) async {
      // The bug: every product showed OFF after connect because the toggle keyed
      // off the server productStatus (no-channels → off) instead of the locally
      // seeded enabledByDefault channels.
      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _freshConnectData(),
          ),
        ),
      );
      await tester.pump(); // settle _applySuggestedDefaults seed + postFrame

      final switches = tester.widgetList<FSwitch>(find.byType(FSwitch)).toList();
      expect(switches, hasLength(2),
          reason: 'one trailing toggle per product (Calendar, Mail)');
      expect(switches.every((s) => s.value == true), isTrue,
          reason:
              'scope-granted products with seeded owned channels start ON, '
              'even though the server reports no-channels pre-save');
    });

    testWidgets(
        '(j) toggling a scope-granted (no-channels) product ON enables its '
        'channels locally and does NOT stage a re-auth', (tester) async {
      IntegrationChanges? lastChange;

      await tester.pumpWidget(
        _wrap(
          SetupSourceWidget(
            twistInstanceId: 'test-instance',
            setupMode: true,
            showAccounts: false,
            initialData: _scopeGrantedOffData(),
            onChanged: (c) => lastChange = c,
          ),
        ),
      );
      await tester.pump();

      // Calendar's scope is granted but its only channel is enabledByDefault:
      // false, so it starts OFF locally. Tapping its single-channel row toggles
      // the product (no drill-down for a 1-channel product).
      await tester.tap(find.text('Calendar'));
      await tester.pump();

      expect(lastChange, isNotNull);
      expect(lastChange!.selectedChannels, contains('google:calendar:primary'),
          reason: 'scope-granted toggle enables the product channel locally');
      expect(lastChange!.stagedProducts, isNot(contains('calendar')),
          reason:
              'scope already granted — must NOT stage a re-auth (no "Continue '
              'with Google")');
    });
  });
}
