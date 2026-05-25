# NewThreadPage compose redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chip rows above the NewThreadPage note editor with text-field-style rows inside the same bordered compose surface, supporting keyboard-driven entry on desktop and tap-to-modal on touch.

**Architecture:** A new `compose/` widget package introduces a row chrome (`ComposeFieldRow`), a focus-driven dropdown (`ComposeDropdown`), and a chip-action menu (`ComposeChipMenu`), plus four field widgets (priority, connection, contacts, title). `NoteEditor` gains a `bodyOnly` flag so `NewThreadPage` can own the outer `EditableArea`, with the new field widgets stacked above the editor body inside the same border. The synthetic "Plot thread" option is modeled as a `ConnectionChoice` sum type that wraps either a real `CreateTarget` or the Plot-thread sentinel.

**Tech Stack:** Flutter (Dart), forui, flutter_bloc, OverlayPortal (for dropdowns), font_awesome_flutter. Lint: `flutter analyze`. Manual verification via the `run-app` skill.

**Spec:** `docs/superpowers/specs/2026-05-25-new-thread-compose-redesign-design.md`

---

## File structure

**Create:**
- `apps/plot/lib/widget/compose/compose.dart` — barrel file
- `apps/plot/lib/widget/compose/connection_choice.dart` — sum type for connection-field value
- `apps/plot/lib/widget/compose/compose_field_row.dart` — row chrome (icon + tooltip + slot + divider)
- `apps/plot/lib/widget/compose/compose_dropdown.dart` — focus-driven dropdown with arrow-key navigation
- `apps/plot/lib/widget/compose/compose_chip_menu.dart` — popover (desktop) / bottom-sheet (touch) for chip actions
- `apps/plot/lib/widget/compose/title_compose_field.dart`
- `apps/plot/lib/widget/compose/priority_compose_field.dart`
- `apps/plot/lib/widget/compose/connection_compose_field.dart`
- `apps/plot/lib/widget/compose/contacts_compose_field.dart`
- `apps/plot/lib/widget/compose/email_parser.dart` — small helper, separately testable
- `apps/plot/test/widget/compose/connection_choice_test.dart`
- `apps/plot/test/widget/compose/email_parser_test.dart`

**Modify:**
- `apps/plot/lib/widget/widget.dart` — export compose barrel
- `apps/plot/lib/widget/note_editor.dart` — add `bodyOnly` constructor flag
- `apps/plot/lib/page/new_thread.dart` — refactor (delete chip code, mount compose surface)
- `apps/plot/lib/widget/connection_chip.dart` — extend `ConnectionPickerModal.open` to include the Plot-thread choice; signature returns `ConnectionChoice?`

**Delete:**
- `apps/plot/lib/widget/inline_title_input.dart`

---

## Task 1: Add `ConnectionChoice` sum type

**Why:** The connection field always shows a value; the default is "Plot thread" which is not a real `CreateTarget`. A sealed sum type wraps either a real target or the Plot sentinel.

**Files:**
- Create: `apps/plot/lib/widget/compose/connection_choice.dart`
- Create: `apps/plot/test/widget/compose/connection_choice_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget/compose/connection_choice_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/connection_choice.dart';

void main() {
  group('ConnectionChoice.plotThread', () {
    test('has a stable key', () {
      expect(ConnectionChoice.plotThread.key, 'plot:thread');
    });

    test('displays "Plot thread" as label', () {
      expect(ConnectionChoice.plotThread.label, 'Plot thread');
    });

    test('toUserAction returns null', () {
      expect(ConnectionChoice.plotThread.toUserAction(), isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/connection_choice_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `ConnectionChoice`**

```dart
// apps/plot/lib/widget/compose/connection_choice.dart
import 'package:plot/store/store.dart' show CreateLinkUserAction;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …) or the synthetic
/// "Plot thread" choice that just clears any existing connection.
sealed class ConnectionChoice {
  String get key;
  String get label;
  String? get logo;
  String? get logoDark;
  String get searchText;

  /// Returns the [CreateLinkUserAction] to attach to the draft, or null
  /// for the Plot-thread choice (which removes any existing action).
  CreateLinkUserAction? toUserAction();

  static const PlotThreadChoice plotThread = PlotThreadChoice._();

  /// Wrap a real [CreateTarget] as a choice.
  factory ConnectionChoice.target(CreateTarget target) =
      TargetConnectionChoice;
}

class PlotThreadChoice implements ConnectionChoice {
  const PlotThreadChoice._();

  @override
  String get key => 'plot:thread';

  @override
  String get label => 'Plot thread';

  @override
  String? get logo => null;

  @override
  String? get logoDark => null;

  @override
  String get searchText => 'plot thread';

  @override
  CreateLinkUserAction? toUserAction() => null;
}

class TargetConnectionChoice implements ConnectionChoice {
  TargetConnectionChoice(this.target);

  final CreateTarget target;

  @override
  String get key => target.key;

  @override
  String get label => target.chipLabel;

  @override
  String? get logo => target.linkType.logo;

  @override
  String? get logoDark => target.linkType.logoDark;

  @override
  String get searchText => target.searchText;

  @override
  CreateLinkUserAction? toUserAction() => target.toUserAction();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/connection_choice_test.dart`
Expected: PASS — 3 tests passed.

- [ ] **Step 5: Lint and commit**

```bash
cd apps/plot && flutter analyze lib/widget/compose/connection_choice.dart test/widget/compose/connection_choice_test.dart
```
Expected: No issues found.

```bash
git add apps/plot/lib/widget/compose/connection_choice.dart apps/plot/test/widget/compose/connection_choice_test.dart
git commit -m "$(cat <<'EOF'
Add ConnectionChoice sum type for compose connection field

The compose surface treats "Plot thread" as a first-class choice
that wraps a sealed sum with either a real CreateTarget or the
plot-thread sentinel. toUserAction() returns null for the sentinel
so picking it clears any CreateLinkUserAction on the draft.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `EmailParser` helper

**Why:** The contacts field needs a single, testable email-pattern check used by both the dropdown logic and the chip-commit path.

**Files:**
- Create: `apps/plot/lib/widget/compose/email_parser.dart`
- Create: `apps/plot/test/widget/compose/email_parser_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget/compose/email_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/email_parser.dart';

void main() {
  group('EmailParser.isEmail', () {
    test('plain address', () {
      expect(EmailParser.isEmail('alice@example.com'), isTrue);
    });

    test('plus-addressed', () {
      expect(EmailParser.isEmail('alice+filter@example.com'), isTrue);
    });

    test('subdomain', () {
      expect(EmailParser.isEmail('alice@mail.example.co.uk'), isTrue);
    });

    test('rejects missing tld', () {
      expect(EmailParser.isEmail('alice@example'), isFalse);
    });

    test('rejects missing @', () {
      expect(EmailParser.isEmail('aliceexample.com'), isFalse);
    });

    test('rejects whitespace', () {
      expect(EmailParser.isEmail('alice @example.com'), isFalse);
    });

    test('trims leading/trailing whitespace', () {
      expect(EmailParser.isEmail('  alice@example.com  '), isTrue);
    });

    test('returns trimmed value via normalize', () {
      expect(
        EmailParser.normalize('  alice@example.com  '),
        'alice@example.com',
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `EmailParser`**

```dart
// apps/plot/lib/widget/compose/email_parser.dart

/// Lenient email pattern matcher for compose-field chip commits. Not for
/// validating mail-routable addresses — chips with addresses that don't
/// actually deliver are surfaced as bounces server-side.
class EmailParser {
  static final RegExp _pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// True iff [value] (after trimming) matches the address pattern.
  static bool isEmail(String value) => _pattern.hasMatch(value.trim());

  /// Trimmed form of [value].
  static String normalize(String value) => value.trim();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: PASS — 8 tests passed.

- [ ] **Step 5: Lint and commit**

```bash
cd apps/plot && flutter analyze lib/widget/compose/email_parser.dart test/widget/compose/email_parser_test.dart
```
Expected: No issues found.

```bash
git add apps/plot/lib/widget/compose/email_parser.dart apps/plot/test/widget/compose/email_parser_test.dart
git commit -m "$(cat <<'EOF'
Add EmailParser helper for compose contacts field

Single regex-based check used by the dropdown and chip-commit paths
so they cannot disagree on what counts as an email-shaped string.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Create `ComposeFieldRow` chrome widget

**Why:** All four field widgets share the same row chrome — leading icon with tooltip, content slot, hairline bottom divider, and a tap target that focuses the field input.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_field_row.dart`

- [ ] **Step 1: Implement `ComposeFieldRow`**

```dart
// apps/plot/lib/widget/compose/compose_field_row.dart
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Shared row chrome for compose fields. Renders a leading icon with a
/// tooltip (label + optional shortcut hint) and a content slot, with a
/// hairline bottom divider matching the editor border. Tapping anywhere
/// in the row invokes [onTapField] so the field can request focus.
class ComposeFieldRow extends StatelessWidget {
  const ComposeFieldRow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.child,
    this.shortcut,
    this.onTapField,
    this.isLast = false,
  });

  final IconData icon;
  final String tooltip;
  final Widget child;
  final ShortcutActivator? shortcut;
  final VoidCallback? onTapField;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final iconColor = theme.plotColors.muted;
    final iconSize = theme.typography.sm.fontSize ?? 14.0;

    final Widget leadingIcon = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: FaIcon(icon, size: iconSize, color: iconColor),
    );

    final Widget leading = hasPhysicalKeyboard()
        ? FTooltip(
            tipBuilder: (context, controller) => _buildTooltip(context),
            child: leadingIcon,
          )
        : leadingIcon;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapField,
      child: Container(
        constraints: BoxConstraints(
          minHeight: isMobilePlatform() ? 48 : 40,
        ),
        decoration: isLast
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colors.border,
                    width: 1,
                  ),
                ),
              ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            leading,
            Expanded(child: child),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildTooltip(BuildContext context) {
    final shortcutText =
        shortcut == null ? '' : formatShortcut(shortcut!);
    if (shortcutText.isEmpty) return Text(tooltip);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tooltip),
        Text(
          shortcutText,
          style: context.theme.typography.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/compose_field_row.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_field_row.dart
git commit -m "$(cat <<'EOF'
Add ComposeFieldRow chrome widget

Shared row chrome for all four compose fields: leading icon with
tooltip (label + optional shortcut hint), content slot, hairline
bottom divider, and a tap target that delegates to the field's
own focus handler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Create `ComposeDropdown` widget

**Why:** Three fields (priority, connection, contacts) share the same focus-driven dropdown pattern: opens on focus, navigates with arrow keys, selects with Enter, filters by typed text. One widget owns the overlay positioning, item highlighting, and keyboard handling.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_dropdown.dart`

- [ ] **Step 1: Implement `ComposeDropdown`**

```dart
// apps/plot/lib/widget/compose/compose_dropdown.dart
import 'package:flutter/services.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';

/// A focus-driven dropdown anchored to a field. The parent owns the
/// [FocusNode] and the [items] list; this widget owns:
///   - the overlay rendering,
///   - the highlighted-index cursor,
///   - arrow-key / Enter / Escape handling.
///
/// Open the dropdown by calling [DropdownController.show] from the parent
/// (typically when the field's input gains focus or its text changes).
class ComposeDropdown<T> extends StatefulWidget {
  const ComposeDropdown({
    super.key,
    required this.controller,
    required this.items,
    required this.itemBuilder,
    required this.onSelected,
    required this.child,
    this.maxHeight = 280,
    this.emptyBuilder,
  });

  final DropdownController controller;
  final List<T> items;
  final Widget Function(BuildContext context, T item, bool highlighted)
      itemBuilder;
  final void Function(T item) onSelected;
  final Widget child;
  final double maxHeight;
  final WidgetBuilder? emptyBuilder;

  @override
  State<ComposeDropdown<T>> createState() => ComposeDropdownState<T>();
}

class ComposeDropdownState<T> extends State<ComposeDropdown<T>> {
  int _highlightedIndex = 0;
  final GlobalKey _anchorKey = GlobalKey();

  @override
  void didUpdateWidget(ComposeDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      // Reset the highlight when the candidate list changes (e.g. user
      // typed and the filtered list shrank).
      _highlightedIndex = widget.items.isEmpty
          ? 0
          : _highlightedIndex.clamp(0, widget.items.length - 1);
    }
  }

  /// Public hooks for the parent to drive navigation from its keyboard
  /// listener. Returns true if the key was handled.
  bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!widget.controller.isShowing) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (widget.items.isEmpty) return false;
      widget.onSelected(widget.items[_highlightedIndex]);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.hide();
      return true;
    }
    return false;
  }

  void _move(int delta) {
    if (widget.items.isEmpty) return;
    setState(() {
      _highlightedIndex =
          (_highlightedIndex + delta) % widget.items.length;
      if (_highlightedIndex < 0) {
        _highlightedIndex += widget.items.length;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dropdown(
      controller: widget.controller,
      dropdown: _buildOverlay(context),
      child: Container(key: _anchorKey, child: widget.child),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Material(
      color: context.theme.plotColors.editableBackground,
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: widget.items.isEmpty
            ? (widget.emptyBuilder?.call(context) ??
                const SizedBox.shrink())
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.items.length,
                itemBuilder: (context, i) {
                  return GestureDetector(
                    onTap: () => widget.onSelected(widget.items[i]),
                    child: widget.itemBuilder(
                      context,
                      widget.items[i],
                      i == _highlightedIndex,
                    ),
                  );
                },
              ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify imports — `Material` comes from forui**

Check that `Material` is exported by `widget.dart`. If not, replace with a forui `FCard` (the existing Dropdown overlays in this codebase use forui surfaces).

Run: `grep -n "Material\b" apps/plot/lib/widget/widget.dart`
If empty, replace the `Material(...)` block with:

```dart
return FCard(
  style: FCardStyleDelta.delta(
    decoration: DecorationDelta.boxDelta(
      color: ColorValueDelta.value(
        context.theme.plotColors.editableBackground,
      ),
      borderRadius: BorderRadiusGeometryDelta.value(
        BorderRadius.circular(8),
      ),
    ),
  ),
  child: ConstrainedBox(/* ... */),
);
```

(Use the same `FCard` style helpers the codebase already uses — check `lib/widget/dropdown.dart` for the existing precedent before settling on the API shape.)

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/compose_dropdown.dart
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_dropdown.dart
git commit -m "$(cat <<'EOF'
Add ComposeDropdown widget for focus-driven field pickers

Shared dropdown for the priority, connection, and contacts compose
fields. Owns the highlighted-index cursor and arrow/Enter/Escape
handling; parents pass items and a selection callback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create `ComposeChipMenu` (popover + modal)

**Why:** Clicking/tapping a chip in the contacts field opens an action menu with `Remove` and disabled `CC`/`BCC` placeholders. Desktop uses a popover anchored to the chip; touch uses a bottom-sheet modal. Both surface the same options to keep the future CC/BCC wiring symmetric.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_chip_menu.dart`

- [ ] **Step 1: Implement `ComposeChipMenu`**

```dart
// apps/plot/lib/widget/compose/compose_chip_menu.dart
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// Action a user picked from the chip menu.
enum ComposeChipAction { remove, addAsCc, addAsBcc }

/// Show the chip action menu. On desktop, opens a `Modal` anchored
/// inline (small dialog); on touch, the same `Modal` renders as a
/// bottom sheet via the project's Modal infrastructure.
/// `addAsCc` / `addAsBcc` are surfaced but disabled until CC/BCC ship.
Future<ComposeChipAction?> showComposeChipMenu(
  BuildContext context, {
  required String chipLabel,
}) async {
  final result = await Modal.open<ComposeChipAction>(
    context,
    title: chipLabel,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MenuItem(
          icon: PlotIcon.close,
          label: 'Remove',
          onTap: () => Modal.pop(
            context,
            Value(ComposeChipAction.remove),
          ),
        ),
        _MenuItem(
          icon: PlotIcon.user,
          label: 'Add as CC',
          enabled: false,
          onTap: () {},
        ),
        _MenuItem(
          icon: PlotIcon.user,
          label: 'Add as BCC',
          enabled: false,
          onTap: () {},
        ),
      ],
    ),
  );
  return result;
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final color = enabled
        ? theme.colors.foreground
        : theme.plotColors.veryMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: isMobilePlatform() ? 14 : 10,
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}
```

> **Implementation note:** the exact `Modal.open` signature in this codebase is `Modal.open<T>(context, ...)` and `Modal.pop<T>(context, Value<T>(value))`. Verify call shapes against `lib/widget/modal.dart` before committing — adjust the wrapping (`Value<T>`, named args) to match. The two memory notes in `MEMORY.md` cover this:
> - `Modal.pop` requires explicit type parameter
> - `Value<T>` is re-exported from drift via `package:plot/util/value.dart`

- [ ] **Step 2: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/compose_chip_menu.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_chip_menu.dart
git commit -m "$(cat <<'EOF'
Add ComposeChipMenu for contacts-field chip actions

Renders a Modal with Remove (active) and CC/BCC placeholders
(disabled). Used by clicks on desktop and taps on touch — Modal's
own platform-aware presentation handles popover vs. bottom-sheet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `bodyOnly` flag to `NoteEditor`

**Why:** The new compose surface mounts a single `EditableArea` around the field rows + body. `NoteEditor` must be able to skip its own outer `EditableArea` when used inside that surface, while the regular thread-page caller keeps it.

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Read the editor area entry point**

Run: `grep -n "EditableArea\|_buildEditorArea\|isNewThreadMode" apps/plot/lib/widget/note_editor.dart | head -20`

Identify `_buildEditorArea` (currently around line 480) and the constructor flags.

- [ ] **Step 2: Add the constructor flag**

In the `NoteEditor` constructor parameters, add:

```dart
/// Skip the outer EditableArea wrapper. Used when an ancestor
/// already provides the bordered surface (e.g. NewThreadPage's
/// compose card).
final bool bodyOnly;
```

In the constructor body, default `this.bodyOnly = false`.

- [ ] **Step 3: Conditionally skip `EditableArea` in `_buildEditorArea`**

Find `_buildEditorArea`. It currently returns `EditableArea(builder: ...)`. Wrap the `builder` callback's body into a local `buildContent(focusNode)` function and return:

```dart
if (widget.bodyOnly) {
  // Caller owns the EditableArea. Use a plain FocusNode so the editor
  // still receives focus, but don't render another border/background.
  return Builder(
    builder: (context) {
      final focusNode = _bodyOnlyFocusNode ??= FocusNode();
      return buildContent(context, focusNode);
    },
  );
}
return EditableArea(
  key: _editableAreaKey,
  padding: false,
  position: EditableAreaPosition.bottom,
  flushToBottom: widget.flushToBottom,
  builder: buildContent,
);
```

Add a `FocusNode? _bodyOnlyFocusNode;` field on `NoteEditorState` and dispose it in `dispose()`. The existing `focus()` method on `NoteEditorState` must also focus this node when `bodyOnly` is set.

> **Note:** The exact refactor depends on the current shape of `_buildEditorArea`. Read it first, extract the builder body into a reusable function, and then add the conditional. Don't change any of the existing editor logic (`Editor`, hint, autofocus, focus listener, etc.).

- [ ] **Step 4: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/note_editor.dart
```
Expected: No issues found.

- [ ] **Step 5: Verify regular thread page still works**

Open the app via the `run-app` skill. Open any existing thread. Type into the note editor. Confirm: border/background still around the editor, typing works, send button works, attachments work.

> If this is being executed in a non-interactive environment, skip this step and rely on `flutter analyze` plus the full manual-verification phase at the end.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "$(cat <<'EOF'
Add NoteEditor.bodyOnly flag

Skips the outer EditableArea wrapper so an ancestor (NewThreadPage's
new compose surface) can own the bordered background. Default stays
false; the existing thread page is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Export the `compose/` barrel

**Why:** Other widgets and the page layer import via `package:plot/widget/widget.dart`. The compose package needs to be reachable through the same barrel.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose.dart`
- Modify: `apps/plot/lib/widget/widget.dart`

- [ ] **Step 1: Create the barrel**

```dart
// apps/plot/lib/widget/compose/compose.dart
export 'compose_chip_menu.dart';
export 'compose_dropdown.dart';
export 'compose_field_row.dart';
export 'connection_choice.dart';
export 'email_parser.dart';
```

(Field widgets are exported as they're added.)

- [ ] **Step 2: Add export to `widget.dart`**

Append to `apps/plot/lib/widget/widget.dart`:

```dart
export 'compose/compose.dart';
```

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/widget.dart lib/widget/compose/
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/compose.dart apps/plot/lib/widget/widget.dart
git commit -m "$(cat <<'EOF'
Wire compose widgets into the widget barrel

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `TitleComposeField`

**Why:** Replace `InlineTitleInput`'s chip-that-expands-to-input behavior with a plain always-editable single-line text field, using the shared row chrome.

**Files:**
- Create: `apps/plot/lib/widget/compose/title_compose_field.dart`
- Modify: `apps/plot/lib/widget/compose/compose.dart`

- [ ] **Step 1: Implement `TitleComposeField`**

```dart
// apps/plot/lib/widget/compose/title_compose_field.dart
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

class TitleComposeField extends StatefulWidget {
  const TitleComposeField({
    super.key,
    required this.title,
    required this.onChanged,
    this.isLast = false,
  });

  final String? title;

  /// Persist a new value. `null` clears.
  final Future<void> Function(String? next) onChanged;

  final bool isLast;

  @override
  State<TitleComposeField> createState() => TitleComposeFieldState();
}

class TitleComposeFieldState extends State<TitleComposeField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title ?? '');
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(TitleComposeField old) {
    super.didUpdateWidget(old);
    // External edits (e.g. clear after submit) only update when the
    // field isn't focused, to avoid clobbering an in-progress edit.
    if (!_focusNode.hasFocus &&
        (widget.title ?? '') != _controller.text) {
      _controller.text = widget.title ?? '';
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Request focus on the title input. Used by the ⌘⇧H shortcut.
  void focus() => _focusNode.requestFocus();

  Future<void> _commit() async {
    final trimmed = _controller.text.trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (next != widget.title) {
      await widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ComposeFieldRow(
      icon: FontAwesomeIcons.pen,
      tooltip: 'Title',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyH,
        shift: true,
      ),
      onTapField: focus,
      isLast: widget.isLast,
      child: FTextField(
        control: .managed(controller: _controller),
        focusNode: _focusNode,
        hint: 'Title',
        textInputAction: TextInputAction.next,
        onChange: (_) => _commit(),
        onSubmit: (_) => _commit(),
        style: FTextFieldStyleDelta.delta(
          contentPadding: EdgeInsetsGeometryDelta.value(
            const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(
                border: BorderDelta.none,
                color: ColorValueDelta.value(
                  const Color(0x00000000),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
```

> **Style note:** the `FTextField` style block strips the field's own border so it visually blends into the compose row. Verify the exact API (`FTextFieldStyleDelta`, `FVariantsDelta`, `DecorationDelta.boxDelta`) against an existing borderless `FTextField` in this codebase (e.g. `lib/widget/inline_title_input.dart`) and copy the verified pattern. If the API differs, prefer the pattern already used in the project over the shape shown here.

- [ ] **Step 2: Re-export**

In `apps/plot/lib/widget/compose/compose.dart`, add:

```dart
export 'title_compose_field.dart';
```

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/title_compose_field.dart lib/widget/compose/compose.dart
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/title_compose_field.dart apps/plot/lib/widget/compose/compose.dart
git commit -m "$(cat <<'EOF'
Add TitleComposeField

Always-editable single-line title row that sits inside the compose
surface. Replaces InlineTitleInput's chip-that-expands behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `PriorityComposeField`

**Why:** Priority is the simplest dropdown-driven field. Mirroring the existing modal behavior keeps the touch path identical; desktop adds a dropdown anchored to the field with "Auto-organize" as the first item when not already on.

**Files:**
- Create: `apps/plot/lib/widget/compose/priority_compose_field.dart`
- Modify: `apps/plot/lib/widget/compose/compose.dart`

- [ ] **Step 1: Implement `PriorityComposeField`**

```dart
// apps/plot/lib/widget/compose/priority_compose_field.dart
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Either an existing priority or the synthetic "Auto-organize" choice.
sealed class PriorityChoice {
  String get label;
}

class AutoOrganizeChoice implements PriorityChoice {
  const AutoOrganizeChoice();
  @override
  String get label => 'Auto';
}

class PickedPriorityChoice implements PriorityChoice {
  PickedPriorityChoice(this.priority);
  final Priority priority;
  @override
  String get label => priority.title ?? priority.id.toString();
}

class PriorityComposeField extends StatefulWidget {
  const PriorityComposeField({
    super.key,
    required this.currentPriority,
    required this.isAuto,
    required this.onPickAuto,
    required this.onPickPriority,
    required this.openTouchModal,
    this.isLast = false,
  });

  /// Currently selected priority (irrelevant when [isAuto] is true).
  final Priority currentPriority;

  /// True when the draft is in auto-organize mode.
  final bool isAuto;

  /// Switch to auto-organize.
  final Future<void> Function() onPickAuto;

  /// Switch to a specific priority.
  final Future<void> Function(Priority next) onPickPriority;

  /// On touch, tapping the field invokes this to open the existing
  /// SelectModal (NewThreadPage owns the modal helper).
  final Future<void> Function() openTouchModal;

  final bool isLast;

  @override
  State<PriorityComposeField> createState() => _PriorityComposeFieldState();
}

class _PriorityComposeFieldState extends State<PriorityComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _focusNode = FocusNode();
  List<PriorityChoice> _candidates = const [];
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus && hasPhysicalKeyboard()) {
      _loadCandidates();
      _dropdown.show();
    } else {
      _dropdown.hide();
    }
  }

  Future<void> _loadCandidates() async {
    final all = await Priority.get(order: PriorityOrder.nested);
    if (!mounted) return;
    final filtered = _filter.isEmpty
        ? all
        : all.where((p) => p.matchesSearch(_filter)).toList();
    setState(() {
      _candidates = [
        if (!widget.isAuto) const AutoOrganizeChoice(),
        ...filtered.map(PickedPriorityChoice.new),
      ];
    });
  }

  Future<void> _handlePicked(PriorityChoice choice) async {
    _dropdown.hide();
    if (choice is AutoOrganizeChoice) {
      await widget.onPickAuto();
    } else if (choice is PickedPriorityChoice) {
      await widget.onPickPriority(choice.priority);
    }
  }

  Future<void> _handleTap() async {
    if (hasPhysicalKeyboard()) {
      _focusNode.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isAuto
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(PlotIcon.sparkles, size: 14),
              const SizedBox(width: 6),
              Text(
                'Auto',
                style: context.theme.typography.sm,
              ),
            ],
          )
        : PriorityLabel(
            priority: widget.currentPriority,
            fontSize: context.theme.typography.sm.fontSize,
          );

    return ComposeFieldRow(
      icon: FontAwesomeIcons.folder,
      tooltip: 'Priority',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyP,
        shift: true,
        alt: false,
      ),
      onTapField: _handleTap,
      isLast: widget.isLast,
      child: ComposeDropdown<PriorityChoice>(
        controller: _dropdown,
        items: _candidates,
        itemBuilder: (context, choice, highlighted) {
          return Container(
            color: highlighted
                ? context.theme.colors.muted.withValues(alpha: 0.15)
                : null,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: choice is AutoOrganizeChoice
                ? Row(
                    children: [
                      Icon(PlotIcon.sparkles, size: 14),
                      const SizedBox(width: 8),
                      const Text('Auto-organize'),
                    ],
                  )
                : PriorityLabel(
                    priority: (choice as PickedPriorityChoice).priority,
                    fontSize: 14,
                  ),
          );
        },
        onSelected: _handlePicked,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 8,
          ),
          child: Focus(focusNode: _focusNode, child: label),
        ),
      ),
    );
  }
}
```

> **Notes on accuracy to existing API:**
> - The `Priority.get(order: PriorityOrder.nested)` call mirrors what `_selectPriority` already does in `new_thread.dart`.
> - `priority.matchesSearch(...)` is already used in `new_thread.dart` for the filter callback.
> - `PriorityLabel` is already a widget in `lib/widget/priority.dart`.
> - If `Priority` doesn't have a `title` getter (the code reads `priority.title` directly elsewhere), adjust `_PickedPriorityChoice.label` to whatever the project uses (`PriorityLabel` reads the same field internally, so a tooltip-only label is fine).

- [ ] **Step 2: Re-export**

In `apps/plot/lib/widget/compose/compose.dart`:

```dart
export 'priority_compose_field.dart';
```

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/priority_compose_field.dart lib/widget/compose/compose.dart
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/priority_compose_field.dart apps/plot/lib/widget/compose/compose.dart
git commit -m "$(cat <<'EOF'
Add PriorityComposeField

Reads as text on the compose surface; opens a focus-driven dropdown
on desktop with Auto-organize as the first item, or the existing
SelectModal on touch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Update `ConnectionPickerModal` to return `ConnectionChoice?`

**Why:** The connection field's value is always a `ConnectionChoice` (which may be the Plot-thread sentinel). The picker modal needs to surface the same option set as the desktop dropdown so the touch and desktop selections stay consistent.

**Files:**
- Modify: `apps/plot/lib/widget/connection_chip.dart`

- [ ] **Step 1: Change return type and add the Plot-thread row**

In `ConnectionPickerModal.open`:

```dart
class ConnectionPickerModal {
  ConnectionPickerModal._();

  static Future<ConnectionChoice?> open(BuildContext context) async {
    final targets = await loadCreateTargets();
    if (!context.mounted) return null;

    final choices = <ConnectionChoice>[
      ConnectionChoice.plotThread,
      ...targets.map(ConnectionChoice.target),
    ];

    final result = await SelectModal.open<ConnectionChoice>(
      context,
      items: (search) async {
        final text = search?.trim().toLowerCase() ?? '';
        final filtered = text.isEmpty
            ? choices
            : choices
                .where((c) => c.searchText.contains(text))
                .toList();
        return [SelectGroup(title: null, items: filtered)];
      },
      itemBuilder: (choice, _) => switch (choice) {
        PlotThreadChoice() => ListTile(
            icon: PlotIcon.note,
            title: 'Plot thread',
          ),
        TargetConnectionChoice(:final target) =>
          createTargetTile(context, target),
      },
      prompt: 'Pick a connection',
      emptyMessage: 'No connections available',
      showFilter: true,
    );
    if (!result.present) return null;
    return result.value;
  }
}
```

- [ ] **Step 2: Update old call sites in `new_thread.dart` to match**

Search for `ConnectionPickerModal.open`. Current usage:

```dart
Future<void> _openConnectionPicker() async {
  final picked = await ConnectionPickerModal.open(context);
  if (picked == null || !mounted) return;
  await _toggleConnection(picked);
}
```

Update to:

```dart
Future<void> _openConnectionPicker() async {
  final picked = await ConnectionPickerModal.open(context);
  if (picked == null || !mounted) return;
  await _applyConnectionChoice(picked);
}
```

Add the helper that handles both cases (this is also used by the new connection field):

```dart
Future<void> _applyConnectionChoice(ConnectionChoice choice) async {
  final bloc = _priorityBloc;
  if (bloc == null) return;
  final note = bloc.state.draftNote;
  final actions = List<UserAction>.from(note.actions ?? const []);
  actions.removeWhere((a) => a is CreateLinkUserAction);
  final action = choice.toUserAction();
  if (action != null) actions.add(action);
  await bloc.updateDraft(
    bloc.state.draft,
    note: note.copyWith(actions: actions.isEmpty ? null : actions),
  );
}
```

Keep the existing `_toggleConnection(CreateTarget)` for now — Task 12 deletes the chip row that calls it.

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/connection_chip.dart lib/page/new_thread.dart
```
Expected: No new issues introduced. (Pre-existing lints, if any, are not part of this task.)

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/connection_chip.dart apps/plot/lib/page/new_thread.dart
git commit -m "$(cat <<'EOF'
ConnectionPickerModal returns ConnectionChoice with Plot thread row

Touch and desktop pickers now surface the same option set. The Plot
thread sentinel sits at the top of the modal; selecting it clears
any CreateLinkUserAction on the draft.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `ConnectionComposeField`

**Why:** Shows the active `ConnectionChoice`; opens a dropdown on desktop focus and the modal on touch.

**Files:**
- Create: `apps/plot/lib/widget/compose/connection_compose_field.dart`
- Modify: `apps/plot/lib/widget/compose/compose.dart`

- [ ] **Step 1: Implement `ConnectionComposeField`**

```dart
// apps/plot/lib/widget/compose/connection_compose_field.dart
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

class ConnectionComposeField extends StatefulWidget {
  const ConnectionComposeField({
    super.key,
    required this.activeChoice,
    required this.candidates,
    required this.onPicked,
    required this.openTouchModal,
    this.isLast = false,
  });

  /// The currently selected choice (always set — defaults to Plot thread).
  final ConnectionChoice activeChoice;

  /// All candidates, already ranked for the current priority.
  final List<ConnectionChoice> candidates;

  final Future<void> Function(ConnectionChoice choice) onPicked;

  final Future<void> Function() openTouchModal;

  final bool isLast;

  @override
  State<ConnectionComposeField> createState() =>
      _ConnectionComposeFieldState();
}

class _ConnectionComposeFieldState extends State<ConnectionComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus && hasPhysicalKeyboard()) {
      _dropdown.show();
    } else {
      _dropdown.hide();
    }
  }

  Future<void> _handleTap() async {
    if (hasPhysicalKeyboard()) {
      _focusNode.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  Future<void> _handlePicked(ConnectionChoice choice) async {
    _dropdown.hide();
    await widget.onPicked(choice);
  }

  @override
  Widget build(BuildContext context) {
    return ComposeFieldRow(
      icon: PlotIcon.link,
      tooltip: 'Connection',
      onTapField: _handleTap,
      isLast: widget.isLast,
      child: ComposeDropdown<ConnectionChoice>(
        controller: _dropdown,
        items: widget.candidates,
        itemBuilder: (context, choice, highlighted) {
          return Container(
            color: highlighted
                ? context.theme.colors.muted.withValues(alpha: 0.15)
                : null,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: switch (choice) {
              PlotThreadChoice() => Row(
                  children: const [
                    Icon(PlotIcon.note, size: 14),
                    SizedBox(width: 8),
                    Text('Plot thread'),
                  ],
                ),
              TargetConnectionChoice(:final target) =>
                createTargetTile(context, target),
            },
          );
        },
        onSelected: _handlePicked,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 8,
          ),
          child: Focus(
            focusNode: _focusNode,
            child: Text(
              widget.activeChoice.label,
              style: context.theme.typography.sm,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Re-export**

In `apps/plot/lib/widget/compose/compose.dart`:

```dart
export 'connection_compose_field.dart';
```

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/connection_compose_field.dart lib/widget/compose/compose.dart
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/connection_compose_field.dart apps/plot/lib/widget/compose/compose.dart
git commit -m "$(cat <<'EOF'
Add ConnectionComposeField

Always shows the active ConnectionChoice. Desktop focus opens a
dropdown ranked by the connection MRU; touch tap opens the modal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `ContactsComposeField`

**Why:** The most behavior-rich field — chip rendering, inline text input, dropdown autocomplete, keyboard chip navigation, click-to-menu, email parsing. Built in one pass since the parts are tightly interleaved.

**Files:**
- Create: `apps/plot/lib/widget/compose/contacts_compose_field.dart`
- Modify: `apps/plot/lib/widget/compose/compose.dart`

- [ ] **Step 1: Define the chip + candidate model**

A contact field row is one of three things: a contact (`Actor`), a group (`GroupRow`), or a pending email invite (`String`). The widget receives the resolved chip list from the parent and an async candidate-loader for the dropdown.

```dart
// apps/plot/lib/widget/compose/contacts_compose_field.dart
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// One value currently on the contacts field.
sealed class ContactChipValue {
  String get key;
  String get label;
}

class ContactChipActor implements ContactChipValue {
  ContactChipActor(this.actor);
  final Actor actor;
  @override
  String get key => 'actor:${actor.id.toUuid()}';
  @override
  String get label => actor.name ?? actor.email ?? 'Unknown';
}

class ContactChipGroup implements ContactChipValue {
  ContactChipGroup(this.group);
  final GroupRow group;
  @override
  String get key => 'group:${group.id}';
  @override
  String get label => group.name;
}

class ContactChipEmail implements ContactChipValue {
  ContactChipEmail(this.email);
  final String email;
  @override
  String get key => 'email:$email';
  @override
  String get label => email;
}

/// One dropdown row. Either a known contact / group, or a "create email
/// invite from typed text" synthesized item.
sealed class ContactCandidate {
  String get label;
}

class ActorCandidate implements ContactCandidate {
  ActorCandidate(this.actor);
  final Actor actor;
  @override
  String get label => actor.name ?? actor.email ?? '';
}

class GroupCandidate implements ContactCandidate {
  GroupCandidate(this.group);
  final GroupRow group;
  @override
  String get label => group.name;
}

class InviteEmailCandidate implements ContactCandidate {
  InviteEmailCandidate(this.email);
  final String email;
  @override
  String get label => 'Invite $email';
}

class ContactsComposeField extends StatefulWidget {
  const ContactsComposeField({
    super.key,
    required this.chips,
    required this.loadCandidates,
    required this.onAdd,
    required this.onRemove,
    required this.openTouchModal,
    this.isLast = false,
  });

  final List<ContactChipValue> chips;

  /// Returns candidates filtered by [query] (already excluding values
  /// already on the chip list). If [query] looks like an email and no
  /// existing actor matches, the parent should append an
  /// [InviteEmailCandidate] to the returned list.
  final Future<List<ContactCandidate>> Function(String query)
      loadCandidates;

  final Future<void> Function(ContactCandidate candidate) onAdd;
  final Future<void> Function(ContactChipValue chip) onRemove;
  final Future<void> Function() openTouchModal;
  final bool isLast;

  @override
  State<ContactsComposeField> createState() => ContactsComposeFieldState();
}

class ContactsComposeFieldState extends State<ContactsComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _inputFocus = FocusNode();
  late final TextEditingController _controller;
  List<ContactCandidate> _candidates = const [];
  int? _focusedChipIndex;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _inputFocus.addListener(_handleFocusChange);
    _controller.addListener(_handleTextChange);
  }

  @override
  void dispose() {
    _inputFocus.removeListener(_handleFocusChange);
    _controller.removeListener(_handleTextChange);
    _inputFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_inputFocus.hasFocus && hasPhysicalKeyboard()) {
      _refreshCandidates();
      _dropdown.show();
    } else {
      _dropdown.hide();
    }
  }

  void _handleTextChange() {
    if (_controller.text.isNotEmpty && _focusedChipIndex != null) {
      // Typing returns focus to the text input.
      setState(() => _focusedChipIndex = null);
    }
    _refreshCandidates();
  }

  Future<void> _refreshCandidates() async {
    final results = await widget.loadCandidates(_controller.text);
    if (!mounted) return;
    setState(() => _candidates = results);
  }

  Future<void> _handlePicked(ContactCandidate candidate) async {
    await widget.onAdd(candidate);
    _controller.clear();
    _refreshCandidates();
  }

  Future<void> _commitTypedEmail() async {
    final text = EmailParser.normalize(_controller.text);
    if (!EmailParser.isEmail(text)) return;
    await widget.onAdd(InviteEmailCandidate(text));
    _controller.clear();
    _refreshCandidates();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isEmpty = _controller.text.isEmpty;

    // Chip navigation only when the text input is empty.
    if (isEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (widget.chips.isEmpty) return KeyEventResult.ignored;
        setState(() {
          _focusedChipIndex = (_focusedChipIndex ?? widget.chips.length)
              - 1;
          if (_focusedChipIndex! < 0) {
            _focusedChipIndex = widget.chips.length - 1;
          }
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_focusedChipIndex == null) return KeyEventResult.ignored;
        setState(() {
          final next = _focusedChipIndex! + 1;
          _focusedChipIndex = next >= widget.chips.length ? null : next;
        });
        return KeyEventResult.handled;
      }
      if ((event.logicalKey == LogicalKeyboardKey.backspace ||
              event.logicalKey == LogicalKeyboardKey.delete) &&
          _focusedChipIndex != null) {
        final idx = _focusedChipIndex!;
        if (idx < widget.chips.length) {
          widget.onRemove(widget.chips[idx]);
          setState(() {
            _focusedChipIndex = idx == 0 ? null : idx - 1;
          });
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace &&
          widget.chips.isNotEmpty &&
          _focusedChipIndex == null) {
        // Pressing backspace in the empty input focuses the last chip
        // rather than deleting it (matches Gmail / Linear behavior).
        setState(() => _focusedChipIndex = widget.chips.length - 1);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      if (_candidates.isNotEmpty) {
        // ComposeDropdown handles Enter itself when focused; this path
        // covers Tab as a commit affordance.
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          _handlePicked(_candidates.first);
          return KeyEventResult.handled;
        }
      }
      if (EmailParser.isEmail(_controller.text)) {
        _commitTypedEmail();
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.comma &&
        EmailParser.isEmail(_controller.text)) {
      _commitTypedEmail();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _handleChipTap(int idx) async {
    if (isTouchPlatform()) {
      final action = await showComposeChipMenu(
        context,
        chipLabel: widget.chips[idx].label,
      );
      if (action == ComposeChipAction.remove) {
        await widget.onRemove(widget.chips[idx]);
      }
      return;
    }
    final action = await showComposeChipMenu(
      context,
      chipLabel: widget.chips[idx].label,
    );
    if (action == ComposeChipAction.remove) {
      await widget.onRemove(widget.chips[idx]);
    }
  }

  Future<void> _handleRowTap() async {
    if (hasPhysicalKeyboard()) {
      _inputFocus.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.chips.isEmpty ? 'Private — only you' : '';
    return ComposeFieldRow(
      icon: FontAwesomeIcons.user,
      tooltip: 'Share with',
      shortcut:
          platformSingleActivator(LogicalKeyboardKey.keyS, shift: true),
      onTapField: _handleRowTap,
      isLast: widget.isLast,
      child: ComposeDropdown<ContactCandidate>(
        controller: _dropdown,
        items: _candidates,
        itemBuilder: (context, candidate, highlighted) {
          return Container(
            color: highlighted
                ? context.theme.colors.muted.withValues(alpha: 0.15)
                : null,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: Text(candidate.label),
          );
        },
        onSelected: _handlePicked,
        child: Focus(
          focusNode: _inputFocus,
          onKeyEvent: _handleKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 0; i < widget.chips.length; i++)
                  _ChipView(
                    value: widget.chips[i],
                    focused: i == _focusedChipIndex,
                    onTap: () => _handleChipTap(i),
                  ),
                IntrinsicWidth(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 80),
                    child: FTextField(
                      control: .managed(controller: _controller),
                      readOnly: isTouchPlatform(),
                      hint: placeholder,
                      style: FTextFieldStyleDelta.delta(
                        contentPadding: EdgeInsetsGeometryDelta.value(
                          const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipView extends StatelessWidget {
  const _ChipView({
    required this.value,
    required this.focused,
    required this.onTap,
  });

  final ContactChipValue value;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = focused
        ? context.theme.colors.primary
        : context.theme.colors.muted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: focused ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          value.label,
          style: context.theme.typography.sm,
        ),
      ),
    );
  }
}
```

> **Caveats the implementer should sanity-check against the codebase:**
> - The `FTextField` style block strips chrome enough to blend into the row. Verify against existing borderless usages.
> - `Focus(focusNode: _inputFocus, onKeyEvent: ...)` wrapping an `FTextField` causes a focus-ownership conflict — the `FTextField` creates its own internal node by default. Fix: pass `_inputFocus` directly to `FTextField(focusNode: _inputFocus, ...)` and set the key handler via `_inputFocus.onKeyEvent = _handleKey;` in `initState` (drop the outer `Focus` wrapper). Verify against `InlineTitleInput` for the project's existing `FTextField(focusNode: ...)` pattern.
> - The chip-menu call is the same on desktop and touch because the underlying `Modal` adapts. If the desktop popover should be anchored to the chip rather than centered as a dialog, switch to the `Dropdown` infrastructure used by `ComposeDropdown` — `showComposeChipMenu` accepts a `BuildContext` so the anchor can be derived.

- [ ] **Step 2: Re-export**

In `apps/plot/lib/widget/compose/compose.dart`:

```dart
export 'contacts_compose_field.dart';
```

- [ ] **Step 3: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/compose/contacts_compose_field.dart lib/widget/compose/compose.dart
```
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/contacts_compose_field.dart apps/plot/lib/widget/compose/compose.dart
git commit -m "$(cat <<'EOF'
Add ContactsComposeField

Chip+text hybrid with keyboard chip navigation (arrow keys, backspace),
email-pattern auto-commit, click/tap chip-action menu, and a dropdown
of contact/group/invite candidates anchored to the field.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Integrate the compose surface into `NewThreadPage`

**Why:** Replace the old `_buildThreadTypeSelector` chip stack with the new compose surface. Delete the helpers and state that no longer have callers. Wire the new field widgets to existing draft-mutation paths.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`
- Modify: `apps/plot/lib/widget/note_editor.dart` (call site: pass `bodyOnly: true`)
- Delete: `apps/plot/lib/widget/inline_title_input.dart`

- [ ] **Step 1: Replace `_buildThreadTypeSelector`**

Replace the body of `_buildThreadTypeSelector` with:

```dart
Widget _buildComposeSurface(BuildContext context, PriorityState state) {
  final isAuto = ThreadsBase.autoFileIds.contains(
    state.draft.id.toString(),
  );
  final activeChoice = _resolveActiveConnectionChoice(state);
  final connectionCandidates = _rankConnectionChoices();

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PriorityComposeField(
        currentPriority: state.draft.priority,
        isAuto: isAuto,
        onPickAuto: _switchToAuto,
        onPickPriority: _switchToPriority,
        openTouchModal: () => _selectPriority(context, state),
      ),
      ConnectionComposeField(
        activeChoice: activeChoice,
        candidates: connectionCandidates,
        onPicked: _applyConnectionChoice,
        openTouchModal: _openConnectionPicker,
      ),
      ContactsComposeField(
        chips: _resolveContactChips(state),
        loadCandidates: _loadContactCandidates,
        onAdd: _applyContactCandidate,
        onRemove: _removeContactChip,
        openTouchModal: () => _openSharedPicker(context),
      ),
      TitleComposeField(
        title: state.draft.title,
        onChanged: _updateTitle,
        isLast: true,
      ),
    ],
  );
}
```

- [ ] **Step 2: Add the new helpers in `NewThreadPageState`**

Add the following methods. The connection-choice resolver mirrors `_isConnectionActive`/`_activeCreateAction` for the new ConnectionChoice domain:

```dart
ConnectionChoice _resolveActiveConnectionChoice(PriorityState state) {
  final active = state.draftNote.actions
      ?.whereType<CreateLinkUserAction>()
      .firstOrNull;
  if (active == null) return ConnectionChoice.plotThread;
  // Find the matching CreateTarget so the field can show its label.
  for (final target in _allConnectionTargets) {
    if (active.twistInstanceId == target.twist.id.toString() &&
        active.channelId == target.channel.channelId &&
        active.linkType == target.linkType.type) {
      return ConnectionChoice.target(target);
    }
  }
  // Target is not in the loaded list (e.g. action created before we
  // loaded). Fall back to Plot thread so the field always has a value.
  return ConnectionChoice.plotThread;
}

List<ConnectionChoice> _rankConnectionChoices() {
  final ranked = _rankConnections(_allConnectionTargets);
  return [
    ConnectionChoice.plotThread,
    ...ranked.map(ConnectionChoice.target),
  ];
}

List<ContactChipValue> _resolveContactChips(PriorityState state) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final draft = state.draft;
  final chips = <ContactChipValue>[];
  for (final id in draft.groups) {
    final g = Group.fromCache(id);
    if (g != null) chips.add(ContactChipGroup(g));
  }
  for (final id in draft.contacts) {
    if (selfUuids.contains(id)) continue;
    final actor = Actor.fromCache(ActorId.fromUuid(id));
    if (actor != null) chips.add(ContactChipActor(actor));
  }
  for (final email in draft.inviteEmails) {
    chips.add(ContactChipEmail(email));
  }
  return chips;
}

Future<List<ContactCandidate>> _loadContactCandidates(String query) async {
  final priority = context.read<PriorityBloc>().state.draft.priority;
  final sorted =
      await Actor.getSortedShareCandidates(priority: priority);
  final draft = context.read<PriorityBloc>().state.draft;
  final selectedActorIds = draft.contacts.toSet();
  final selectedGroupIds = draft.groups.toSet();
  final selectedEmails = draft.inviteEmails.toSet();

  final lowered = query.trim().toLowerCase();
  final candidates = <ContactCandidate>[];
  for (final c in sorted) {
    if (lowered.isNotEmpty &&
        !c.searchText.toLowerCase().contains(lowered)) {
      continue;
    }
    switch (c) {
      case ActorShareCandidate(:final actor):
        if (selectedActorIds.contains(actor.id.toUuid())) continue;
        candidates.add(ActorCandidate(actor));
      case GroupShareCandidate(:final group):
        if (selectedGroupIds.contains(group.id)) continue;
        candidates.add(GroupCandidate(group));
    }
  }
  if (EmailParser.isEmail(query) &&
      !selectedEmails.contains(EmailParser.normalize(query))) {
    candidates.add(InviteEmailCandidate(EmailParser.normalize(query)));
  }
  return candidates;
}

Future<void> _applyContactCandidate(ContactCandidate candidate) async {
  final bloc = _priorityBloc;
  if (bloc == null) return;
  final draft = bloc.state.draft;
  switch (candidate) {
    case ActorCandidate(:final actor):
      final ids = [...draft.contacts, actor.id.toUuid()];
      await bloc.updateDraft(draft.copyWith(contacts: Value(ids)));
    case GroupCandidate(:final group):
      final ids = [...draft.groups, group.id];
      await bloc.updateDraft(
        draft.copyWith(groups: Value(ids.isEmpty ? null : ids)),
      );
    case InviteEmailCandidate(:final email):
      final emails = [...draft.inviteEmails, email];
      await bloc.updateDraft(
        draft.copyWith(inviteEmails: Value(emails)),
      );
  }
}

Future<void> _removeContactChip(ContactChipValue chip) async {
  final bloc = _priorityBloc;
  if (bloc == null) return;
  final draft = bloc.state.draft;
  switch (chip) {
    case ContactChipActor(:final actor):
      final ids = draft.contacts.where(
        (id) => id != actor.id.toUuid(),
      ).toList();
      await bloc.updateDraft(draft.copyWith(contacts: Value(ids)));
    case ContactChipGroup(:final group):
      final ids = draft.groups.where((id) => id != group.id).toList();
      await bloc.updateDraft(
        draft.copyWith(groups: Value(ids.isEmpty ? null : ids)),
      );
    case ContactChipEmail(:final email):
      final emails =
          draft.inviteEmails.where((e) => e != email).toList();
      await bloc.updateDraft(
        draft.copyWith(
          inviteEmails: Value(emails.isEmpty ? null : emails),
        ),
      );
  }
}

Future<void> _updateTitle(String? next) async {
  final bloc = _priorityBloc;
  if (bloc == null) return;
  await bloc.updateDraft(
    bloc.state.draft.copyWith(title: Value(next)),
  );
}
```

- [ ] **Step 3: Wrap compose surface + body in a single `EditableArea` with widget-order traversal**

In `NewThreadPage.build`, both panel branches use `_buildComposeSurface(...)` followed by `NoteEditor(... bodyOnly: true ...)` inside one outer `EditableArea`. A `FocusTraversalGroup` with `WidgetOrderTraversalPolicy` enforces Tab order = visual order (Priority → Connection → Contacts → Title → Body), since the field widgets are mounted in that order in the Column. This avoids needing to thread explicit traversal-order parameters into every field widget.

```dart
Padding(
  padding: EdgeInsets.symmetric(horizontal: context.contentPaddingH),
  child: EditableArea(
    padding: false,
    position: EditableAreaPosition.bottom,
    flushToBottom: !layoutState.multiPanel,
    builder: (context, focusNode) => FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildComposeSurface(context, state),
          NoteEditor(
            key: _threadEditorKey,
            bodyOnly: true,
            /* ...existing props... */
          ),
        ],
      ),
    ),
  ),
);
```

Mirror the same wrap in the multi-panel branch (current `Padding(horizontal: 20)` block).

> **Layout caveat:** the existing multi-panel branch wraps the compose surface in a `Flexible` constrained-height block. Preserve that constraint pattern; only the inner contents change.

- [ ] **Step 4: Delete the old chip code and state**

Remove from `apps/plot/lib/page/new_thread.dart`:

- `_HoverBuilder` class.
- Fields `_recentCandidates`, `_pinnedActors`, `_pinnedEmails`, `_pinnedGroups`, `_pinnedSuggestions`, `_pinnedConnections`.
- Methods `_loadRecentCandidates`, `_refreshPinnedChips`, `_refreshPinnedConnections`, `_buildThreadTypeSelector`, `_buildTitleRow`, `_buildConnectionRow`, `_buildPriorityChipRow`, `_buildPriorityChip`, `_buildAutoSparklesToggle`, `_buildChipTooltip`, `_buildWithSelector`, `_buildGroupChip`, `_buildLockChip`, `_clearShareTargets`, `_buildContactChip`, `_buildEmailChip`, `_buildAddContactChip`, `_isConnectionActive`, `_activeCreateAction`, `_toggleConnection`, `_toggleWithGroup`, `_toggleWithContact`, `_toggleEmailInvite`.
- Classes `_ConnectionPickerCommand` and `_ShareNewThread`.
- The `_titleInputKey` field and the `_titleInputKey.currentState?.focus()` call in `_buildThreadShortcuts`.

Replace the title-focus shortcut binding with a `GlobalKey<TitleComposeFieldState>` referencing the new `TitleComposeField` (defined inline by promoting `TitleComposeFieldState` to public; already done in Task 8).

Update `_loadRecentCandidates` usages — those calls happen in `_switchToPriority` / `_switchToAuto` / `_initializeDraft`. Replace with no-ops or remove (the new `ContactsComposeField` loads candidates lazily on demand).

Keep the `_loadConnections` / `_allConnectionTargets` flow — it still feeds the new connection field's candidate list.

- [ ] **Step 5: Lint**

```bash
cd apps/plot && flutter analyze lib/page/new_thread.dart lib/widget/note_editor.dart
```
Expected: No issues found.

- [ ] **Step 6: Delete `inline_title_input.dart`**

```bash
git rm apps/plot/lib/widget/inline_title_input.dart
```

Then also remove its export from `apps/plot/lib/widget/widget.dart` (search for `inline_title_input`).

- [ ] **Step 7: Lint full app**

```bash
cd apps/plot && flutter analyze
```
Expected: No new issues.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/lib/widget/note_editor.dart apps/plot/lib/widget/widget.dart apps/plot/lib/widget/inline_title_input.dart
git commit -m "$(cat <<'EOF'
Integrate compose surface into NewThreadPage

Replaces the chip rows above the note editor with the new field
widgets stacked inside one EditableArea. Deletes the chip helpers
and InlineTitleInput; switches the editor to bodyOnly so the outer
surface owns the border/background.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Manual verification

**Why:** UI behavior across desktop and touch is the spec's main acceptance criterion. The `run-app` skill drives the app in an isolated profile.

- [ ] **Step 1: Launch the agent profile via the `run-app` skill**

Invoke the `run-app` skill. The skill encodes the correct `flutter run` invocation for the agent profile.

- [ ] **Step 2: Desktop — tab traversal**

In the running app, navigate to a new-thread page (bottom-nav New button, or `/p/<priority>/new`). Press Tab repeatedly. Verify focus order: Priority → Connection → Contacts → Title → Body. Shift+Tab walks backwards.

- [ ] **Step 3: Desktop — priority dropdown**

Click the priority field (or Tab to it). Confirm:
- Dropdown opens automatically on focus.
- First item is "✨ Auto-organize" when not already auto.
- Arrow keys highlight rows; Enter selects.
- Selecting "Auto-organize" updates the field to "✨ Auto".
- Typing filters the list.
- Escape closes the dropdown.

- [ ] **Step 4: Desktop — connection dropdown**

Tab to the connection field. Confirm:
- Default value is "Plot thread".
- Dropdown opens on focus with Plot thread + all targets.
- Selecting a non-Plot target attaches a `CreateLinkUserAction` (verify by submitting the draft).
- Selecting "Plot thread" clears the `CreateLinkUserAction`.

- [ ] **Step 5: Desktop — contacts field**

Tab to contacts. Confirm:
- Placeholder reads "Private — only you" when empty.
- Typing letters opens dropdown; arrow keys highlight; Enter adds.
- Typing `someone@example.com` and pressing Enter (or `,`) adds it as a pending email invite chip.
- Once chips are present, `←` from the empty cursor focuses the last chip; further `←`/`→` move focus.
- Pressing Backspace on a focused chip removes it; focus shifts to the previous chip.
- Clicking a chip opens a popover with `Remove` (and disabled CC/BCC).

- [ ] **Step 6: Desktop — title**

Tab to title. Confirm:
- Field accepts typing immediately (no chip-expand step).
- Enter commits and moves focus to body.

- [ ] **Step 7: Touch — iOS simulator**

Launch the iOS simulator profile (the `run-app` skill or `flutter run -d <ios>`). Open the new-thread page.
- Tap priority → existing `SelectModal` opens; soft keyboard does NOT show.
- Tap connection → modal opens with Plot thread + targets.
- Tap contacts → existing share modal opens.
- Tap a chip → bottom-sheet modal with `Remove` opens.
- Tap title → soft keyboard opens and accepts input.

- [ ] **Step 8: Cross-cutting**

- Change priority and confirm the contacts and connection candidate lists re-rank when their dropdowns reopen.
- Submit a draft from each path (Plot thread + at least one target connection). Confirm the resulting thread has the expected `CreateLinkUserAction` (or none).

- [ ] **Step 9: Run `/finalize`**

Per the project's change-finalization checklist (`AGENTS.md`), invoke the `finalize` skill to run lint repo-wide and check the rest of the checklist.

- [ ] **Step 10: Commit any finalize follow-ups, if any**

If `finalize` finds issues, fix them inline and commit:

```bash
git add <changed files>
git commit -m "$(cat <<'EOF'
Fix finalize-skill follow-ups for compose redesign

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- The plan assumes the harness can read project files and run `flutter analyze` / `flutter test`. If the API shapes shown (e.g. `FTextFieldStyleDelta`, `FCard` style helpers, `Modal.open` signature) don't match the codebase exactly, prefer the codebase's existing patterns over the literal code in this plan — the design intent is what matters, not the symbol names. The spec is the contract; this plan is the recipe.
- Tasks 1–7 can be parallelized (no inter-dependencies). Tasks 8–12 each depend on 1–7. Task 13 depends on 8–12. Task 14 depends on 13.
- Commits per task. Don't bundle. The verification step at the end is a single sweep, not a per-task gate (UI doesn't render until the integration in Task 13).
