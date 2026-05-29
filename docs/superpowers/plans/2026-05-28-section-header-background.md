# Section-header background Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `headerBackground` into a renamed `pageHeaderBackground` (unchanged) and a new, subtler warm-neutral `sectionHeaderBackground`, then fill the agenda date headers and activity-feed section headings with it and align their text weight.

**Architecture:** Add one getter to `ColourSchemeData` derived from a single relative-darken step over `background` (so it inherits the surface's faint warm chroma and always sits darker than its surface, in both the un-darkened middle panel and the darkened agenda subtree). Apply it as a full-width band behind two existing no-fill header branches in `widget/agenda.dart`, and bump the activity-feed heading text to `w500`.

**Tech Stack:** Flutter/Dart, `forui`, OKLCH colours via `prism_flutter` (`RayOklch`). App-only change in `apps/plot`; no schema/server work.

**Spec:** `docs/superpowers/specs/2026-05-28-section-header-background-design.md`

---

## File Structure

- `apps/plot/lib/style/colors.dart` — rename `headerBackground` → `pageHeaderBackground`; add `sectionHeaderBackground`; fix/expand both doc comments. (Owns all theme colour getters.)
- `apps/plot/lib/page/thread.dart` — one call-site rename.
- `apps/plot/lib/widget/note_viewer.dart` — one call-site rename.
- `apps/plot/lib/widget/agenda.dart` — fill the date-header and activity-feed-heading branches with the new band; add `w500` to the heading text.
- `apps/plot/test/style/colors_test.dart` — **new**: invariant test for the band ordering (`background` lighter than `sectionHeaderBackground` lighter than `pageHeaderBackground`, both modes).
- `docs/updates.md` — optional one-line user note.

---

## Task 1: Colour getters — rename + new section band

**Files:**
- Modify: `apps/plot/lib/style/colors.dart` (getter at `:284`, doc at `:270-291`)
- Modify: `apps/plot/lib/page/thread.dart:1407`
- Modify: `apps/plot/lib/widget/note_viewer.dart:53`
- Test: `apps/plot/test/style/colors_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/style/colors_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/style/colors.dart';

void main() {
  group('header background bands', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      test('sectionHeaderBackground sits between background and page band '
          '($brightness)', () {
        final scheme = ColourSchemeData(
          themeColor: const ThemeColor.defaultColor(),
          brightness: brightness,
        );
        final bg = scheme.background.computeLuminance();
        final section = scheme.sectionHeaderBackground.computeLuminance();
        final page = scheme.pageHeaderBackground.computeLuminance();
        // Darker than the surface it sits on...
        expect(section, lessThan(bg));
        // ...but gentler (lighter) than the heavier page-header bar.
        expect(section, greaterThan(page));
      });
    }
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/style/colors_test.dart`
Expected: FAIL — compile error, `sectionHeaderBackground`/`pageHeaderBackground` not defined on `ColourSchemeData`.
(If it instead fails to compile on *unrelated* generated code, run `flutter pub run build_runner build --delete-conflicting-outputs` once, then re-run.)

- [ ] **Step 3: Rename the getter and add the new band in `colors.dart`**

Replace the existing getter + doc block (currently lines ~270-291, starting at the `/// L3 — section-header background.` comment through the closing `}` of `headerBackground`) with:

```dart
  /// L3 (page) — header-bar band. Used by the thread page header
  /// (`page/thread.dart`) and the note viewer header
  /// (`widget/note_viewer.dart`). A clear, neutral header bar — distinctly
  /// stronger than the subtler [sectionHeaderBackground] used for in-list
  /// section/date headers.
  ///
  /// In light mode a pure-neutral band; in dark mode it inherits the
  /// background's faint warm chroma via [background].
  Color get pageHeaderBackground {
    final relDarken = pow(_darkenFactor, 3).toDouble();
    if (brightness == Brightness.light) {
      final l = (1.0 / darken / relDarken).clamp(0.0, 1.0);
      return RayOklch.fromComponents(l, 0.0, 95).toColor();
    }
    return copyWith(darken: relDarken).background;
  }

  /// L3 (section) — subtle in-list header band. Used by agenda date headers
  /// and PriorityPage activity-feed section headings ("Today"/"New"/...).
  ///
  /// A *gentler* sibling of [pageHeaderBackground]: one relative-darken step
  /// over [background]. Two consequences, both intentional:
  ///   * It stays darker than whatever surface it sits on — the un-darkened
  ///     middle panel (activity feed) and the already-darkened agenda subtree
  ///     (date headers), where the step compounds. Darker, never lighter:
  ///     lighter is reserved for the hover/focus [highlight].
  ///   * It inherits the surface's faint warm chroma (hue 115) instead of
  ///     being flattened to a pure neutral like the light-mode page band.
  /// The single step keeps it well short of [pageHeaderBackground]'s bar.
  Color get sectionHeaderBackground {
    return copyWith(darken: _darkenFactor).background;
  }
```

(Implementation note: `copyWith(darken:)` *multiplies* the current darken, so passing `_darkenFactor` applies exactly one extra step. `1.015` light / `1.05` dark. This is the starting candidate — Task 3 may bump it to `pow(_darkenFactor, 2)` if it reads too faint in-app.)

- [ ] **Step 4: Update the two call sites and confirm no stragglers**

In `apps/plot/lib/page/thread.dart:1407`:
```dart
        color: context.colour.pageHeaderBackground,
```
In `apps/plot/lib/widget/note_viewer.dart:53`:
```dart
        color: context.colour.pageHeaderBackground,
```
Then confirm nothing else still references the old name:

Run: `cd apps/plot && grep -rn "\.headerBackground\b" lib test`
Expected: no output (empty). If anything prints, rename it to `pageHeaderBackground` (or `sectionHeaderBackground` if it's an agenda/section header — but there should be none).

- [ ] **Step 5: Run the test and analyze**

Run: `cd apps/plot && flutter test test/style/colors_test.dart`
Expected: PASS (both light and dark cases).

Run: `cd apps/plot && flutter analyze lib/style/colors.dart lib/page/thread.dart lib/widget/note_viewer.dart test/style/colors_test.dart`
Expected: No issues (no `undefined_getter`, no unused imports).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/style/colors.dart apps/plot/lib/page/thread.dart apps/plot/lib/widget/note_viewer.dart apps/plot/test/style/colors_test.dart
git commit -m "flutter(theme): split header band into page + subtle section bands

Rename headerBackground -> pageHeaderBackground (unchanged value) and add
sectionHeaderBackground: one relative-darken step over background, so it
inherits the surface warmth and stays darker-than-surface yet gentler than
the page-header bar."
```

---

## Task 2: Apply the section band in the agenda + heading weight

**Files:**
- Modify: `apps/plot/lib/widget/agenda.dart` (date-header return `:324-327`; activity-heading branch `:424-428`; heading text style `:350-354`)

No automated test: this is pure styling (a fill + a font weight). Widget golden tests for a sub-0.02-lightness band are fragile and the project steers away from running the full Flutter suite from an agent (codegen dependency). Correctness here is the analyzer (Step 4) plus the in-app visual check in Task 3.

- [ ] **Step 1: Fill the date-header band**

In `agenda.dart`, replace the date-header return (lines ~324-327):
```dart
      // Symmetric vertical padding around each header.
      return Padding(
        padding: EdgeInsets.symmetric(vertical: spacing.sm),
        child: child,
      );
```
with a full-width band behind it:
```dart
      // A subtle full-width band sets each day apart; the symmetric vertical
      // padding keeps the label breathing inside it.
      return DecoratedBox(
        decoration: BoxDecoration(color: context.colour.sectionHeaderBackground),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: spacing.sm),
          child: child,
        ),
      );
```

- [ ] **Step 2: Fill the activity-feed heading band**

In the `isTextOnlyHeading` branch (lines ~424-428):
```dart
      if (isTextOnlyHeading) {
        result = Padding(
          padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
          child: child,
        );
      } else {
```
wrap the `Padding` in the same band:
```dart
      if (isTextOnlyHeading) {
        result = DecoratedBox(
          decoration:
              BoxDecoration(color: context.colour.sectionHeaderBackground),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
            child: child,
          ),
        );
      } else {
```

- [ ] **Step 3: Match the heading text to the weekday label weight**

In the text-only heading `child` (lines ~350-354), the `Text` currently uses bare `timeStyle` (default `w400`). The agenda date header's weekday label is `veryMuted` + `typography.sm` + `w500`; `timeStyle` is already `veryMuted` + `sm`, so only the weight is missing. Change just this `Text`'s style (do **not** edit the shared `timeStyle`, which gap/event times also use):
```dart
          child = Center(
            child: Text(
              centerText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: timeStyle.copyWith(fontWeight: FontWeight.w500),
            ),
          );
```

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/agenda.dart`
Expected: No issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/agenda.dart
git commit -m "flutter(agenda): subtle band behind date + section headers

Fill the agenda date headers and activity-feed section headings with the new
sectionHeaderBackground, and bump the heading text to w500 so it matches the
date header's weekday label."
```

---

## Task 3: In-app tuning, docs, finalize

**Files:**
- Possibly modify: `apps/plot/lib/style/colors.dart` (the `sectionHeaderBackground` step, only if tuning needs it)
- Optional: `docs/updates.md`

- [ ] **Step 1: View it in the running app (light + dark)**

Launch via the `run-app` skill. Navigate to a view with the agenda (date headers visible) and a priority's activity feed (`Today`/`New`/`Scheduled`/`Done` headings). Confirm in **both** light and dark mode:
- A subtle warm band sits behind the date headers and the section headings.
- The band is **darker** than its surrounding surface (it must not look like the lighter hover/focus highlight).
- It reads clearly **gentler** than the thread page header bar (open a thread to compare).
- `veryMuted` heading text stays legible on the band; the heading weight matches the weekday label.

- [ ] **Step 2: Tune the step only if needed**

If the band is too faint to register, bump the step in `colors.dart`:
```dart
  Color get sectionHeaderBackground {
    return copyWith(darken: pow(_darkenFactor, 2).toDouble()).background;
  }
```
Hot reload and re-check. If too strong (competing with the page bar), keep the single `_darkenFactor` step. Then re-run `flutter test test/style/colors_test.dart` — the ordering invariant must still hold (`background` > `section` > `page`). If you changed it, commit:
```bash
git add apps/plot/lib/style/colors.dart
git commit -m "flutter(theme): tune sectionHeaderBackground step after in-app review"
```

- [ ] **Step 3: Optional docs/updates.md line**

Only if judged user-noticeable. If so, add to the top section of `docs/updates.md`:
```markdown
- Agenda day headers and activity section headers now sit on a subtle band for easier scanning.
```
Commit:
```bash
git add docs/updates.md
git commit -m "docs(updates): note subtle section-header band"
```

- [ ] **Step 4: Finalize**

Run the `/finalize` checklist (lint on changed packages, backwards-compat, error capture, docs, public-submodule — most are N/A for an app-only styling change, but run it to confirm).

---

## Self-Review

**Spec coverage:**
- Rename `headerBackground` → `pageHeaderBackground` (unchanged value) → Task 1, Steps 3-4. ✓
- New warm-neutral, darker-than-surface, gentler `sectionHeaderBackground` → Task 1, Step 3. ✓
- Apply to agenda date headers + activity-feed section headings; gap/now headers untouched → Task 2, Steps 1-2 (only the `date != null` and `isTextOnlyHeading` branches). ✓
- Heading text `w500` to match weekday label → Task 2, Step 3. ✓
- Doc-comment cleanup → Task 1, Step 3. ✓
- In-app tuning of the OKLCH step + dark-mode check → Task 3, Steps 1-2. ✓
- Optional docs line / finalize → Task 3, Steps 3-4. ✓

**Placeholder scan:** No TBD/TODO. The only "to be decided" is the OKLCH step, which is an explicit, bounded in-app tuning decision (single step vs. `pow(_,2)`) with concrete code for both, guarded by the invariant test — not an open placeholder.

**Type consistency:** Getter names `pageHeaderBackground` / `sectionHeaderBackground` are used identically across colors.dart, thread.dart, note_viewer.dart, agenda.dart, and the test. `copyWith(darken:)`, `background`, `_darkenFactor`, `RayOklch.fromComponents`, `ThemeColor.defaultColor()`, and `Color.computeLuminance()` all match existing signatures in `colors.dart`/the framework.
