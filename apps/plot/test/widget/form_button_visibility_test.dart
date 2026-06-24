import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';

/// Records when it ran; returns [CommandSkipped] so no Modal host is needed.
class _RecordCommand extends Command {
  _RecordCommand(this.onRan, {required super.title})
    : super(eventObject: EventObject.action, eventAction: EventAction.opened);
  final void Function() onRan;
  @override
  Future<CommandReturn> run(BuildContext context) async {
    onRan();
    return const CommandSkipped();
  }
}

Widget _host(Widget child, {double width = 900}) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _pumpButton(FormButton button) => _host(
  FormScope(
    values: const {},
    validate: () => true,
    child: Builder(
      builder: (context) => button.build(
        context,
        -1,
        enabled: true,
        focusNodes: [FocusNode()],
      ),
    ),
  ),
);

void main() {
  testWidgets('hides reactively when isVisible() is false, shows again when true', (
    tester,
  ) async {
    // staged=true means "re-auth pending" → Save hidden.
    final staged = ValueNotifier<bool>(false);
    final button = FormButton(
      key: 'save',
      isPrimary: true,
      visibilityListenable: staged,
      isVisible: () => !staged.value,
      buildCommand: (_) => _RecordCommand(() {}, title: 'Save'),
    );

    await tester.pumpWidget(_pumpButton(button));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);

    staged.value = true; // stage → hide
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsNothing);

    staged.value = false; // unstage → reappears
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('without the visibility hook the button always renders (back-compat)', (
    tester,
  ) async {
    final button = FormButton(
      key: 'save',
      isPrimary: true,
      buildCommand: (_) => _RecordCommand(() {}, title: 'Save'),
    );

    await tester.pumpWidget(_pumpButton(button));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
  });
}
