import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart' show AuthButton;
import 'package:plot/widget/product_setup.dart';

/// Minimal [TwistProvider] for testing — supplies a Google provider with
/// two required scopes so [ProductSetupWidget] can build.
TwistProvider _googleProvider() => TwistProvider(
      provider: AuthProvider.google,
      scopes: ['https://www.googleapis.com/auth/calendar.readonly'],
      access: const [],
      optionalScopes: null,
    );

/// Convenience factory for a [ProductInfo] with the given label.
ProductInfo _product(String label) => ProductInfo(
      key: label.toLowerCase(),
      label: label,
      description: '$label description',
      icon: 'https://example.com/$label.svg',
      scopeGroupId: label.toLowerCase(),
    );

/// Wraps [ProductSetupWidget] in the minimal Flutter-test scaffolding it needs:
/// a [Directionality] (text layout), an [FTheme] (forui token access), and a
/// [SizedBox] so unconstrained [Row] children don't overflow in test layout.
Widget _wrap(Widget child) => FTheme(
      data: FThemes.zinc.light.desktop,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          child: child,
        ),
      ),
    );

void main() {
  group('ProductSetupWidget', () {
    testWidgets('renders all product labels', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [
              _product('Gmail'),
              _product('Calendar'),
              _product('Drive'),
            ],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      expect(find.text('Gmail'), findsOneWidget);
      expect(find.text('Calendar'), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
    });

    testWidgets('renders product descriptions', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [_product('Gmail')],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      expect(find.text('Gmail description'), findsOneWidget);
    });

    testWidgets('renders header text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [_product('Gmail')],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      // The header explains the permissions ask in provider-agnostic terms
      // (the copy is shared by Google/Outlook composite setup, see #426).
      expect(
        find.textContaining('Grant all permissions for full functionality'),
        findsOneWidget,
      );
    });

    testWidgets('contains no FSwitch toggles (informational only)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [
              _product('Gmail'),
              _product('Calendar'),
            ],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      // Products are informational — no toggles present.
      expect(find.byType(FSwitch), findsNothing);
    });

    testWidgets('shows a single connect button', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [_product('Gmail')],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      // AuthButton renders a FButton; one must be present.
      expect(find.byType(FButton), findsOneWidget);
    });

    testWidgets('connect button keeps its spinner on through the hand-off',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProductSetupWidget(
            provider: _googleProvider(),
            products: [_product('Gmail')],
            twistInstanceId: 'test-instance-id',
            onSuccess: () async {},
          ),
        ),
      );

      // After OAuth returns, the composite connect flow hands off to a separate
      // channel-setup modal (EditSource) that keeps THIS modal displayed while
      // it loads. The button must keep spinning until that modal swaps in, so
      // it cannot clear its loading state the instant onSuccess resolves.
      final button = tester.widget<AuthButton>(find.byType(AuthButton));
      expect(button.keepSpinnerOnSuccess, isTrue);
    });
  });
}
