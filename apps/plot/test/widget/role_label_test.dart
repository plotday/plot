import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/widget/role_label.dart';
import 'package:plot/widget/select_tile.dart';

/// A role's colour is its identity, so a role is surfaced as its name rendered
/// in that colour ([RoleLabel]) — never a [ColorDot] tagged beside the name.
/// These guard the colour rendering and the [SelectTile] value-widget slot that
/// lets the selected role show coloured in a form field.
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
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 280, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Role role({String name = 'Work', int colorIndex = 3}) => Role.fromRow(
    RoleRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      name: name,
      color: ThemeColor(colorIndex),
    ),
  );

  testWidgets('RoleLabel renders the role name in the role colour', (
    tester,
  ) async {
    final r = role(name: 'Marketing', colorIndex: 5);
    await tester.pumpWidget(host(RoleLabel(role: r)));

    final text = tester.widget<Text>(find.text('Marketing'));
    expect(
      text.style?.color,
      scheme.colours.fromTheme(r.displayColor),
      reason: 'the label text must be painted in the role colour',
    );

    // The whole point: no leading ColorDot beside the role name.
    expect(find.byType(ColorDot), findsNothing);
  });

  testWidgets('SelectTile shows valueWidget in place of the value text', (
    tester,
  ) async {
    final r = role(name: 'Personal');
    await tester.pumpWidget(
      host(
        SelectTile(
          label: 'Role',
          value: r.name, // drives the has-value / placeholder check
          valueWidget: RoleLabel(role: r),
          onSelect: () {},
        ),
      ),
    );

    // The coloured RoleLabel is shown...
    final text = tester.widget<Text>(find.text('Personal'));
    expect(text.style?.color, scheme.colours.fromTheme(r.displayColor));
    // ...and there's no separate plain-text duplicate of the value.
    expect(find.text('Personal'), findsOneWidget);
  });
}
