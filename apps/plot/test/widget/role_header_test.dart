import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/role_header.dart';

/// Behaviour contract for the accordion [RoleHeader].
///
/// - The role name renders as an **uppercase eyebrow** (render-only — the
///   stored name keeps its case).
/// - A **collapsed** role is a tap target with the same hover pill as the focus
///   tiles (in the role's own colour) and a faint trailing chevron cue.
/// - The **expanded** role is a flat section label: tapping it does nothing, it
///   never paints a hover highlight, and it shows no chevron.
/// - Neither shows the old leading chevron — the role name sits flush-left.
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

  Role role() => Role.fromRow(
    RoleRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      name: 'Work',
      color: const ThemeColor.defaultColor(),
    ),
  );

  Widget header({required bool expanded, required VoidCallback onTap}) =>
      RoleHeader(
        role: role(),
        expanded: expanded,
        childFocuses: const [],
        monochrome: true,
        onTap: onTap,
      );

  ListTile tileOf(WidgetTester tester) =>
      tester.widget<ListTile>(find.byType(ListTile));

  testWidgets('renders the role name as an uppercase eyebrow', (tester) async {
    await tester.pumpWidget(host(header(expanded: false, onTap: () {})));

    // Uppercased render-only — the original-case name is not shown.
    expect(find.text('WORK'), findsOneWidget);
    expect(find.text('Work'), findsNothing);
    // No leading caret (the role isn't disclosed with a left chevron).
    expect(find.byIcon(FontAwesomeIcons.chevronDown), findsNothing);
  });

  group('collapsed role', () {
    testWidgets('is tappable and carries a coloured hover pill', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(header(expanded: false, onTap: () => taps++)));

      final tile = tileOf(tester);
      // Same hover styling as focuses: hover highlight enabled, in the role's
      // own colour (non-null in the monochrome left panel).
      expect(tile.noHoverHighlight, isFalse);
      expect(tile.highlightColor, isNotNull);

      // Tapping selects the role's first focus (expands it).
      expect(tile.onTap, isNotNull);
      await tester.tap(find.text('WORK'));
      expect(taps, 1);
    });

    testWidgets('shows a faint trailing chevron cue at rest', (tester) async {
      await tester.pumpWidget(host(header(expanded: false, onTap: () {})));

      // The "open me" affordance — a chevron (cross-fades to the "…" menu on
      // hover, but at rest it's the visible cue).
      expect(find.byIcon(PlotIcon.right), findsOneWidget);
    });
  });

  group('expanded role', () {
    testWidgets('does nothing on tap and never highlights', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(header(expanded: true, onTap: () => taps++)));

      final tile = tileOf(tester);
      // Flat section header: no hover pill, no tap target.
      expect(tile.noHoverHighlight, isTrue);
      expect(tile.onTap, isNull);
      expect(tile.command, isNull);

      // Tapping the header is a no-op.
      await tester.tap(find.text('WORK'));
      expect(taps, 0);
    });

    testWidgets('shows no chevron (inert section heading)', (tester) async {
      await tester.pumpWidget(host(header(expanded: true, onTap: () {})));

      // The current/open role is inert — only collapsed roles invite a tap.
      expect(find.byIcon(PlotIcon.right), findsNothing);
    });
  });
}
