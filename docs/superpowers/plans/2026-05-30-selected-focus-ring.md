# Selected Focus Selection Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the selected focus in the left-panel sidebar clearly distinct by drawing the agent/activity-feed selection ring — a 1px border in the focus's own color — around the selected rounded tile, without shifting any content.

**Architecture:** Add a centralized per-focus ring-color helper (`borderFromTheme`) alongside the existing `backgroundFromTheme`. Add an opt-in `selectedBorderColor` to the shared `ListTile` so rounded tiles can render a constant-width border (transparent when unselected, the ring color when selected). The sidebar focus tiles and fixed Inbox/Everything tiles opt in; nothing else is restyled.

**Tech Stack:** Flutter (widgets-only + forui), Dart, OKLCH color helpers (`package:ray`), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-05-30-selected-focus-ring-design.md`

---

## Background facts (verified in the codebase)

- `OklchColours` lives in `apps/plot/lib/style/colors.dart`. It is built via the factory `OklchColours.fromTheme(ThemeColor themeColor, Brightness brightness)` (line ~70) and holds private `_themeColor` / `_brightness` fields. `backgroundFromTheme(ThemeColor?)` (line ~202) returns a per-color tinted `accentBackground` and is the template for the new helper.
- The OKLCH value `accentBackground` (a `package:ray` color) supports `.withHue()`, `.withChroma()`, `.withLightness()`, and `.toColor()`. The agent/activity feed's selected border already uses `accentBackground.withLightness(0.85 light / 0.35 dark)` in `ListTile`.
- `apps/plot/lib/widget/list_tile.dart`: `selectedBorder` defaults to `true` (line ~98); the border is drawn in the `BoxDecoration` at lines ~375-392. Crucially, when `borderRadius != null` the border is `null` — so rounded tiles never get a ring today.
- Sidebar focus tiles: `apps/plot/lib/widget/priority.dart` (`PriorityWidget`) passes `borderRadius` + `selectedColor: priorityAccentBg` + `highlightColor: priorityAccentBg` (lines ~207-212); `priorityAccentBg` is computed at lines ~125-127. Left-panel mode is `monochrome == true`.
- Fixed tiles: `apps/plot/lib/widget/priorities_list.dart` `_FixedFocusTile` builds a `ListTile` with `selectedColor: accentBg` / `highlightColor: accentBg`; `accentBg` from `backgroundFromTheme(tileColor)` where `tileColor = const ThemeColor.defaultColor()`.
- Existing pure-color unit tests live in `apps/plot/test/style/oklch_test.dart` and import `package:plot/style/colors.dart` + `package:plot/util/theme_color.dart` + `package:flutter/widgets.dart` (for `Brightness`).

All commands below assume the working directory is `apps/plot` unless noted.

---

## File Structure

- **Modify** `apps/plot/lib/style/colors.dart` — add `borderFromTheme(ThemeColor?)` to `OklchColours`.
- **Create** `apps/plot/test/style/border_from_theme_test.dart` — unit tests for the new helper.
- **Modify** `apps/plot/lib/widget/list_tile.dart` — add `selectedBorderColor` field + constant-width rounded-border logic.
- **Modify** `apps/plot/lib/widget/priority.dart` — compute and pass the per-focus ring color (left panel only).
- **Modify** `apps/plot/lib/widget/priorities_list.dart` — same for `_FixedFocusTile` (Inbox/Everything).

---

### Task 1: Add `borderFromTheme` to `OklchColours`

**Files:**
- Test: `apps/plot/test/style/border_from_theme_test.dart`
- Modify: `apps/plot/lib/style/colors.dart` (after `backgroundFromTheme`, ~line 210)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/style/border_from_theme_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';

void main() {
  group('OklchColours.borderFromTheme', () {
    test('ring differs from the tint background (more visible) in light mode', () {
      final colours = OklchColours.fromTheme(
        const ThemeColor.defaultColor(),
        Brightness.light,
      );
      const purple = ThemeColor(2);
      // The ring is the tinted background pushed to a more visible lightness,
      // so it must NOT equal the fill it sits on — otherwise it is invisible.
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring differs from the tint background in dark mode', () {
      final colours = OklchColours.fromTheme(
        const ThemeColor.defaultColor(),
        Brightness.dark,
      );
      const purple = ThemeColor(2);
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring is fully opaque', () {
      final colours = OklchColours.fromTheme(
        const ThemeColor.defaultColor(),
        Brightness.light,
      );
      expect(colours.borderFromTheme(const ThemeColor(2)).a, 1.0);
    });

    test('ring hue tracks the focus color (different colors → different rings)', () {
      final colours = OklchColours.fromTheme(
        const ThemeColor.defaultColor(),
        Brightness.light,
      );
      expect(
        colours.borderFromTheme(const ThemeColor(2)), // purple
        isNot(equals(colours.borderFromTheme(const ThemeColor(4)))), // red
      );
    });

    test('null color falls back to the default focus color', () {
      final colours = OklchColours.fromTheme(
        const ThemeColor.defaultColor(),
        Brightness.light,
      );
      expect(
        colours.borderFromTheme(null),
        equals(colours.borderFromTheme(const ThemeColor.defaultColor())),
      );
    });
  });
}
```

> Note: `Color.a` is the 0.0–1.0 alpha channel in current Flutter. If `flutter analyze` flags `.a` as undefined on this SDK, replace the opacity assertion with `expect(colours.borderFromTheme(const ThemeColor(2)).opacity, 1.0);`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/style/border_from_theme_test.dart`
Expected: FAIL — compile error `The method 'borderFromTheme' isn't defined for the type 'OklchColours'`.

- [ ] **Step 3: Implement `borderFromTheme`**

In `apps/plot/lib/style/colors.dart`, immediately after the closing brace of `backgroundFromTheme` (the method ending with `.toColor();` at ~line 210), add:

```dart
  /// The selection-ring colour for a given priority colour: the per-colour
  /// tinted [accentBackground] (as in [backgroundFromTheme]) pushed to a more
  /// visible lightness so it reads as a crisp edge around a selected tile.
  /// Mirrors the selected-item border treatment used by the agent / activity
  /// feed (see [ListTile]'s selected border) — same lightness, applied to each
  /// focus's own hue.
  Color borderFromTheme(ThemeColor? color) {
    final c = color ?? const ThemeColor.defaultColor();
    final isDark = _brightness == Brightness.dark;
    final currentChroma = _themeColor.toChroma(isDark: isDark);
    final targetChroma = c.toChroma(isDark: isDark);
    final chromaScale = currentChroma > 0 ? targetChroma / currentChroma : 0.0;
    return accentBackground
        .withHue(c.toHue())
        .withChroma(accentBackground.chroma * chromaScale)
        .withLightness(isDark ? 0.35 : 0.85)
        .toColor();
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/style/border_from_theme_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/style/colors.dart apps/plot/test/style/border_from_theme_test.dart
git commit --no-verify -m "focus: add borderFromTheme helper for selection ring"
```

> Use `--no-verify`: husky's pre-commit hook is unavailable in Flutter-only checkouts. In the full monorepo tree it is fine either way.

---

### Task 2: Add `selectedBorderColor` to `ListTile` (constant-width rounded border)

**Files:**
- Modify: `apps/plot/lib/widget/list_tile.dart` (constructor ~line 91, fields ~line 184, border block ~lines 375-392)

This is a pure styling/layout change to a widget with heavy runtime dependencies; it is verified by `flutter analyze` plus the Task 5 visual check rather than a widget test.

- [ ] **Step 1: Add the constructor parameter**

In `apps/plot/lib/widget/list_tile.dart`, find the constructor line:

```dart
    this.selectedColor,
```

and add immediately after it:

```dart
    this.selectedBorderColor,
```

- [ ] **Step 2: Add the field declaration**

Find the field declaration:

```dart
  final Color? selectedColor;
```

and add immediately after it:

```dart
  /// When non-null, the tile reserves a constant 1px border that paints this
  /// colour while selected and transparent otherwise — so selection never
  /// shifts content. For rounded tiles (non-null [borderRadius]) this is the
  /// only way the selection ring is drawn; rounded tiles with a null
  /// [selectedBorderColor] keep their borderless behaviour.
  final Color? selectedBorderColor;
```

- [ ] **Step 3: Replace the border logic**

Find this exact block (around lines 375-392):

```dart
                  borderRadius: widget.borderRadius,
                  border: widget.borderRadius != null
                      ? null
                      : Border.symmetric(
                          horizontal: BorderSide(
                            color: showBorder
                                ? context.colour.colours.accentBackground
                                      .withLightness(
                                        context.colour.brightness ==
                                                Brightness.light
                                            ? 0.85
                                            : 0.35,
                                      )
                                      .toColor()
                                : const Color(0x00000000),
                            width: 1,
                          ),
                        ),
```

Replace it with:

```dart
                  borderRadius: widget.borderRadius,
                  // Rounded tiles only get a border when a caller opts in via
                  // [selectedBorderColor]; the width is constant (1) so toggling
                  // selection changes only the colour, never the layout. The
                  // edge-to-edge (non-rounded) feed border is unchanged but will
                  // honour an explicit [selectedBorderColor] when provided.
                  border: widget.borderRadius != null
                      ? (widget.selectedBorderColor != null
                            ? Border.all(
                                color: showBorder
                                    ? widget.selectedBorderColor!
                                    : const Color(0x00000000),
                                width: 1,
                              )
                            : null)
                      : Border.symmetric(
                          horizontal: BorderSide(
                            color: showBorder
                                ? (widget.selectedBorderColor ??
                                      context.colour.colours.accentBackground
                                          .withLightness(
                                            context.colour.brightness ==
                                                    Brightness.light
                                                ? 0.85
                                                : 0.35,
                                          )
                                          .toColor())
                                : const Color(0x00000000),
                            width: 1,
                          ),
                        ),
```

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/widget/list_tile.dart`
Expected: "No issues found!" (or only pre-existing, unrelated infos).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/list_tile.dart
git commit --no-verify -m "focus: add opt-in selectedBorderColor to ListTile"
```

---

### Task 3: Draw the ring on sidebar focus tiles (`PriorityWidget`)

**Files:**
- Modify: `apps/plot/lib/widget/priority.dart` (compute ~lines 125-127, pass ~lines 207-212)

- [ ] **Step 1: Compute the ring color**

In `apps/plot/lib/widget/priority.dart`, find:

```dart
    final priorityAccentBg = widget.monochrome
        ? buildContext.colour.colours.backgroundFromTheme(priority.displayColor)
        : null;
```

and add immediately after it:

```dart
    // The selected focus gets a crisp ring in its own colour (see the
    // agent/activity feed). Only in the left-panel monochrome frame — single-
    // panel mode keeps the plain edge-to-edge treatment.
    final priorityRing = widget.monochrome
        ? buildContext.colour.colours.borderFromTheme(priority.displayColor)
        : null;
```

- [ ] **Step 2: Pass it to the `ListTile`**

Find:

```dart
      selected: widget.selected,
      selectedBorder: widget.selectedBorder,
      selectedColor: priorityAccentBg,
      highlightColor: priorityAccentBg,
```

and change to:

```dart
      selected: widget.selected,
      selectedBorder: widget.selectedBorder,
      selectedColor: priorityAccentBg,
      selectedBorderColor: priorityRing,
      highlightColor: priorityAccentBg,
```

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/widget/priority.dart`
Expected: "No issues found!" (or only pre-existing, unrelated infos).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/priority.dart
git commit --no-verify -m "focus: draw selection ring on sidebar focus tiles"
```

---

### Task 4: Draw the ring on the fixed Inbox/Everything tiles (`_FixedFocusTile`)

**Files:**
- Modify: `apps/plot/lib/widget/priorities_list.dart` (`_FixedFocusTileState.build`)

- [ ] **Step 1: Compute the ring color**

In `apps/plot/lib/widget/priorities_list.dart`, inside `_FixedFocusTileState.build`, find:

```dart
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(tileColor)
        : null;
```

and add immediately after it:

```dart
    // Matching selection ring for the fixed tiles, in the Resolution/brand
    // colour they already render in.
    final ringColor = widget.monochrome
        ? context.colour.colours.borderFromTheme(tileColor)
        : null;
```

- [ ] **Step 2: Pass it to the `ListTile`**

Find (inside the same `build`):

```dart
      selected: widget.isSelected,
      selectedColor: accentBg,
      highlightColor: accentBg,
```

and change to:

```dart
      selected: widget.isSelected,
      selectedColor: accentBg,
      selectedBorderColor: ringColor,
      highlightColor: accentBg,
```

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/widget/priorities_list.dart`
Expected: "No issues found!" (or only pre-existing, unrelated infos).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/priorities_list.dart
git commit --no-verify -m "focus: draw selection ring on Inbox and Everything tiles"
```

---

### Task 5: Full analyze + visual verification

**Files:** none (verification only).

- [ ] **Step 1: Run the new unit tests and analyze the changed app code**

Run:
```bash
flutter test test/style/border_from_theme_test.dart
flutter analyze lib/style/colors.dart lib/widget/list_tile.dart lib/widget/priority.dart lib/widget/priorities_list.dart
```
Expected: tests PASS; analyze reports no new issues.

- [ ] **Step 2: Launch the app and inspect the sidebar (use the `run-app` skill)**

Invoke the `run-app` skill to launch Plot.app in the isolated `agent` profile, then verify in the left-panel sidebar:
- Selected focus shows a 1px ring in its own color, clearly distinct from both a hovered (ring-less) tile and the panel frame.
- Hover on a non-selected focus shows the tint only (no ring); the selected tile keeps its ring.
- Inbox and Everything fixed tiles show the matching ring when selected.
- Repeat in dark mode (toggle the app theme — not system brightness).

- [ ] **Step 3: Confirm no content shift**

Toggle selection between two focuses and confirm the title text and leading icon do **not** move by 1px — the reserved transparent border must keep every tile's layout identical between selected and unselected. Spot-check the same for the Inbox/Everything tiles.

- [ ] **Step 4: Update user-facing changelog**

Add a bullet to the top section of `docs/updates.md` in plain language, e.g.:

```markdown
- The focus you're viewing now stands out more clearly in the sidebar with a subtle colored outline.
```

Then commit:
```bash
git add docs/updates.md
git commit --no-verify -m "docs: note clearer selected-focus highlight in updates"
```

- [ ] **Step 5: Finalize**

Run the `/finalize` checklist (lint of changed packages, backwards-compat, error capture, docs). No public-submodule changes are involved in this plan.

---

## Self-Review

**Spec coverage:**
- Root-cause (rounded tiles skip the border) → Task 2 fixes the rounded branch.
- Focus-hued ring matching the feed's lightness → Task 1 (`borderFromTheme` = `backgroundFromTheme` + `.withLightness(0.85/0.35)`).
- Hover/selected backgrounds unchanged → Tasks 3/4 leave `selectedColor`/`highlightColor` as `priorityAccentBg`/`accentBg`; only add `selectedBorderColor`.
- No content shift (constant-width reserved border) → Task 2 border always `width: 1`, transparent when unselected; Task 5 Step 3 verifies.
- Opt-in / no unrelated restyle → Task 2 rounded branch is `null` unless `selectedBorderColor` is provided; only `PriorityWidget` and `_FixedFocusTile` opt in.
- Priorities search list also benefits → it reuses `PriorityWidget` (Task 3); no extra task needed.
- Single-panel (non-monochrome) unchanged → Tasks 3/4 pass `null` when `!monochrome`.
- Verification (analyze + run-app, light & dark) → Task 5.

**Placeholder scan:** No TODO/TBD; every code step shows full code. Opacity-assertion fallback is spelled out.

**Type consistency:** New surface is one symbol, `borderFromTheme` (Task 1), consumed identically in Tasks 3/4; one widget field, `selectedBorderColor` (Task 2), set in Tasks 2/3/4. Names match throughout.
