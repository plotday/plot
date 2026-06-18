import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/pro_badge.dart';

/// The onboarding "Connect your tools" tiles are a hardcoded white surface on
/// a themed backdrop, so they pass [ProBadge] an explicit brand colour. The
/// theme-derived default accent is the neutral-theme grey there and renders
/// "Pro" near-invisible on white — these guard that the override wins and the
/// default still works for in-app lists.
void main() {
  Color proTextColor(WidgetTester tester) {
    final text = tester.widget<Text>(find.text('Pro'));
    return text.style!.color!;
  }

  Widget host(Widget child, ColourSchemeData scheme) =>
      Provider<ColourSchemeData>.value(
        value: scheme,
        child: Builder(
          builder: (context) => FTheme(
            data: buildTheme(context, scheme),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      );

  testWidgets('explicit color overrides the theme accent', (tester) async {
    const override = Color(0xFF7C3AED);
    final scheme = ColourSchemeData(
      // Theme 7 (gray) has a near-zero-chroma accent — the case that made the
      // onboarding badge invisible.
      themeColor: const ThemeColor(7),
      brightness: Brightness.light,
    );
    await tester.pumpWidget(host(const ProBadge(color: override), scheme));

    expect(find.text('Pro'), findsOneWidget);
    expect(proTextColor(tester), override);
  });

  testWidgets('falls back to the theme primary when no color given', (
    tester,
  ) async {
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );
    await tester.pumpWidget(host(const ProBadge(), scheme));

    expect(find.text('Pro'), findsOneWidget);
    expect(proTextColor(tester), scheme.accent);
  });
}
