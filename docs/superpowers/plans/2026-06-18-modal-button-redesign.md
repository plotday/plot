# Modal Button Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace stacked, left-aligned modal action buttons with a consistent "action bar" — primary fills + centred + bold accent, secondaries quiet — that renders side-by-side on multi-panel (desktop dialog) and stacked-with-borders on single-panel (phone bottom sheet), while preserving keyboard navigation.

**Architecture:** A new `FormButtonBar` `FormItem` owns a trailing run of buttons and renders the two layouts (branching on `context.isMultiPanel`). `FormModal` auto-groups the maximal trailing run of `FormButton`s (absorbing interleaved `FormDivider`s) into one `FormButtonBar`, so call sites need no change and consistency is structural. The existing multi-slot focus model (`focusableCount` + `highlightedSubIndex`, as used by `FormScheduler`) carries keyboard navigation through the bar unchanged.

**Tech Stack:** Flutter (forui widgets only — no `flutter/material.dart`), Dart, `flutter_test` widget tests.

## Global Constraints

- UI imports: only `package:flutter/widgets.dart` and `package:forui/forui.dart`; **never** `package:flutter/material.dart`.
- Widgets are stateless unless local UI state is required; no Bloc references inside widgets.
- UI text is sentence case ("Save", "Archive") — labels come from each button's `Command`, unchanged here.
- Desktop-style cursor: do **not** add pointer cursors to buttons.
- Lint must pass: `cd apps/plot && flutter analyze` (zero issues).
- `context.isMultiPanel` (from `package:plot/state/layout.dart`, `LayoutHelpers` extension) is the single signal for dialog-vs-bottom-sheet; `LayoutState.isMultiPanel(width)` is `width >= 760`.
- Theme tokens: accent = `context.theme.colors.primary`; muted = `context.theme.plotColors.muted`; rule/divider = `context.theme.colors.border`; hover fill = `context.theme.plotColors.highlight` (ListTile applies this itself); destructive = `context.theme.colors.destructive`; padding = `context.theme.spacing.xl` (20) horizontal, `context.theme.spacing.sm` (6) vertical; body text = `context.theme.typography.md`.
- Keep `FormButton`'s existing rendering untouched — it remains the style for mid-form standalone buttons (e.g. `Add account`, `Connect`).

---

## File Structure

- **Modify** `apps/plot/lib/widget/form.dart` — extract a reusable wrapped-command builder from `_FormButtonWidget`; add a public `listTileController` getter on `FormButtonController`; add an optional `destructive` flag to `FormButton`.
- **Create** `apps/plot/lib/widget/form_button_bar.dart` — the `FormButtonBar` `FormItem` + its private `_FormButtonBarBody` renderer (multi-panel row / single-panel stacked).
- **Modify** `apps/plot/lib/widget/form_modal.dart` — auto-group trailing button runs into a `FormButtonBar`; teach the focus/submit/activate helpers about `FormButtonBar`; wire ←/→ within the bar.
- **Modify** call sites (destructive flags + redundant `FormDivider` removal): `apps/plot/lib/command/twist.dart`, `apps/plot/lib/command/focus_block.dart`.
- **Create** tests: `apps/plot/test/widget/form_button_bar_test.dart`, `apps/plot/test/widget/form_modal_button_grouping_test.dart`.

---

## Task 1: Reusable wrapped-command builder + `FormButton` extensions

Extract the run/validate/pop logic from `_FormButtonWidget` into a top-level function both `_FormButtonWidget` and the new bar can call (DRY). Add the `destructive` flag and a public controller getter the bar needs. Pure refactor + additive API — no behaviour change for existing buttons.

**Files:**
- Modify: `apps/plot/lib/widget/form.dart`
- Test: `apps/plot/test/widget/form_button_bar_test.dart` (created here, reused in Task 3)

**Interfaces:**
- Produces:
  - `CommandWrapper buildWrappedFormButtonCommand(BuildContext context, {required Command Function(Map<String, dynamic> values) buildCommand, required bool skipValidation})` — builds the display command from current `FormScope` values and returns a `CommandWrapper` whose `run` validates the form (unless `skipValidation`), runs the command, handles the result (toast / refresh / route / `Modal.pop`), and returns `CommandDone` for `CommandMessage` results.
  - `FormButtonController.listTileController` → `ListTileController` (public getter).
  - `FormButton.destructive` → `bool` (constructor arg, default `false`).

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/form_button_bar_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/form.dart';

/// A trivial command that records when it ran. Returns [CommandSkipped] so the
/// wrapped command's success path does NOT call `Modal.pop` — letting these
/// tests run without a `ModalProvider`/`Modal` host.
class _RecordCommand extends Command {
  _RecordCommand(this.onRan, {required String title})
    : super(
        title: title,
        eventObject: EventObject.action,
        eventAction: EventAction.opened,
      );
  final void Function() onRan;
  @override
  Future<CommandReturn> run(BuildContext context) async {
    onRan();
    return const CommandSkipped();
  }
}

/// Pumps [child] inside the Plot theme at [width] logical pixels wide.
/// width >= 760 => multi-panel; < 760 => single-panel.
Widget host(Widget child, {double width = 900}) {
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

void main() {
  testWidgets('buildWrappedFormButtonCommand runs the built command', (
    tester,
  ) async {
    var ran = false;
    late CommandWrapper wrapped;
    await tester.pumpWidget(
      host(
        FormScope(
          values: const {},
          validate: () => true,
          child: Builder(
            builder: (context) {
              wrapped = buildWrappedFormButtonCommand(
                context,
                buildCommand: (_) =>
                    _RecordCommand(() => ran = true, title: 'Save'),
                skipValidation: false,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await wrapped.run(tester.element(find.byType(SizedBox).first));
    expect(ran, isTrue);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: FAIL — `buildWrappedFormButtonCommand` is undefined.

- [ ] **Step 3: Extract the builder in `form.dart`**

In `apps/plot/lib/widget/form.dart`, find the `runWrappedCommand` closure and the `CommandWrapper` construction inside `_FormButtonWidgetState.build` (the block from `Future<CommandReturn> runWrappedCommand() async {` through `final wrappedCommand = CommandWrapper(displayCommand, run: (_, context) => runWrappedCommand());`). Lift it into a top-level function above the `FormButton` class:

```dart
/// Builds the command a form button runs: validates the form (unless
/// [skipValidation]), executes [buildCommand] with the latest [FormScope]
/// values, then handles the result (error toast, in-place refresh, route, or
/// `Modal.pop`). Shared by the single [FormButton] row and the multi-button
/// [FormButtonBar] so both behave identically.
CommandWrapper buildWrappedFormButtonCommand(
  BuildContext context, {
  required Command Function(Map<String, dynamic> values) buildCommand,
  required bool skipValidation,
}) {
  final formValues = FormScope.of(context)?.values ?? {};
  final formValidate = FormScope.of(context)?.validate;

  Command displayCommand;
  try {
    displayCommand = buildCommand(formValues);
  } catch (e) {
    log.warning('Could not build command for display: $e');
    displayCommand = _FormSubmitCommand();
  }

  Future<CommandReturn> runWrappedCommand() async {
    if (!skipValidation && formValidate != null && !formValidate()) {
      context.showToast(
        message: 'Please fill in all required fields',
        isError: true,
      );
      return const CommandDone();
    }
    final latestValues = FormScope.of(context)?.values ?? formValues;
    final command = buildCommand(latestValues);
    final result = await command.run(context);
    if (context.mounted) {
      if (result is CommandMessage && result.isError) {
        context.showToast(
          title: result.title,
          message: result.message,
          isError: true,
        );
      } else if (result is CommandRefresh) {
        final refresh = FormScope.of(context)?.refresh;
        if (refresh != null) {
          await refresh();
        } else {
          Modal.pop<CommandReturn>(context, Value(result));
        }
      } else if (result is CommandRoute) {
        await Modal.popAll(context);
        if (context.mounted) {
          result.go(context);
        }
      } else if (result is! CommandSkipped) {
        Modal.pop<CommandReturn>(context, Value(result));
      }
    }
    if (result is CommandMessage) {
      return const CommandDone();
    }
    return result;
  }

  return CommandWrapper(
    displayCommand,
    run: (_, context) => runWrappedCommand(),
  );
}
```

Then replace the lifted block inside `_FormButtonWidgetState.build` with a call:

```dart
    final wrappedCommand = buildWrappedFormButtonCommand(
      context,
      buildCommand: widget.buildCommand,
      skipValidation: widget.skipValidation,
    );
```

(Leave the surrounding `Opacity`/`IgnorePointer`/`ListTile` return exactly as-is.)

- [ ] **Step 4: Add the public controller getter**

In `FormButtonController` (top of `form.dart`), add below `_listTileController`:

```dart
  /// Public handle to the underlying [ListTileController] so a multi-button
  /// bar can wire each button's tile to its controller.
  ListTileController get listTileController => _controller;
```

- [ ] **Step 5: Add the `destructive` flag to `FormButton`**

In `FormButton`'s constructor and fields:

```dart
  FormButton({
    required super.key,
    required this.buildCommand,
    this.skipValidation = false,
    this.isPrimary = false,
    this.destructive = false,
  }) : super(required: false, label: '');
```

and add the field with the others:

```dart
  /// When true (Archive / Delete), the label turns [colors.destructive] on
  /// hover/focus in a [FormButtonBar] to signal a destructive action without
  /// shouting at rest. Has no effect on the standalone [FormButton] rendering.
  final bool destructive;
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: PASS.

- [ ] **Step 7: Verify no regression + lint**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/widget/form.dart apps/plot/test/widget/form_button_bar_test.dart
git commit -m "refactor(form): extract wrapped-command builder; add FormButton.destructive + controller getter"
```

---

## Task 2: `FormButtonBar` — single-panel stacked layout

Create the `FormButtonBar` `FormItem` and its renderer, implementing the **single-panel** (bottom-sheet) layout first: stacked full-width rows, each with a top border, every label centred (primary bold accent, secondaries muted). Multi-panel is added in Task 3.

**Files:**
- Create: `apps/plot/lib/widget/form_button_bar.dart`
- Test: `apps/plot/test/widget/form_button_bar_test.dart` (extend)

**Interfaces:**
- Consumes (Task 1): `buildWrappedFormButtonCommand(...)`, `FormButtonController.listTileController`, `FormButton.destructive`.
- Produces:
  - `class FormButtonBar extends FormItem` with `FormButtonBar({required String key, required List<FormButton> buttons})`.
  - `int get focusableCount` = `buttons.length`.
  - `int? get primarySubIndex` — index of the first `isPrimary` button, else null.
  - `FormButtonController? get primaryController`.
  - `Future<void> runSubSlot(int subIndex)`.
  - `bool isSubSlotEnabled(int subIndex, bool formValid)`.
  - `build(context, highlightedSubIndex, {enabled, focusNodes, controller})` where **`enabled` carries "is the form currently valid"** (FormModal passes `_isFormValid()`).

- [ ] **Step 1: Write the failing test**

Append to `apps/plot/test/widget/form_button_bar_test.dart`:

```dart
  FormButton _btn(
    String key,
    String title, {
    bool isPrimary = false,
    bool skipValidation = false,
    bool destructive = false,
    void Function()? onRan,
  }) => FormButton(
    key: key,
    isPrimary: isPrimary,
    skipValidation: skipValidation,
    destructive: destructive,
    buildCommand: (_) =>
        _RecordCommand(onRan ?? () {}, title: title),
  );

  Widget _bar(FormButtonBar bar, {required double width}) => host(
    FormScope(
      values: const {},
      validate: () => true,
      child: Builder(
        builder: (context) => bar.build(
          context,
          -1,
          enabled: true,
          focusNodes: List.generate(bar.focusableCount, (_) => FocusNode()),
        ),
      ),
    ),
    width: width,
  );

  testWidgets('single-panel: buttons stack vertically (primary above secondary)', (
    tester,
  ) async {
    final bar = FormButtonBar(
      key: 'actions',
      buttons: [
        _btn('save', 'Save', isPrimary: true),
        _btn('archive', 'Archive', skipValidation: true, destructive: true),
      ],
    );
    await tester.pumpWidget(_bar(bar, width: 400)); // single-panel
    await tester.pumpAndSettle();

    final saveRect = tester.getRect(find.text('Save'));
    final archiveRect = tester.getRect(find.text('Archive'));
    // Stacked: Archive sits below Save.
    expect(archiveRect.top, greaterThan(saveRect.bottom));
    // Centred: both labels' horizontal centres are near the 400px midline.
    expect(saveRect.center.dx, moreOrLessEquals(200, epsilon: 8));
    expect(archiveRect.center.dx, moreOrLessEquals(200, epsilon: 8));
  });

  testWidgets('primarySubIndex / isSubSlotEnabled reflect button flags', (
    tester,
  ) async {
    final bar = FormButtonBar(
      key: 'actions',
      buttons: [
        _btn('save', 'Save', isPrimary: true),
        _btn('archive', 'Archive', skipValidation: true),
      ],
    );
    expect(bar.primarySubIndex, 0);
    // Primary needs a valid form; skipValidation secondary is always enabled.
    expect(bar.isSubSlotEnabled(0, false), isFalse);
    expect(bar.isSubSlotEnabled(0, true), isTrue);
    expect(bar.isSubSlotEnabled(1, false), isTrue);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: FAIL — `FormButtonBar` is undefined.

- [ ] **Step 3: Create `form_button_bar.dart`**

```dart
import 'package:flutter/widgets.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/list_tile.dart';

/// A bottom-of-modal action bar: one primary button plus any secondary peer
/// actions (Archive, Delete, Details, …), auto-grouped from a trailing run of
/// [FormButton]s by [FormModal].
///
/// Multi-panel (dialog): a single framed row — the primary fills the left
/// (centred, bold accent), secondaries cluster to the right at natural width,
/// hairline vertical dividers between, hover fills the cell. (Added in the
/// multi-panel task.)
///
/// Single-panel (bottom sheet): stacked full-width rows, each with a 1px top
/// border, every label centred — primary bold accent, secondaries muted.
///
/// Exposes one focus slot per button so [FormModal]'s linear ↑/↓ navigation
/// steps through the buttons in order (the [FormScheduler] multi-slot pattern).
class FormButtonBar extends FormItem {
  FormButtonBar({required super.key, required this.buttons})
    : assert(buttons.length > 0, 'FormButtonBar needs at least one button'),
      _controllers = List.generate(
        buttons.length,
        (_) => FormButtonController(),
      ),
      super(required: false);

  final List<FormButton> buttons;
  final List<FormButtonController> _controllers;

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => buttons.length;

  /// Index of the first primary button, or null if the bar has no primary.
  int? get primarySubIndex {
    for (var i = 0; i < buttons.length; i++) {
      if (buttons[i].isPrimary) return i;
    }
    return null;
  }

  /// Controller for the primary button (Enter from a text field runs this).
  FormButtonController? get primaryController {
    final i = primarySubIndex;
    return i == null ? null : _controllers[i];
  }

  /// Run the button at [subIndex] (Enter on the highlighted cell).
  Future<void> runSubSlot(int subIndex) async {
    if (subIndex >= 0 && subIndex < _controllers.length) {
      await _controllers[subIndex].run();
    }
  }

  /// Whether the button at [subIndex] is enabled. `skipValidation` buttons
  /// (Archive/Delete) are always enabled; others require a valid form.
  bool isSubSlotEnabled(int subIndex, bool formValid) {
    if (subIndex < 0 || subIndex >= buttons.length) return false;
    return buttons[subIndex].skipValidation || formValid;
  }

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {}

  @override
  bool isValid() => true;

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    // [enabled] carries "is the form valid" from FormModal; per-button enabled
    // is derived from that plus each button's skipValidation flag.
    return _FormButtonBarBody(
      buttons: buttons,
      controllers: _controllers,
      focusNodes: focusNodes,
      highlightedSubIndex: highlightedSubIndex,
      formValid: enabled,
    );
  }
}

class _FormButtonBarBody extends StatelessWidget {
  const _FormButtonBarBody({
    required this.buttons,
    required this.controllers,
    required this.focusNodes,
    required this.highlightedSubIndex,
    required this.formValid,
  });

  final List<FormButton> buttons;
  final List<FormButtonController> controllers;
  final List<FocusNode> focusNodes;
  final int highlightedSubIndex;
  final bool formValid;

  bool _enabled(int i) => buttons[i].skipValidation || formValid;

  /// One tappable button cell, reused by both layouts.
  Widget _tile(BuildContext context, int i) {
    final spec = buttons[i];
    final enabled = _enabled(i);
    final highlighted = highlightedSubIndex == i;
    final colors = context.theme.colors;

    final Color textColor = spec.isPrimary
        ? colors.primary
        : (spec.destructive && highlighted)
        ? colors.destructive
        : context.theme.plotColors.muted;
    final textStyle = context.theme.typography.md.copyWith(
      fontWeight: spec.isPrimary ? FontWeight.bold : FontWeight.normal,
      color: textColor,
    );

    Widget tile = ListTile(
      command: buildWrappedFormButtonCommand(
        context,
        buildCommand: spec.buildCommand,
        skipValidation: spec.skipValidation,
      ),
      style: ListTileStyle.button,
      centered: true,
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.sm,
      ),
      focusNode: focusNodes.length > i ? focusNodes[i] : null,
      controller: controllers[i].listTileController,
      highlighted: highlighted,
      textStyle: textStyle,
    );

    if (!enabled) {
      tile = Opacity(
        opacity: 0.5,
        child: IgnorePointer(child: tile),
      );
    }
    return tile;
  }

  Widget _topBorder(BuildContext context, {required Widget child}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: context.theme.colors.border, width: 1),
          ),
        ),
        child: child,
      );

  Widget _buildStacked(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < buttons.length; i++)
        _topBorder(context, child: _tile(context, i)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Multi-panel side-by-side layout is added in the next task; until then
    // both presentations stack.
    return _buildStacked(context);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: PASS (all tests, including the single-panel stack + `primarySubIndex` cases).

- [ ] **Step 5: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/form_button_bar.dart apps/plot/test/widget/form_button_bar_test.dart
git commit -m "feat(form): add FormButtonBar with stacked single-panel layout"
```

---

## Task 3: `FormButtonBar` — multi-panel side-by-side layout

Add the multi-panel row: primary fills the left (`Expanded`, centred), secondaries at natural width to the right, hairline vertical dividers between, one top rule, equal-height cells so hover fills cleanly.

**Files:**
- Modify: `apps/plot/lib/widget/form_button_bar.dart`
- Test: `apps/plot/test/widget/form_button_bar_test.dart` (extend)

**Interfaces:**
- Consumes: `_FormButtonBarBody._tile`, `context.isMultiPanel`.
- Produces: no new public API; `build()` now branches on `context.isMultiPanel`.

- [ ] **Step 1: Write the failing test**

Append to `apps/plot/test/widget/form_button_bar_test.dart`:

```dart
  testWidgets('multi-panel: primary fills left, secondary sits to its right', (
    tester,
  ) async {
    final bar = FormButtonBar(
      key: 'actions',
      buttons: [
        _btn('save', 'Save', isPrimary: true),
        _btn('archive', 'Archive', skipValidation: true),
      ],
    );
    await tester.pumpWidget(_bar(bar, width: 900)); // multi-panel
    await tester.pumpAndSettle();

    final saveRect = tester.getRect(find.text('Save'));
    final archiveRect = tester.getRect(find.text('Archive'));
    // Same row (roughly equal vertical centres).
    expect(saveRect.center.dy, moreOrLessEquals(archiveRect.center.dy, epsilon: 4));
    // Secondary is to the right of the primary.
    expect(archiveRect.center.dx, greaterThan(saveRect.center.dx));
  });

  testWidgets('multi-panel: 1 + 2 lays all three on one row in order', (
    tester,
  ) async {
    final bar = FormButtonBar(
      key: 'actions',
      buttons: [
        _btn('save', 'Save', isPrimary: true),
        _btn('details', 'Details'),
        _btn('archive', 'Archive', skipValidation: true),
      ],
    );
    await tester.pumpWidget(_bar(bar, width: 900));
    await tester.pumpAndSettle();

    final save = tester.getRect(find.text('Save')).center.dx;
    final details = tester.getRect(find.text('Details')).center.dx;
    final archive = tester.getRect(find.text('Archive')).center.dx;
    expect(save, lessThan(details));
    expect(details, lessThan(archive));
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: FAIL — in multi-panel the body still stacks, so `Save` and `Archive` are not on the same row (`dy` differs).

- [ ] **Step 3: Add the row layout**

In `form_button_bar.dart`, add a vertical divider helper and the row builder to `_FormButtonBarBody`, and branch in `build`:

```dart
  Widget _verticalDivider(BuildContext context) => Container(
    width: 1,
    color: context.theme.colors.border,
  );

  Widget _buildRow(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i == 0) {
        // Primary (leftmost) fills the remaining width.
        children.add(Expanded(child: _tile(context, i)));
      } else {
        children.add(_verticalDivider(context));
        // Secondaries take only the width they need.
        children.add(IntrinsicWidth(child: _tile(context, i)));
      }
    }
    return _topBorder(
      context,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
```

Replace the `build` method body:

```dart
  @override
  Widget build(BuildContext context) {
    return context.isMultiPanel ? _buildRow(context) : _buildStacked(context);
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: PASS (single-panel stack tests still pass at width 400; new multi-panel tests pass at width 900).

- [ ] **Step 5: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/form_button_bar.dart apps/plot/test/widget/form_button_bar_test.dart
git commit -m "feat(form): add multi-panel side-by-side layout to FormButtonBar"
```

---

## Task 4: Auto-group trailing buttons + integrate `FormButtonBar` in `FormModal`

Transform each group in `FormModal._initForm` so a maximal trailing run of `FormButton`s (absorbing interleaved/adjacent `FormDivider`s) becomes one `FormButtonBar`. Then teach the focus/submit/activate/value helpers about `FormButtonBar`. The existing slot model carries ↑/↓ navigation unchanged because `focusableCount` is preserved.

**Files:**
- Modify: `apps/plot/lib/widget/form_modal.dart`
- Test: `apps/plot/test/widget/form_modal_button_grouping_test.dart` (create)

**Interfaces:**
- Consumes: `FormButtonBar` (`focusableCount`, `primarySubIndex`, `primaryController`, `runSubSlot`, `isSubSlotEnabled`), `StaticFormGroup`.
- Produces: `static List<StaticFormGroup> groupTrailingButtons(List<StaticFormGroup> groups)` (top-level or static helper) — pure transform usable in tests.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/form_modal_button_grouping_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/widget/form.dart';
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
          FormChannelListStub(), // a non-button item after it
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
}
```

> Note: replace `FormChannelListStub()` with any concrete non-button `FormItem`
> that exists and constructs without arguments — e.g. `FormInfo(key: 'i', text: 'x')`.
> Use `FormInfo(key: 'i', text: 'x')` if `FormInfo` is the simplest; verify its
> constructor in `form.dart` first.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/form_modal_button_grouping_test.dart`
Expected: FAIL — `FormModal.groupTrailingButtons` is undefined.

- [ ] **Step 3: Add the transform to `form_modal.dart`**

Add an import at the top: `import 'package:plot/widget/form_button_bar.dart';`

Add a static method on `FormModal` (the `StatefulWidget`, not the State):

```dart
  /// Collapses each group's maximal *trailing* run of [FormButton]s (absorbing
  /// any [FormDivider]s interleaved with or adjacent to that run) into a single
  /// [FormButtonBar]. A [FormButton] that is not part of the trailing run
  /// (e.g. a mid-form `Add account`) is left untouched. Pure — does not mutate
  /// the input.
  static List<StaticFormGroup> groupTrailingButtons(
    List<StaticFormGroup> groups,
  ) {
    return groups.map((group) {
      final items = group.items;
      // Find the start of the trailing run: items that are FormButton or
      // FormDivider, scanning from the end.
      int runStart = items.length;
      while (runStart > 0 &&
          (items[runStart - 1] is FormButton ||
              items[runStart - 1] is FormDivider)) {
        runStart--;
      }
      final tail = items.sublist(runStart);
      final buttons = tail.whereType<FormButton>().toList();
      // No trailing buttons (e.g. empty group, or only non-button items) →
      // leave the group as-is.
      if (buttons.isEmpty) return group;
      final head = items.sublist(0, runStart);
      return StaticFormGroup(
        title: group.title,
        subtitle: group.subtitle,
        items: [
          ...head,
          FormButtonBar(key: '${group.title ?? 'actions'}__bar', buttons: buttons),
        ],
      );
    }).toList();
  }
```

In `_FormModalState._initForm`, apply the transform right after `_formGroups` is set:

```dart
  void _initForm([List<StaticFormGroup>? groups]) {
    _formGroups = FormModal.groupTrailingButtons(groups ?? widget.groups);
```

- [ ] **Step 4: Run the grouping test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/form_modal_button_grouping_test.dart`
Expected: PASS.

- [ ] **Step 5: Teach the FormModal helpers about `FormButtonBar`**

Make these edits in `form_modal.dart`:

(a) `_isFocusSlotEnabled` — add a `FormButtonBar` branch:

```dart
  bool _isFocusSlotEnabled(int focusIndex) {
    final (item, subIndex) = _getItemAndSubIndex(focusIndex);
    if (!item.isFocusable) return false;
    if (item is FormButton) return item.skipValidation || _isFormValid();
    if (item is FormButtonBar) return item.isSubSlotEnabled(subIndex, _isFormValid());
    if (item is FormSelect) return item.enabled;
    return true;
  }
```

(b) `_findInitialFocusIndex` — make the "primary button" pass also find a bar's primary sub-slot. Replace the `// No text inputs, find primary button first` loop:

```dart
    // No text inputs, find primary button first (standalone or inside a bar)
    for (int i = 0; i < totalSlots; i++) {
      final (item, subIndex) = _getItemAndSubIndex(i);
      if (item is FormButton && item.isPrimary && _isFocusSlotEnabled(i)) {
        return i;
      }
      if (item is FormButtonBar &&
          item.primarySubIndex == subIndex &&
          _isFocusSlotEnabled(i)) {
        return i;
      }
    }

    // Fall back to first button (standalone or any bar slot)
    for (int i = 0; i < totalSlots; i++) {
      final (item, _) = _getItemAndSubIndex(i);
      if ((item is FormButton || item is FormButtonBar) &&
          _isFocusSlotEnabled(i)) {
        return i;
      }
    }
```

(c) `_collectFormValues` — skip bars too:

```dart
        if (item is! FormButton && item is! FormButtonBar) {
          values[item.key] = item.getValue();
        }
```

(d) `_submitForm` — Enter from a text field runs the primary, now inside a bar:

```dart
  Future<void> _submitForm() async {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormButton && item.isPrimary) {
          await _buttonControllers[item]?.run();
          return;
        }
        if (item is FormButtonBar) {
          final controller = item.primaryController;
          if (controller != null) {
            await controller.run();
            return;
          }
        }
      }
    }
  }
```

(Delete the now-unused `_getPrimaryButton()` method if nothing else references it — grep first; if other code uses it, leave it.)

(e) `ActivateListSelectionIntent` (Enter on the highlighted slot) — add a bar branch. Inside the `onInvoke`, after the `if (item is FormButton) { ... }` block, add:

```dart
                      } else if (item is FormButtonBar) {
                        item.runSubSlot(subIndex);
```

(insert as an `else if` in the existing chain, before `item.onSubmitted != null`).

(f) The render loop's `enabled:`/`controller:` for items — pass form-validity to the bar and no controller. Find the `item.build(context, highlightedSubIndex, enabled: ..., controller: ...)` call and update:

```dart
                                        item.build(
                                          context,
                                          highlightedSubIndex,
                                          enabled: item is FormButton
                                              ? (item.skipValidation ||
                                                    _isFormValid())
                                              : item is FormButtonBar
                                              ? _isFormValid()
                                              : true,
                                          focusNodes: itemFocusNodes,
                                          controller: item is FormButton
                                              ? _buttonControllers.putIfAbsent(
                                                  item,
                                                  () => FormButtonController(),
                                                )
                                              : null,
                                        ),
```

(g) `onActivate` of `ListViewSelector` — make a bar's highlighted slot run that button. Replace:

```dart
      onActivate: (index) async {
        if (index >= _allFocusSlotsCount()) return;
        final (item, subIndex) = _getItemAndSubIndex(index);
        if (item is FormButtonBar) {
          await item.runSubSlot(subIndex);
        } else if (item is FormButton || item.onSubmitted != null) {
          await _submitForm();
        }
      },
```

- [ ] **Step 6: Write a FormModal navigation test**

Append to `apps/plot/test/widget/form_modal_button_grouping_test.dart`:

```dart
  testWidgets('Enter from a text field runs the bar primary', (tester) async {
    var saved = false;
    final form = FormData(
      title: 'Edit',
      groups: [
        StaticFormGroup(
          items: [
            FormTextInput(key: 'name', initialValue: 'x'),
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (_) => _RecordSave(() => saved = true),
            ),
            FormDivider(key: 'd'),
            FormButton(
              key: 'archive',
              skipValidation: true,
              buildCommand: (_) => _Noop(),
            ),
          ],
        ),
      ],
    );
    // Pump the modal via your existing modal test harness (see
    // recipient_picker_modal_test.dart for the ModalProvider + run pattern),
    // focus the text field, send Enter, and assert `saved` is true.
    // ...harness-specific pump...
  });
```

> Implementation note: model the modal pump on `test/widget/recipient_picker_modal_test.dart`
> (it shows how to host a `Modal`/`FormModal` with `ModalProvider`). Define
> `_RecordSave` like `_RecordCommand` in the bar test. If wiring a full modal
> pump proves heavy, assert the same behaviour by calling the State's
> `_submitForm` is not accessible (private) — instead keep this as a widget test
> that pumps the real `FormModal`, sends `LogicalKeyboardKey.enter`, and checks
> the command ran. Keep the grouping unit tests (Steps 1–4) as the primary guard.

- [ ] **Step 7: Run all affected tests**

Run: `cd apps/plot && flutter test test/widget/form_modal_button_grouping_test.dart test/widget/form_button_bar_test.dart`
Expected: PASS.

- [ ] **Step 8: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/widget/form_modal.dart apps/plot/test/widget/form_modal_button_grouping_test.dart
git commit -m "feat(form): auto-group trailing modal buttons into FormButtonBar"
```

---

## Task 5: ←/→ navigation within the multi-panel bar

In the side-by-side bar the buttons are horizontal, so ←/→ should move the highlight between them (↑/↓ already do via the linear slot walk). Wire left/right to `_moveHighlight(±1)` only when the focused slot belongs to a `FormButtonBar`, so arrows keep working as text-cursor keys elsewhere.

**Files:**
- Modify: `apps/plot/lib/widget/form_modal.dart`
- Test: `apps/plot/test/widget/form_modal_button_grouping_test.dart` (extend)

**Interfaces:**
- Consumes: `_getItemAndSubIndex`, `_moveHighlight`.

- [ ] **Step 1: Add the key handling**

In the `onKeyEvent` of the `Focus` widget (the block that already handles `arrowUp`/`arrowDown`), add a left/right branch:

```dart
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  event.logicalKey == LogicalKeyboardKey.arrowRight) {
                // Only hijack ←/→ when the highlighted slot is inside a button
                // bar (its buttons render side-by-side). Elsewhere ←/→ stay
                // available as text-cursor keys.
                if (_allFocusSlotsCount() > 0) {
                  final (item, _) = _getItemAndSubIndex(_highlightedIndex);
                  if (item is FormButtonBar) {
                    _moveHighlight(
                      event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1,
                    );
                    return KeyEventResult.handled;
                  }
                }
              }
```

(Place it inside the existing `if (event is KeyDownEvent) { ... }`.)

- [ ] **Step 2: Write the test**

Append to `form_modal_button_grouping_test.dart` a widget test that pumps a `FormModal` whose only group is `[FormButton(save, primary), FormButton(archive, skipValidation)]` at width 900, sends `LogicalKeyboardKey.arrowRight`, and asserts the focus/highlight moved from the primary (slot 0) to the secondary (slot 1) — e.g. by checking the secondary's tile is highlighted, or that a subsequent Enter runs `archive` instead of `save`. Model the pump on `recipient_picker_modal_test.dart`.

```dart
  testWidgets('→ moves highlight from primary to secondary in the bar', (
    tester,
  ) async {
    var archived = false;
    // pump FormModal with save+archive at width 900 (multi-panel),
    // send arrowRight, then Enter, assert `archived` is true and save did not
    // run. ...harness-specific...
  });
```

- [ ] **Step 3: Run the tests**

Run: `cd apps/plot && flutter test test/widget/form_modal_button_grouping_test.dart`
Expected: PASS.

- [ ] **Step 4: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/form_modal.dart apps/plot/test/widget/form_modal_button_grouping_test.dart
git commit -m "feat(form): ←/→ navigate within the multi-panel button bar"
```

---

## Task 6: Destructive flags + redundant-divider cleanup at call sites

Mark Archive/Delete buttons `destructive: true` so they pick up the hover/focus tint, and delete the now-redundant `FormDivider`s in the multi-button groups (auto-grouping absorbs them anyway — this is tidiness).

**Files:**
- Modify: `apps/plot/lib/command/twist.dart`, `apps/plot/lib/command/focus_block.dart`
- Test: `apps/plot/test/widget/form_button_bar_test.dart` (extend — destructive tint)

**Interfaces:**
- Consumes: `FormButton.destructive`, `colors.destructive`.

- [ ] **Step 1: Write the failing test**

Append to `form_button_bar_test.dart`:

```dart
  testWidgets('destructive secondary turns destructive-coloured when highlighted', (
    tester,
  ) async {
    final bar = FormButtonBar(
      key: 'actions',
      buttons: [
        _btn('save', 'Save', isPrimary: true),
        _btn('archive', 'Archive', skipValidation: true, destructive: true),
      ],
    );
    // highlightedSubIndex = 1 forces the Archive cell into its highlighted state.
    await tester.pumpWidget(
      host(
        FormScope(
          values: const {},
          validate: () => true,
          child: Builder(
            builder: (context) => bar.build(
              context,
              1,
              enabled: true,
              focusNodes: List.generate(2, (_) => FocusNode()),
            ),
          ),
        ),
        width: 400,
      ),
    );
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text('Archive'));
    // The destructive colour comes through the resolved text style.
    final ctx = tester.element(find.text('Archive'));
    expect(text.style?.color, ctx.theme.colors.destructive);
  });
```

> Verify the `ctx.theme.colors` accessor matches how the codebase reads it (it
> may be `FTheme.of(ctx).colors`); align the test with `_FormButtonBarBody`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart`
Expected: FAIL only if the tint is not yet applied. (The tint code already exists from Task 2/3; this test pins it. If it already passes, that is acceptable — proceed to mark call sites.)

- [ ] **Step 3: Mark destructive call sites + remove dividers**

In `apps/plot/lib/command/twist.dart`:
- EditSource group (~`'archive'` button near the `PromptToArchiveSource` command): add `destructive: true` to the archive `FormButton`; delete the adjacent `FormDivider(key: 'divider')`.
- EditTwistInstance group (`'archive'` → `PromptToArchiveTwist`): add `destructive: true`; delete the `FormDivider(key: 'divider')` in that group.
- EditTwistInstance fallback group (`'archive'`): add `destructive: true`; delete its `FormDivider`.

In `apps/plot/lib/command/focus_block.dart`:
- The `'delete'` button (`ArchiveFocusBlock`): add `destructive: true`.

(Leave `'details'` non-destructive. Leave AddPriorityWithMatching's `'create'` non-destructive. Leave mid-form `FormDivider`s that separate fields from a single trailing button — they are harmless, but removing the ones strictly between buttons is cleaner.)

- [ ] **Step 4: Run the test + lint**

Run: `cd apps/plot && flutter test test/widget/form_button_bar_test.dart && flutter analyze`
Expected: PASS, no issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/twist.dart apps/plot/lib/command/focus_block.dart apps/plot/test/widget/form_button_bar_test.dart
git commit -m "feat(form): mark destructive modal actions; drop redundant button dividers"
```

---

## Task 7: Documentation + run-app verification

**Files:**
- Modify: `docs/updates.md`
- Verify (no code): EditSource, EditTwistInstance, a single-primary modal, in both widths.

- [ ] **Step 1: Add an updates entry**

In `docs/updates.md`, under `## Next release` (create the section at the top if absent, above the most recent stamped version), add to a `### Fixes` section (or a fitting feature section):

```markdown
- Modal action buttons are clearer: the main action stands out and sits beside
  quieter secondary actions on desktop, stacking neatly on mobile.
```

- [ ] **Step 2: Run the app and verify (run-app skill)**

Invoke the `run-app` skill. Then:
- Open a connection settings modal (EditSource) — confirm **Save** fills the left, **Archive** is a quiet cell on the right with a top rule, hovering each fills its cell, and Archive turns destructive-coloured on hover.
- Open the twist settings modal (EditTwistInstance) — confirm `Save │ Details │ Archive` on one row in order.
- Open a single-primary modal (e.g. new thread) — confirm the primary is centred with a top border.
- Narrow the window below 760px (or use a single-panel layout) — confirm the same modals **stack**, every row top-bordered and centred.
- Keyboard: ↑/↓ moves through the buttons; ←/→ moves within the side-by-side bar; Enter submits the primary; Esc dismisses.

- [ ] **Step 3: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs: note modal action button redesign"
```

---

## Self-Review notes

- **Spec coverage:** multi-panel side-by-side (Task 3) ✓; single-panel stacked + per-row borders + centred (Task 2) ✓; consistent top border (Tasks 2–3) ✓; hover fills section (ListTile fill flush under the bar's own top border, dividers removed — Tasks 2–3, 6) ✓; single-primary centred (Tasks 2–3, runs of 1) ✓; destructive hover tint (Task 6) ✓; secondaries keep muted leading icon (the command's icon renders via `ListTile`, muted text — Task 2) ✓; mid-form buttons unchanged (grouping only the trailing run — Task 4) ✓; ↑/↓ preserved + ←/→ added (Tasks 4–5) ✓; Enter submits primary, initial focus on primary (Task 4) ✓; auto-grouping implementation (Task 4) ✓.
- **Automated vs run-app coverage:**
  - **Fully automated (render/measure/style/unit):** Task 1 wrapper invoke; Task 2 single-panel stacking + `primarySubIndex`/`isSubSlotEnabled`; Task 3 multi-panel geometry (1+1 and 1+2); Task 4 `groupTrailingButtons` unit transform; Task 6 destructive tint. These need **no** modal host — `_RecordCommand` returns `CommandSkipped` (skips `Modal.pop`), and geometry tests only render.
  - **Behavioral key tests (Task 4 Enter, Task 5 ←/→):** these pump a real `FormModal` and send keys. Model the pump on `test/widget/recipient_picker_modal_test.dart` and use a `CommandSkipped`-returning command so no `Modal.pop` host is required. If the `FormModal` pump proves heavy, the `groupTrailingButtons` unit test plus the **run-app verification in Task 7** are the backstop for nav behaviour — note this explicitly rather than dropping the check silently.
- **Open verification during implementation (pin, don't placeholder):**
  - Theme accessor is `context.theme.colors` / `context.theme.plotColors` (confirmed in `confirm_modal.dart`, `button.dart`); `colors.destructive` exists. Tests use `context.theme.colors.destructive`.
  - Confirm `IntrinsicWidth`/`IntrinsicHeight` around `ListTile` produces the intended natural-width secondaries; the Task 3 geometry tests are the guard — adjust wrapping until they pass.
  - In Task 4 Step 1, swap the `FormChannelListStub()` placeholder for a real zero-arg non-button `FormItem` — use `FormInfo(key: 'i', text: 'x')` (verify its constructor in `form.dart`).
