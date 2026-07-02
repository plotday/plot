import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/checkout_waiting_modal.dart';
import 'package:plot/widget/modal.dart';

/// Hosts a [ModalProvider] under a [Navigator] (which showFDialog needs) and
/// captures a context inside the provider so the test can drive
/// [CheckoutWaitingModal.run] directly. Mirrors the harness in
/// `modal_pop_for_swap_test.dart` — the source of truth for the modal test
/// wrapper (theme, provider, and navigator setup).
Widget _host(void Function(BuildContext) onInner) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          // >760px => multi-panel => Modal uses showFDialog (needs a Navigator).
          data: const MediaQueryData(size: Size(900, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => ModalProvider(
                  child: Builder(
                    builder: (inner) {
                      onInner(inner);
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// Minimal UsageData carrying one personal connection add-on credit count.
UsageData _usageWithConnectionCredits(int purchased) => UsageData.fromJson({
      'personal': {
        'connections': {'count': 0},
        'twists': {'count': 0},
        'premium': {'allowed': true, 'count': 0, 'purchased': purchased},
        'twistAddonCount': 0,
      },
      'teams': <dynamic>[],
      'pricing': {'connectionAddonPrice': 5},
    });

void main() {
  testWidgets('resolves true when isComplete flips via the listenable',
      (tester) async {
    final notifier = ValueNotifier<SubscriptionSnapshot>(
      SubscriptionSnapshot(usage: _usageWithConnectionCredits(0)),
    );
    bool? result;
    late BuildContext ctx;
    await tester.pumpWidget(_host((inner) => ctx = inner));
    await tester.pump();

    final future = CheckoutWaitingModal(
      message: 'Complete checkout in your browser to add the connection.',
      isComplete: (u) => (u.personal.premium?.purchased ?? 0) > 0,
      listenable: notifier,
    ).run(ctx).then((r) => result = r);
    // Show the modal. Not pumpAndSettle: the spinner's fading-circle animates
    // indefinitely, so pumpAndSettle would never converge while it's mounted.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    notifier.value =
        SubscriptionSnapshot(usage: _usageWithConnectionCredits(1));
    await tester.pump(); // listener fires -> Modal.pop(true)
    await tester.pump(const Duration(milliseconds: 400));
    await future;

    expect(result, isTrue);
  });

  testWidgets('resolves false when the safety cap fires', (tester) async {
    final notifier = ValueNotifier<SubscriptionSnapshot>(
      SubscriptionSnapshot(usage: _usageWithConnectionCredits(0)),
    );
    bool? result;
    late BuildContext ctx;
    await tester.pumpWidget(_host((inner) => ctx = inner));
    await tester.pump();

    final future = CheckoutWaitingModal(
      message: 'Complete checkout in your browser to add the connection.',
      isComplete: (u) => (u.personal.premium?.purchased ?? 0) > 0,
      listenable: notifier,
      timeout: const Duration(milliseconds: 50),
    ).run(ctx).then((r) => result = r);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 60)); // cap fires
    await tester.pumpAndSettle();
    await future;

    expect(result, isFalse);
  });
}
