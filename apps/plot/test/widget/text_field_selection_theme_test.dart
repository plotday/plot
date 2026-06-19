import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/text_field_selection_theme.dart';

/// Pumps [child] under a Plot [FTheme] built for [brightness] and returns the
/// resolved [FThemeData] so tests can compare against its colours.
Future<FThemeData> _pump(
  WidgetTester tester,
  Brightness brightness,
  Widget Function(BuildContext context) child,
) async {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor(0),
    brightness: brightness,
  );
  late FThemeData theme;
  await tester.pumpWidget(
    material.MaterialApp(
      home: Builder(
        builder: (context) {
          theme = buildTheme(context, scheme);
          return FTheme(data: theme, child: child(context));
        },
      ),
    ),
  );
  return theme;
}

void main() {
  group('fieldSelectionBuilder', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        'a real FTextField selects with the note-editor colour ($brightness)',
        (tester) async {
          final controller = TextEditingController(text: 'hello');
          addTearDown(controller.dispose);
          final focusNode = FocusNode();
          addTearDown(focusNode.dispose);

          final theme = await _pump(
            tester,
            brightness,
            (_) => SizedBox(
              width: 200,
              child: FTextField(
                builder: fieldSelectionBuilder,
                focusNode: focusNode,
                control: FTextFieldControl.managed(controller: controller),
              ),
            ),
          );

          // Flutter's TextField only forwards selectionColor to its EditableText
          // while focused with a live selection.
          focusNode.requestFocus();
          await tester.pump();
          controller.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 5,
          );
          await tester.pump();

          final editable = tester.widget<EditableText>(
            find.byType(EditableText),
          );
          // Highlight matches the NoteEditor's selection colour (Editor uses
          // `colors.primaryForeground`).
          expect(editable.selectionColor, theme.colors.primaryForeground);
          // ...and is no longer forui's muted cursor colour at 40% alpha.
          expect(
            editable.selectionColor,
            isNot(theme.colors.mutedForeground.withValues(alpha: 0.4)),
          );
          // Cursor keeps forui's muted tone.
          expect(editable.cursorColor, theme.colors.mutedForeground);
        },
      );
    }

    testWidgets('without the builder, forui keeps its muted selection', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      final theme = await _pump(
        tester,
        Brightness.light,
        (_) => SizedBox(
          width: 200,
          child: FTextField(
            focusNode: focusNode,
            control: FTextFieldControl.managed(controller: controller),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      // Sanity check that the builder is what changes the colour: the bare
      // field still selects with primaryForeground would be a false pass.
      expect(editable.selectionColor, isNot(theme.colors.primaryForeground));
    });
  });
}
