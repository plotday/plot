library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FTheme;
import 'package:platform_builder/platform_builder.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/window.dart';

/// Regression test for the Windows frameless window being undraggable before
/// sign-in. Pre-auth pages (sign-in / loading / email) render as bare
/// [Scaffold]s at multi-panel width with no [UnifiedHeader] above them, so
/// they must synthesize their own drag bar. Signed-in pages inside the panel
/// shell (marked by [WindowDragProvider]) must NOT, since the shell header is
/// already draggable.
void main() {
  setUpAll(() {
    // Report the platform as Windows so [Scaffold] takes the Windows path.
    Platform.init(override: Platforms.windows);
    // [_WindowsDragBar] reads these static fields, normally set by
    // Window.init() (which isn't run in tests).
    Window.toolbarHeight = 32.0;
    Window.toolbarPadding = const EdgeInsets.only(right: 138);
  });

  tearDownAll(() {
    Platform.init();
  });

  Widget host({required Size size, required Widget child}) {
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor(0),
      brightness: Brightness.light,
    );
    return Provider<ColourSchemeData>.value(
      value: scheme,
      child: Builder(
        builder: (context) => FTheme(
          data: buildTheme(context, scheme),
          child: MediaQuery(
            // Width drives context.isMultiPanel when no LayoutBloc is in scope
            // (>= ~760px => multi-panel).
            data: MediaQueryData(size: size),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  const multiPanel = Size(1200, 800);
  const singlePanel = Size(400, 800);

  testWidgets('pre-auth page at multi-panel width gets a Windows drag bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        size: multiPanel,
        child: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    expect(find.byType(DragToMoveArea), findsOneWidget);
    expect(find.text('Plot'), findsOneWidget);
  });

  testWidgets(
    'page inside the panel shell at multi-panel width has no drag bar',
    (tester) async {
      await tester.pumpWidget(
        host(
          size: multiPanel,
          child: const WindowDragProvider(
            provided: true,
            child: Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      // The shell's own UnifiedHeader supplies the drag handle; the nested
      // Scaffold must not add a redundant one.
      expect(find.byType(DragToMoveArea), findsNothing);
      expect(find.text('Plot'), findsNothing);
    },
  );

  testWidgets('single-panel page keeps its drag bar (unchanged behavior)', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        size: singlePanel,
        child: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    expect(find.byType(DragToMoveArea), findsOneWidget);
  });

  testWidgets('an explicit header suppresses the fallback drag bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        size: multiPanel,
        child: const Scaffold(
          header: SizedBox(height: 10),
          body: SizedBox.shrink(),
        ),
      ),
    );

    expect(find.byType(DragToMoveArea), findsNothing);
  });
}
