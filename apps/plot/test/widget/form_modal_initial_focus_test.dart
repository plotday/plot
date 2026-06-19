import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/input_modality.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/form_modal.dart';
import 'package:plot/widget/modal.dart';

class _Noop extends Command {
  _Noop()
    : super(
        title: 'Save',
        eventObject: EventObject.action,
        eventAction: EventAction.opened,
      );
  @override
  Future<CommandReturn> run(BuildContext context) async => const CommandSkipped();
}

/// Pumps a button-only [FormModal]'s content inside the Plot theme + a
/// ModalProvider. The form has a single primary button, so its initial focus
/// target is that button — the case Task 1 gates on the open modality.
Widget _buttonOnlyFormHost() {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  final group = StaticFormGroup(
    items: [
      FormButton(key: 'save', isPrimary: true, buildCommand: (_) => _Noop()),
    ],
  );
  final form = FormData(title: 'Confirm', groups: [group]);
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          data: const MediaQueryData(size: Size(900, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ModalProvider(
              child: Center(
                child: SizedBox(
                  width: 460,
                  height: 560,
                  child: Builder(
                    builder: (inner) =>
                        FormModal(form, groups: [group], rootContext: inner)
                            .builder(inner),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _sinkLabel = 'FormModal-sink';

void main() {
  group('shouldActivateInitialHighlight', () {
    test('keyboard open pre-arms the initial highlight (button-only form)', () {
      // Opened via keyboard, no text input -> still pre-arm so Enter activates
      // the primary button.
      expect(
        shouldActivateInitialHighlight(
          openedViaKeyboard: true,
          initialTargetIsTextInput: false,
        ),
        isTrue,
      );
    });

    test('pointer open does NOT pre-arm a button', () {
      // Opened via mouse/touch with no text input -> no initial highlight,
      // matching SelectModal's no-highlight-until-hover feel.
      expect(
        shouldActivateInitialHighlight(
          openedViaKeyboard: false,
          initialTargetIsTextInput: false,
        ),
        isFalse,
      );
    });

    test('pointer open still focuses a text input', () {
      // A text input the user clearly intends to type into is always focused,
      // regardless of how the modal was opened.
      expect(
        shouldActivateInitialHighlight(
          openedViaKeyboard: false,
          initialTargetIsTextInput: true,
        ),
        isTrue,
      );
    });

    test('keyboard open with a text input is active too', () {
      expect(
        shouldActivateInitialHighlight(
          openedViaKeyboard: true,
          initialTargetIsTextInput: true,
        ),
        isTrue,
      );
    });
  });

  group('FormModal initial focus by open modality', () {
    testWidgets('keyboard open focuses the primary button', (tester) async {
      InputModality.debugSetLastInputWasKeyboard(true);
      await tester.pumpWidget(_buttonOnlyFormHost());
      // Let the post-frame focus request settle.
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      // Focus landed on the button's own node, not the neutral sink.
      expect(focus!.debugLabel, isNot(_sinkLabel));
    });

    testWidgets('pointer open does not focus the primary button', (
      tester,
    ) async {
      InputModality.debugSetLastInputWasKeyboard(false);
      await tester.pumpWidget(_buttonOnlyFormHost());
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      // No control is pre-armed; focus parks on the neutral sink so the
      // keyboard stays live without highlighting the primary button.
      expect(FocusManager.instance.primaryFocus?.debugLabel, _sinkLabel);
    });

    testWidgets('hovering clears the pre-armed keyboard highlight', (
      tester,
    ) async {
      // Keyboard open -> the primary button is focused/highlighted.
      InputModality.debugSetLastInputWasKeyboard(true);
      await tester.pumpWidget(_buttonOnlyFormHost());
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, isNot(_sinkLabel));

      // Move a mouse over the button row: the mouse takes over, so the
      // pre-armed highlight clears and focus parks on the neutral sink
      // (matching SelectModal — only the hovered row stays emphasised).
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(() => gesture.removePointer());
      await gesture.moveTo(tester.getCenter(find.text('Save')));
      await tester.pump();
      await tester.pump();

      expect(FocusManager.instance.primaryFocus?.debugLabel, _sinkLabel);
    });
  });
}
