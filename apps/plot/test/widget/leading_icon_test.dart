import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/leading_icon.dart';
import 'package:plot/widget/priority.dart';

/// Leading icons (icons sitting before a label) are sized to roughly cap height
/// — about one step below the label font — rather than 1:1 with the font, so
/// they sit optically level with the text instead of looming over it. The size
/// rule lives on [PlotIconSizes]; this guards the math and the two widgets that
/// default to it ([LeadingIcon], [FocusLabel]).
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

  Priority focus() => Priority.fromStore(
    PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: 'Things',
      path: Path('things'),
      order: const Order(0),
      root: false,
      unread: false,
      role: 'member',
      roleId: null,
      isInbox: false,
      isFyi: false,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    ),
    draft: true,
  );

  group('PlotIconSizes leading sizing', () {
    test('leadingFor is below the label size by the cap-height ratio', () {
      const sizes = PlotIconSizes.fallback; // base 16
      expect(sizes.leadingFor(20), 20 * PlotIconSizes.leadingRatio);
      // A leading icon is always smaller than its label so it reads as level
      // with the text rather than looming over it.
      expect(sizes.leadingFor(20), lessThan(20));
    });

    test('leading equals leadingFor(base)', () {
      const sizes = PlotIconSizes.fallback;
      expect(sizes.leading, sizes.leadingFor(sizes.base));
      expect(sizes.leading, lessThan(sizes.base));
    });
  });

  testWidgets('LeadingIcon.glyph draws the glyph at the leading size', (
    tester,
  ) async {
    await tester.pumpWidget(host(LeadingIcon.glyph(PlotIcon.inbox)));

    final ctx = tester.element(find.byType(Icon));
    final sizes = ctx.theme.iconSizes;
    expect(tester.widget<Icon>(find.byType(Icon)).size, sizes.leading);

    // Centred in a fixed slot the width of `iconSizes.base`, so the glyph gets
    // breathing room and neighbouring rows' labels share one left edge.
    final slot = tester.widget<SizedBox>(
      find
          .ancestor(of: find.byType(Icon), matching: find.byType(SizedBox))
          .first,
    );
    expect(slot.width, sizes.base);
    expect(slot.height, sizes.base);
  });

  testWidgets('FocusLabel defaults its glyph to the cap-height leading size', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(FocusLabel(priority: focus(), showRole: false)),
    );

    final ctx = tester.element(find.byType(Icon));
    final sizes = ctx.theme.iconSizes;
    final fontSize = ctx.theme.typography.md.fontSize!;

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, sizes.leadingFor(fontSize));
    // The whole point: the glyph is smaller than the label font, not 1:1.
    expect(icon.size, lessThan(fontSize));
  });

  testWidgets('FocusLabel honours an explicit iconSize override', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(FocusLabel(priority: focus(), showRole: false, iconSize: 99)),
    );

    expect(tester.widget<Icon>(find.byType(Icon)).size, 99);
  });
}
