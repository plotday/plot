import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/widget/form_button_bar.dart';
import 'package:plot/widget/form_modal.dart';

class _Noop extends Command {
  _Noop()
    : super(
        title: 'x',
        eventObject: EventObject.action,
        eventAction: EventAction.opened,
      );
  @override
  Future<CommandReturn> run(BuildContext context) async => const CommandDone();
}

FormButton _b(String key, {bool isPrimary = false}) =>
    FormButton(key: key, isPrimary: isPrimary, buildCommand: (_) => _Noop());

void main() {
  test('trailing buttons (with divider) collapse into one FormButtonBar', () {
    final groups = [
      StaticFormGroup(
        items: [
          FormTextInput(key: 'name'),
          _b('save', isPrimary: true),
          FormDivider(key: 'divider'),
          _b('archive'),
        ],
      ),
    ];
    final out = FormModal.groupTrailingButtons(groups);
    final items = out.single.items;
    expect(items.length, 2); // name field + one bar
    expect(items[0], isA<FormTextInput>());
    final bar = items[1] as FormButtonBar;
    expect(bar.buttons.map((b) => b.key), ['save', 'archive']);
    expect(bar.focusableCount, 2);
  });

  test('a non-trailing button stays a standalone FormButton', () {
    final groups = [
      StaticFormGroup(
        items: [
          _b('add_account'), // mid-form
          FormInfo(key: 'i', text: 'x'), // a non-button item after it
          _b('add', isPrimary: true), // trailing
        ],
      ),
    ];
    final out = FormModal.groupTrailingButtons(groups);
    final items = out.single.items;
    expect(items[0], isA<FormButton>()); // add_account NOT grouped
    expect(items.last, isA<FormButtonBar>()); // add grouped (run of 1)
    expect((items.last as FormButtonBar).buttons.single.key, 'add');
  });

  test('a group with no trailing buttons is unchanged', () {
    final groups = [
      StaticFormGroup(items: [FormTextInput(key: 'name'), FormInfo(key: 'i')]),
    ];
    final out = FormModal.groupTrailingButtons(groups);
    expect(out.single.items.length, 2);
    expect(out.single.items.every((i) => i is! FormButtonBar), isTrue);
  });
}
