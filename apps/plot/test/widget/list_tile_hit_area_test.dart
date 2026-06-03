import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/list_tile.dart';

/// Regression test for the sidebar focus-tile click "dead zone".
///
/// A [ListTile] with a [trailingBuilder] taller than its body (the sidebar
/// focus tiles reserve `iconSizes.base * 2` = 32px so the row height doesn't
/// jump when the hover button appears) used to leave a several-pixel band at
/// the top and bottom of every row that showed the hover/selection highlight
/// (the `MouseRegion` + background span the full row) but did not register taps
/// (the body/leading `GestureDetector`s were center-aligned at their shorter
/// content height). Clicking near the bottom edge therefore highlighted but did
/// not select. The tap target must fill the full row height (the only residual
/// is the intentional ~1px selection-ring border, which reserves layout space).
void main() {
  Widget host(Widget child) {
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );
    return Provider<ColourSchemeData>.value(
      value: scheme,
      child: Builder(
        builder: (context) => FTheme(
          data: buildTheme(context, scheme),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 280, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // Mirrors the sidebar focus tile: a body label plus a trailing slot that
  // reserves a fixed height taller than the body content.
  Widget tile({required VoidCallback onTap}) => ListTile(
    onTap: onTap,
    leadingBuilder: (_, _) => const Padding(
      padding: EdgeInsets.only(left: 20, right: 12),
      child: SizedBox.square(dimension: 16),
    ),
    body: const Text('A focus'),
    trailingBuilder: (_, _) => const SizedBox(height: 32),
  );

  testWidgets('the whole highlighted row height is tappable, not just the '
      'centered label', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(tile(onTap: () => taps++)));

    final rect = tester.getRect(find.byType(ListTile));
    // The trailing reservation makes the row taller than the body label, so
    // there is a band above and below the label that highlights on hover. It
    // must be tappable. (2px in from each edge clears the 1px selection border.)
    expect(rect.height, greaterThan(28));

    // Over the label, 2px above the bottom edge — was dead before the fix.
    await tester.tapAt(Offset(rect.left + 90, rect.bottom - 2));
    await tester.pump();
    expect(taps, 1, reason: 'bottom-edge tap should select the tile');

    // Over the label, 2px below the top edge — also formerly dead.
    await tester.tapAt(Offset(rect.left + 90, rect.top + 2));
    await tester.pump();
    expect(taps, 2, reason: 'top-edge tap should select the tile');
  });

  testWidgets('tapping the vertical center still selects it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(tile(onTap: () => taps++)));

    final rect = tester.getRect(find.byType(ListTile));
    await tester.tapAt(Offset(rect.left + 90, rect.center.dy));
    await tester.pump();

    expect(taps, 1);
  });

  // The command palette pairs a trailingBuilder with multi-line `details`, so
  // the body is the tallest child. The stretch/IntrinsicHeight path must lay
  // that out without overflow and stay tappable.
  testWidgets('body taller than trailing lays out and taps cleanly', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        ListTile(
          onTap: () => taps++,
          body: const Text('A command'),
          details: const Text('A longer description that sits below the row.'),
          trailingBuilder: (_, _) => const SizedBox(width: 24, height: 16),
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    final rect = tester.getRect(find.byType(ListTile));
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(taps, 1);
  });
}
