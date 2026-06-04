import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/toast.dart';

void main() {
  // Mirrors the app tree around toasts: a ColourSchemeData provider (read by
  // context.colour / colourOnce), an FTheme for forui styling, and an FToaster
  // ancestor for showFToast to resolve.
  Widget host(Widget child) => Provider<ColourSchemeData>.value(
        value: ColourSchemeData(
          themeColor: const ThemeColor.defaultColor(),
          brightness: Brightness.light,
        ),
        child: FTheme(
          data: FThemes.zinc.light.desktop,
          child: FToaster(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: child,
            ),
          ),
        ),
      );

  testWidgets(
    'showToast invoked from an event handler (outside build) shows the toast '
    'without throwing',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Invoked from the test body, where debugBuilding is false — exactly the
      // state inside a keyboard-shortcut or tap handler. The regression: the
      // toast helpers read context.colour (Provider.of listen: true), which
      // throws "Tried to listen to a value exposed with provider, from outside
      // of the widget tree" before the toast can be shown, so the success toast
      // never appeared (e.g. Cmd+Shift+C "Page link copied to clipboard").
      // colourOnce (listen: false) must not throw.
      ctx.showToast(message: 'Page link copied to clipboard');
      await tester.pump(); // build the toast overlay
      await tester.pump(const Duration(milliseconds: 50)); // advance entry anim

      expect(find.text('Page link copied to clipboard'), findsOneWidget);
    },
  );
}
