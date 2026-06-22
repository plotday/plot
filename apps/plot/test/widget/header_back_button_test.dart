import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/header_back_button.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/window.dart';

/// The single-panel header back chevron is visually a small (18px) glyph, but
/// the header band around it is 44px tall and a header item-spacing gap sits to
/// its right. That space used to be inert padding — taps landing in it did
/// nothing, making the button fiddly to hit on mobile. [HeaderBackButton] folds
/// the inert band (vertically) and the trailing spacing (horizontally, via
/// [HeaderBackButton.endInset]) into the hit target while keeping the glyph —
/// and therefore the surrounding layout — fixed. It also lifts the glyph to the
/// hover foreground colour, matching every other icon button.
void main() {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );

  Widget host(Widget child) {
    return Provider<ColourSchemeData>.value(
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
  }

  Icon iconOf(WidgetTester tester) =>
      tester.widget<Icon>(find.byType(Icon));

  testWidgets('hit target fills the full header band height', (tester) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {})));

    final size = tester.getSize(find.byType(HeaderBackButton));
    expect(size.height, kAppHeaderHeight);
  });

  testWidgets('width shrink-wraps the glyph when there is no trailing gap', (
    tester,
  ) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {})));

    final size = tester.getSize(find.byType(HeaderBackButton));
    // 18px glyph + 2px horizontal padding on each side.
    expect(size.width, closeTo(22, 0.5));
  });

  testWidgets('endInset widens the hit target to absorb the header spacing', (
    tester,
  ) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {}, endInset: 8)));

    final size = tester.getSize(find.byType(HeaderBackButton));
    // 22px base + 8px of trailing gap folded into the button.
    expect(size.width, closeTo(30, 0.5));
  });

  testWidgets('glyph stays vertically centred and left-anchored', (
    tester,
  ) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {}, endInset: 8)));

    final button = tester.getRect(find.byType(HeaderBackButton));
    final iconCentre = tester.getCenter(find.byType(Icon));
    // Vertically centred in the band ...
    expect(iconCentre.dy, closeTo(button.top + kAppHeaderHeight / 2, 0.5));
    // ... and the glyph sits at the leading edge (2px in), NOT shifted by the
    // trailing inset — the inset only grows the hit area on the trailing side.
    expect(iconCentre.dx, closeTo(button.left + 2 + 9, 0.5));
  });

  testWidgets('startInset widens the hit target on the leading edge', (
    tester,
  ) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {}, startInset: 12)));

    final size = tester.getSize(find.byType(HeaderBackButton));
    // 22px base + 12px of leading padding folded into the button.
    expect(size.width, closeTo(34, 0.5));
  });

  testWidgets('startInset pushes the glyph right by the inset (stays put)', (
    tester,
  ) async {
    // With startInset the glyph shifts right by exactly the inset. Callers pair
    // this with dropping the header's leading content padding by the same
    // amount, so the glyph's on-screen position is unchanged.
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {}, startInset: 12)));

    final button = tester.getRect(find.byType(HeaderBackButton));
    final iconCentre = tester.getCenter(find.byType(Icon));
    expect(iconCentre.dx, closeTo(button.left + 2 + 12 + 9, 0.5));
  });

  testWidgets('a tap in the absorbed leading inset fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(HeaderBackButton(onTap: () => taps++, startInset: 12)),
    );

    final rect = tester.getRect(find.byType(HeaderBackButton));
    // 2px from the leading edge — inside the formerly-inert content padding.
    await tester.tapAt(Offset(rect.left + 2, rect.center.dy));

    expect(taps, 1);
  });

  testWidgets('taps in the previously-inert top and bottom bands fire onTap', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(host(HeaderBackButton(onTap: () => taps++)));

    final topLeft = tester.getTopLeft(find.byType(HeaderBackButton));
    final size = tester.getSize(find.byType(HeaderBackButton));

    // The 18px glyph occupies roughly the middle ~26px of the 44px band, so
    // y≈3 (top) and y≈41 (bottom) sit in what used to be dead padding.
    await tester.tapAt(topLeft + Offset(size.width / 2, 3));
    await tester.tapAt(topLeft + Offset(size.width / 2, size.height - 3));

    expect(taps, 2);
  });

  testWidgets('a tap in the absorbed trailing gap fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(HeaderBackButton(onTap: () => taps++, endInset: 8)),
    );

    final rect = tester.getRect(find.byType(HeaderBackButton));
    // 2px from the trailing edge — inside the formerly-inert spacing gap.
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));

    expect(taps, 1);
  });

  testWidgets('glyph rests at the muted colour and lifts to hover on hover', (
    tester,
  ) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {})));

    expect(iconOf(tester).color, scheme.muted);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(HeaderBackButton)));
    await tester.pump();

    expect(iconOf(tester).color, scheme.hover);
  });

  testWidgets('renders the back chevron glyph', (tester) async {
    await tester.pumpWidget(host(HeaderBackButton(onTap: () {})));

    expect(iconOf(tester).icon, PlotIcon.left);
  });
}
