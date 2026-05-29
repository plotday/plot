# Section-header background — design

- **Date:** 2026-05-28
- **Status:** Approved (ready for implementation plan)
- **Area:** Flutter app (`apps/plot`)

## Summary

Split today's single `headerBackground` colour into two clearly-named bands and
re-introduce a subtle fill on the agenda date headers and the activity-feed
section headings (`Today` / `New` / `Scheduled` / `Done`), which currently render
as no-fill dividers. The new section band is more subtle than the band used by
the thread page header — a *smaller, darker* step over its surrounding surface —
and carries the same faint warmth the app background already has rather than
being flattened to a pure neutral. The activity-feed heading text is restyled to
match the agenda date header's weekday label.

## Goals

- Two obviously-distinct, well-named colour getters: a page-header band and a
  subtler section-header band.
- Re-introduce a quiet fill behind agenda date headers and activity-feed section
  headings so each reads as a band, not just whitespace.
- Keep the section band *more subtle* than the page band: darker than its
  surrounding surface (never lighter — lighter is reserved for the hover/focus
  `highlight`), but a smaller step.
- Give the section band a touch of chroma, matching the warm tint the `background`
  surface already carries (hue 115, ~0.01 light / ~0.006 dark) — not a
  priority-hue tint, and not a flat neutral.
- Restyle the activity-feed section heading text to match the date header's
  weekday label.

## Non-goals

- No change to the page-header band's value — `thread.dart` and `note_viewer.dart`
  keep exactly today's colour; only its name changes.
- No priority-hue tint on the section band (the warmth comes from the existing
  background hue, same as every other neutral surface).
- No change to gap/time headers or "now" headers — they stay no-fill.
- No new theme infrastructure beyond one getter + a rename.

## Current state (what exists today)

- **`ColourSchemeData.headerBackground`** (`lib/style/colors.dart:284`,
  documented as "L3 — section-header background"): in light mode a pure-neutral
  band, `RayOklch.fromComponents(l, 0.0, 95)` with `l = 1.0/darken/relDarken`,
  `relDarken = _darkenFactor^3` (chroma **0**); in dark mode
  `copyWith(darken: relDarken).background` (which keeps the background's ~0.006
  warm chroma). Its doc comment claims it's used by agenda date headers, agenda
  gap headers, and activity-feed section headers — this is **stale**.
- **Actual usages** (only two, both header *bars* with a bottom border):
  - `lib/page/thread.dart:1407` — thread page header.
  - `lib/widget/note_viewer.dart:53` — note viewer header.
- **Agenda date headers** (`lib/widget/agenda.dart`, the `date != null` branch
  ~line 244): render with **no fill** — a `Row` (gutter month+day, weekday, add
  button) inside a `Padding`, separation from symmetric vertical spacing only.
  Weekday label style (`labelStyle`, ~line 252): `plotColors.veryMuted`,
  `typography.sm.fontSize`, `FontWeight.w500`. The day number (`dayStyle`) is
  `muted` + `w700`.
- **Activity-feed section headings** (`lib/widget/agenda.dart`, the
  `isTextOnlyHeading` branch ~line 422): a centered `Text` (`timeStyle` ~line 335:
  `veryMuted`, `typography.sm.fontSize`, **no weight** → default w400) inside a
  no-fill `Padding`. Same `fontSize` and colour as the weekday label, but the
  weight differs (w400 vs w500).
- **Related neutral getters** (unchanged): `agendaPanelBackground` (L2,
  `_atAbsoluteDepth(2).background`) and `panelDarkestBackground` (L4,
  `_atAbsoluteDepth(7).background`).

## Design

### 1. Rename `headerBackground` → `pageHeaderBackground`

- Same value/formula, just renamed. Update the two usages
  (`thread.dart:1407`, `note_viewer.dart:53`) and grep the whole `apps/plot`
  tree (incl. tests) to catch any other reference.
- Rewrite its doc comment to describe what it actually is: the page/panel
  header bar band (thread page, note viewer) — and to point at
  `sectionHeaderBackground` as the subtler sibling.

### 2. Add `sectionHeaderBackground` (new getter)

- **Warm-neutral, darker, subtle.** Derive it from a *relative-darkened*
  `background` step — i.e. `copyWith(darken: pow(_darkenFactor, N)).background`
  — for **both** light and dark modes. Because `background` is
  `neutral(0.98/0.26, ~0.01/0.006, hue 115)`, deriving from it automatically
  carries the same faint warm chroma the surrounding surface has, in both
  brightnesses; no hardcoded OKLCH.
- **Relative darken (not absolute depth)**, matching the rationale on today's
  getter: the band is used both inside the *already-darkened* agenda subtree
  (date headers) and in the *un-darkened* middle panel (activity feed). A
  relative step keeps it darker than whatever surface it sits on in either
  context.
- **Smaller step than the page band** so it's more subtle. The page band is
  effectively a depth-3 step; the section band starts at a smaller step
  (candidate `N = 1`). The exact `N` is **tuned by eye in the running app** —
  it must be visible as a band yet clearly gentler than the page-header bar.
- Document it as "L3 (subtle) — section-header band: agenda date headers +
  activity-feed section headings; warm-neutral, darker-than-surface, gentler
  than `pageHeaderBackground`."

### 3. Apply the section band in `lib/widget/agenda.dart`

- **Date-header branch** (`date != null`): wrap the header `Row` in a
  full-width `DecoratedBox`/`Container` filled with
  `context.colour.sectionHeaderBackground`. Keep the existing inner vertical
  padding; the band spans the full panel width (gutter through trailing edge).
  The surrounding `verticalMargin` stays as transparent separation *around* the
  band (the fill hugs the header content, not the margin).
- **Activity-feed heading branch** (`isTextOnlyHeading`): replace the no-fill
  `Padding` with the same band fill behind the centered heading text, keeping
  the current vertical padding.
- **Out of scope, unchanged:** gap/time headers and "now" headers keep no fill.

### 4. Restyle the activity-feed heading text

- Match the date header's weekday label: `plotColors.veryMuted`,
  `typography.sm`, **`FontWeight.w500`** (today it's w400). Colour and size
  already match; this adds the weight so "Today/New/Scheduled/Done" sits at the
  same visual weight as the weekday.

## Files to change

- `apps/plot/lib/style/colors.dart` — rename `headerBackground` →
  `pageHeaderBackground`; add `sectionHeaderBackground`; fix/expand both doc
  comments.
- `apps/plot/lib/page/thread.dart` — `headerBackground` → `pageHeaderBackground`.
- `apps/plot/lib/widget/note_viewer.dart` — `headerBackground` →
  `pageHeaderBackground`.
- `apps/plot/lib/widget/agenda.dart` — fill the date-header and
  activity-feed-heading branches with `sectionHeaderBackground`; add `w500` to
  the activity-feed heading text style.
- `docs/updates.md` — one plain-language line (subtle visual polish; optional —
  see below).

## Edge cases & considerations

- **Rename completeness:** grep all of `apps/plot` (lib + test) for
  `headerBackground`; the analyzer will also flag any miss. Don't leave a
  partial rename.
- **Darker, never lighter:** confirm in both modes the band is darker than the
  surface behind it (in dark mode the hover `highlight` lifts rows *lighter*, so
  a lighter band would read as a hover state — it must go darker).
- **Compounding in the agenda subtree:** the date headers sit on the darkened
  agenda body; verify the relative step still reads as a gentle band there (it
  compounds), and independently verify the activity-feed heading on the
  un-darkened middle panel.
- **Subtlety vs. invisibility:** the whole point is a *barely-there* band — the
  warm chroma is what gives it presence at a tiny lightness step. Tune `N` and
  the result in-app; a too-large `N` makes it compete with `pageHeaderBackground`.
- **Text contrast:** `veryMuted` heading/label text over the slightly-darker
  band must stay legible in both modes (it's intentionally quiet).

## Testing

- `cd apps/plot && flutter analyze` on changed files (the rename is the main
  correctness risk; the analyzer catches stragglers).
- No new widget tests strictly required (pure styling), but if any existing
  agenda/header test asserts a specific colour or the no-fill state, update it.

## Verification

Run the app (the `run-app` skill) and confirm, in light **and** dark mode:
- Agenda date headers and the activity-feed `Today/New/Scheduled/Done` headings
  show a subtle warm band, gentler than the thread page header bar.
- The band is darker than its surroundings (not a hover-highlight look).
- The activity-feed heading text matches the weekday label weight.

## Docs / finalize

- `docs/updates.md`: optional single line if deemed user-noticeable, e.g.
  "Agenda day headers and activity section headers now sit on a subtle band for
  easier scanning." Skip if judged too minor.
- Run `/finalize` before completing.
