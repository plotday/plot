# Selected focus selection ring — design

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan

## Problem

In the left-panel sidebar, the currently-selected focus (priority) is hard to
distinguish. Hover effects read well, but once a focus is selected the only
visual change is a background tint — and that tint is **identical to the hover
tint**, so "selected" looks the same as "hovered," and against the already-tinted
left-panel frame the contrast is insufficient.

## Root cause

The sidebar focus tiles already request the same selection border the agent /
activity feed uses, but it never renders for them:

- `widget/priorities_list.dart:115` and `widget/priority.dart:208` pass
  `selectedBorder: true`.
- The same tiles pass `borderRadius: 6` (left-panel pills —
  `widget/priorities_list.dart:74`).
- In `widget/list_tile.dart:376` the border is only drawn for non-rounded
  tiles:

  ```dart
  border: widget.borderRadius != null
      ? null                          // rounded tiles get NO border, ever
      : Border.symmetric(horizontal: BorderSide(
          color: showBorder ? <ring> : transparent, width: 1)),
  ```

  So the selection ring renders only for the edge-to-edge (non-rounded) feed
  tiles. The rounded sidebar tiles fall into the `null` branch and get only a
  background tint.

- The tint itself is the same color for hover and selected:
  `widget/priority.dart:209-210` sets both `selectedColor` and `highlightColor`
  to `priorityAccentBg` (`backgroundFromTheme(priority.displayColor)`). Selected
  therefore equals hover.

## Design

Give the rounded, selected focus tile the same "tint + 1px ring" treatment the
feed uses for selected items, with the ring drawn in the focus's own color.

### Behavior

- **Resting:** muted focus color text/icon, no fill, no ring (unchanged).
- **Hover:** tinted fill + full focus color text/icon, no ring (unchanged).
- **Selected:** tinted fill + a 1px rounded ring in the focus's own color.

The ring is what distinguishes selected from hovered from resting, and gives the
selected pill a crisp edge against the left-panel frame. This matches the
agent/activity feed's selected-item idiom (tinted background + hairline border),
adapted from the feed's horizontal-only border to a full rounded border for the
pill geometry.

### Ring color

Match the feed's selected-border treatment exactly: the feed uses
`accentBackground.withLightness(0.85 in light / 0.35 in dark)`. Apply that same
lightness treatment to each focus's own hue, so the ring reads as a stronger
edge of the tint already filling the tile (a purple focus → purple ring), rather
than every focus sharing one ambient-hued ring that would clash with the
per-focus backgrounds.

Concretely this is `backgroundFromTheme(color)` (per-color hue + chroma) pushed
to the feed's selected-border lightness.

### Hover and selected backgrounds

Unchanged. Both stay `priorityAccentBg`. The ring carries the selected/hover
distinction, matching the feed (tint + ring, not a deeper fill). If, once viewed
live, the ring alone reads too quietly, a cheap follow-up is to deepen the
selected fill slightly — but that is out of scope here and should be decided from
real screenshots (via the `run-app` skill), not added speculatively.

## Changes (4 files)

1. **`apps/plot/lib/style/colors.dart`** — add `borderFromTheme(ThemeColor?)`
   on `OklchColours`. Mirrors the existing `backgroundFromTheme` (per-color hue
   + scaled chroma) but applies `.withLightness(isDark ? 0.35 : 0.85)` so it
   reads as a crisp selection edge. Centralizes the ring formula and documents
   it as the feed's selected-border treatment. Uses the same private
   `_brightness` / `_themeColor` state `backgroundFromTheme` already uses.

2. **`apps/plot/lib/widget/list_tile.dart`** — add a nullable
   `selectedBorderColor` constructor field. In the `BoxDecoration` border logic:
   - **Rounded branch (`borderRadius != null`):** when `selectedBorderColor` is
     provided, draw `Border.all(color: showBorder ? selectedBorderColor :
     const Color(0x00000000), width: 1)` — i.e. the border is **always present
     at width 1** and only its color changes between selected (the ring) and
     unselected (fully transparent). When `selectedBorderColor` is `null`, keep
     `null` (today's behavior). This makes the ring strictly opt-in for rounded
     tiles — no other rounded selected tile is restyled.
   - **Edge-to-edge branch (`borderRadius == null`):** unchanged behavior; may
     honor an explicit `selectedBorderColor` if passed, otherwise the existing
     inline feed formula.

   **No content shift (required):** the border width must be constant (1) for a
   given tile across selected/unselected — a tile that participates in the ring
   always reserves the 1px border, painting it transparent when unselected, so
   selecting a focus only changes the border *color*, never the layout, and the
   text/icon never jump. This mirrors the existing edge-to-edge branch, which
   already does `color: showBorder ? <ring> : transparent` at a fixed width.
   Because every sidebar tile (focus tiles, Inbox, Everything, and the
   priorities search list) opts in, they all carry the same 1px reserved border
   and stay aligned with each other.

3. **`apps/plot/lib/widget/priority.dart`** — compute the ring color from
   `priority.displayColor` via `borderFromTheme` and pass it to the `ListTile`
   as `selectedBorderColor`, but only in left-panel / `monochrome` mode
   (`null` otherwise, so single-panel keeps current behavior). Computed
   internally from existing `priority` + `monochrome` — no new `PriorityWidget`
   constructor param. This also benefits the priorities search list
   (`page/priorities.dart:293`), which reuses `PriorityWidget`.

4. **`apps/plot/lib/widget/priorities_list.dart`** (`_FixedFocusTile`) — same
   treatment for the fixed Inbox and Everything tiles, using the fixed tile's
   color (`ThemeColor.defaultColor()` — Resolution/brand), only in `monochrome`
   mode. Computed internally — no new `_FixedFocusTile` constructor param.

### Public surface change

Only one: `ListTile.selectedBorderColor` (new nullable `Color?`, defaults
`null`). All other call sites are unaffected.

## Out of scope

- Deepening the selected background fill (possible follow-up, decide from live
  screenshots only).
- Changing hover behavior.
- Changing the edge-to-edge feed's existing selection treatment.
- Any change to single-panel (non-`monochrome`) focus rendering.

## Verification

- `cd apps/plot && flutter analyze` clean on changed files.
- Visual check via the `run-app` skill: resting / hover / selected states for a
  focus tile, the Inbox and Everything fixed tiles, and the priorities search
  list, in both light and dark mode. Confirm selected is clearly distinct from
  hover and from the frame, and the ring hue matches each focus's color.
- **No content shift:** toggle selection on a focus and confirm the title and
  icon do not move by 1px — the reserved transparent border must hold the layout
  stable.
