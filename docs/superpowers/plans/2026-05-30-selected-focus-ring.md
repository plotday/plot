# Selected Focus Selection Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the selected focus in the left-panel sidebar clearly distinct by drawing the agent/activity-feed selection ring — a 1px border in the focus's own color — around the selected rounded tile, without shifting any content.

**Architecture:** Add a centralized per-focus ring-color helper (`borderFromTheme`) alongside the existing `backgroundFromTheme`. Add an opt-in `selectedBorderColor` to the shared `ListTile` so rounded tiles can render a constant-width border (transparent when unselected, the ring color when selected). The sidebar focus tiles and fixed Inbox/Everything tiles opt in; nothing else is restyled.

**Tech Stack:** Flutter (widgets-only + forui), Dart, OKLCH color helpers (`package:ray`), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-05-30-selected-focus-ring-design.md`

**Status:** Implemented (all four code commits landed). Remaining: run-app visual verification.

---

## Background facts (verified in the codebase)

- `OklchColours` lives in `apps/plot/lib/style/colors.dart` (class at line ~17) and holds private `_themeColor` / `_brightness` fields. It is normally reached via `ColourSchemeData(themeColor:, brightness:).colours` (the `.colours` getter returns the `OklchColours`); this is exactly how `apps/plot/test/style/colors_test.dart` constructs it. `backgroundFromTheme(ThemeColor?)` returns a per-color tinted `accentBackground` and is the template for the new helper.
- The OKLCH value `accentBackground` (a `package:ray` color) supports `.withHue()`, `.withChroma()`, `.withLightness()`, and `.toColor()`. The agent/activity feed's selected border already uses `accentBackground.withLightness(0.85 light / 0.35 dark)` in `ListTile`.
- `apps/plot/lib/widget/list_tile.dart`: `selectedBorder` defaults to `true`; the border is drawn in the `BoxDecoration`. When `borderRadius != null` the border was `null` — so rounded tiles never got a ring before this change.
- Sidebar focus tiles: `apps/plot/lib/widget/priority.dart` (`PriorityWidget`) passes `borderRadius` + `selectedColor: priorityAccentBg` + `highlightColor: priorityAccentBg`; `priorityAccentBg` is computed from `backgroundFromTheme(priority.displayColor)`. Left-panel mode is `monochrome == true`.
- Fixed tiles: `apps/plot/lib/widget/priorities_list.dart` `_FixedFocusTile` builds a `ListTile` with `selectedColor: accentBg` / `highlightColor: accentBg`; `accentBg` from `backgroundFromTheme(tileColor)` where `tileColor = const ThemeColor.defaultColor()`.
- Existing pure-color unit tests live in `apps/plot/test/style/colors_test.dart`.

All commands below assume the working directory is `apps/plot` unless noted.

---

## File Structure

- **Modify** `apps/plot/lib/style/colors.dart` — add `borderFromTheme(ThemeColor?)` to `OklchColours`.
- **Create** `apps/plot/test/style/border_from_theme_test.dart` — unit tests for the new helper.
- **Modify** `apps/plot/lib/widget/list_tile.dart` — add `selectedBorderColor` field + constant-width rounded-border logic.
- **Modify** `apps/plot/lib/widget/priority.dart` — compute and pass the per-focus ring color (left panel only).
- **Modify** `apps/plot/lib/widget/priorities_list.dart` — same for `_FixedFocusTile` (Inbox/Everything).

---

### Task 1: Add `borderFromTheme` to `OklchColours`  ✅ done

**Files:**
- Test: `apps/plot/test/style/border_from_theme_test.dart`
- Modify: `apps/plot/lib/style/colors.dart` (after `backgroundFromTheme`)

- [x] **Step 1: Write the failing test**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';

void main() {
  group('OklchColours.borderFromTheme', () {
    OklchColours coloursFor(Brightness brightness) => ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: brightness,
    ).colours;

    test('ring differs from the tint background (more visible) in light mode', () {
      final colours = coloursFor(Brightness.light);
      const purple = ThemeColor(2);
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring differs from the tint background in dark mode', () {
      final colours = coloursFor(Brightness.dark);
      const purple = ThemeColor(2);
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring is fully opaque', () {
      final colours = coloursFor(Brightness.light);
      expect(colours.borderFromTheme(const ThemeColor(2)).opacity, 1.0);
    });

    test('ring hue tracks the focus color (different colors → different rings)', () {
      final colours = coloursFor(Brightness.light);
      expect(
        colours.borderFromTheme(const ThemeColor(2)), // purple
        isNot(equals(colours.borderFromTheme(const ThemeColor(4)))), // red
      );
    });

    test('null color falls back to the default focus color', () {
      final colours = coloursFor(Brightness.light);
      expect(
        colours.borderFromTheme(null),
        equals(colours.borderFromTheme(const ThemeColor.defaultColor())),
      );
    });
  });
}
```

> Note: this codebase's Flutter SDK exposes alpha as `Color.opacity` (the `.a` accessor is not available), hence the opacity assertion above.

- [x] **Step 2: Run to verify it fails** — `flutter test test/style/border_from_theme_test.dart` → FAIL (`borderFromTheme` not defined).

- [x] **Step 3: Implement `borderFromTheme`** — in `apps/plot/lib/style/colors.dart`, after `backgroundFromTheme`:

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

- [x] **Step 4: Run to verify it passes** — all 5 tests PASS.
- [x] **Step 5: Commit** — `focus: add borderFromTheme helper for selection ring`.

---

### Task 2: Add `selectedBorderColor` to `ListTile` (constant-width rounded border)  ✅ done

**Files:** `apps/plot/lib/widget/list_tile.dart`

- [x] **Step 1: Add the constructor parameter** — after `this.selectedColor,` add `this.selectedBorderColor,`.

- [x] **Step 2: Add the field declaration** — after `final Color? selectedColor;`:

```dart
  /// When non-null, the tile reserves a constant 1px border that paints this
  /// colour while selected and transparent otherwise — so selection never
  /// shifts content. For rounded tiles (non-null [borderRadius]) this is the
  /// only way the selection ring is drawn; rounded tiles with a null
  /// [selectedBorderColor] keep their borderless behaviour.
  final Color? selectedBorderColor;
```

- [x] **Step 3: Replace the border logic** with:

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

- [x] **Step 4: Analyze** — `flutter analyze lib/widget/list_tile.dart` → no issues.
- [x] **Step 5: Commit** — `focus: add opt-in selectedBorderColor to ListTile`.

---

### Task 3: Draw the ring on sidebar focus tiles (`PriorityWidget`)  ✅ done

**Files:** `apps/plot/lib/widget/priority.dart`

- [x] **Step 1: Compute the ring color** — after the `priorityAccentBg` assignment:

```dart
    // The selected focus gets a crisp ring in its own colour (see the
    // agent/activity feed). Only in the left-panel monochrome frame — single-
    // panel mode keeps the plain edge-to-edge treatment.
    final priorityRing = widget.monochrome
        ? buildContext.colour.colours.borderFromTheme(priority.displayColor)
        : null;
```

- [x] **Step 2: Pass it to the `ListTile`** — add `selectedBorderColor: priorityRing,` after `selectedColor: priorityAccentBg,`.
- [x] **Step 3: Analyze** — no issues.
- [x] **Step 4: Commit** — `focus: draw selection ring on sidebar focus tiles`.

---

### Task 4: Draw the ring on the fixed Inbox/Everything tiles (`_FixedFocusTile`)  ✅ done

**Files:** `apps/plot/lib/widget/priorities_list.dart`

- [x] **Step 1: Compute the ring color** — after the `accentBg` assignment:

```dart
    // Matching selection ring for the fixed tiles, in the Resolution/brand
    // colour they already render in.
    final ringColor = widget.monochrome
        ? context.colour.colours.borderFromTheme(tileColor)
        : null;
```

- [x] **Step 2: Pass it to the `ListTile`** — add `selectedBorderColor: ringColor,` after `selectedColor: accentBg,`.
- [x] **Step 3: Analyze** — no issues.
- [x] **Step 4: Commit** — `focus: draw selection ring on Inbox and Everything tiles`.

---

### Task 5: Full analyze + visual verification

**Files:** `docs/updates.md` (+ verification only).

- [x] **Step 1:** `flutter test test/style/border_from_theme_test.dart` PASS; `flutter analyze` on the four changed app files reports no new issues.
- [ ] **Step 2:** Launch the app (`run-app` skill) and verify resting / hover / selected for a focus tile, Inbox, Everything, and the priorities search list, in light and dark mode.
- [ ] **Step 3:** Confirm no content shift — title/icon do not move by 1px on selection toggle.
- [x] **Step 4:** Add a plain-language bullet to the top of `docs/updates.md`.
- [ ] **Step 5:** Run `/finalize` (no public-submodule changes involved).

---

## Self-Review

**Spec coverage:**
- Root-cause (rounded tiles skip the border) → Task 2.
- Focus-hued ring matching the feed's lightness → Task 1 (`borderFromTheme` = `backgroundFromTheme` + `.withLightness(0.85/0.35)`).
- Hover/selected backgrounds unchanged → Tasks 3/4 only add `selectedBorderColor`.
- No content shift (constant-width reserved border) → Task 2 border always `width: 1`, transparent when unselected; Task 5 Step 3 verifies.
- Opt-in / no unrelated restyle → Task 2 rounded branch is `null` unless `selectedBorderColor` is provided; only `PriorityWidget` and `_FixedFocusTile` opt in.
- Priorities search list benefits → reuses `PriorityWidget` (Task 3).
- Single-panel unchanged → Tasks 3/4 pass `null` when `!monochrome`.
