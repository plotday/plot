# Modal button redesign

Date: 2026-06-18
Status: Approved design — ready for implementation plan

## Problem

Modal action buttons (e.g. **Save** + **Archive** at the bottom of a connection
settings modal) have three issues:

1. **Inconsistent "button-ness."** A 1px top border (a hand-placed `FormDivider`)
   sits above some secondary buttons and makes them read as buttons — but it is
   applied inconsistently across call sites.
2. **Weak hierarchy.** A secondary button like *Archive* calls almost equal
   attention to the primary *Save* — they differ only in colour/weight, not
   footprint or layout, so the primary does not clearly dominate.
3. **Floating highlight.** Hover/focus paints a highlight band that leaves
   background colour above and below the row rather than filling the button's
   whole section.

## Current state (as built)

- `FormButton` (`lib/widget/form.dart:565`) is a `FormItem` rendered as a
  `ListTile` with `style: ListTileStyle.button`, stacked vertically inside
  `FormModal`'s scroll list.
- **Primary** = bold + accent-coloured text, left-aligned, with a leading icon
  from the command (e.g. ✓ for Save). **Secondary** = normal weight, foreground
  colour, same left-aligned layout — hence "almost equal attention except
  colour."
- The "border above Archive" is a manually inserted `FormDivider`
  (`lib/widget/form.dart:815`) — a 1px bottom border with vertical margin —
  added only at some call sites.
- Hover/focus highlight = `plotColors.highlight` fill (`lib/widget/list_tile.dart:400`),
  edge-to-edge, not participating with the top border.
- **Keyboard nav** (`lib/widget/form_modal.dart`): a single linear
  `_highlightedIndex` over all focus slots; `_moveHighlight(±1)` on **↑/↓**.
  Each `FormItem` owns a contiguous range of focus slots, and
  `highlightedSubIndex` tells the item which of its sub-slots is highlighted
  (the `FormScheduler` multi-slot precedent, `lib/widget/form_scheduler.dart`).
- The modal already branches presentation on **`context.isMultiPanel`**
  (`lib/widget/modal.dart:207`): a centred **dialog** when multi-panel, a
  full-width **bottom sheet** when single-panel.

## Cases to support

From a full sweep of `FormButton` call sites:

| Shape | Count | Examples |
|---|---|---|
| Single primary | ~20 | New thread, contact, group, focus block create, save settings |
| 1 primary + 1 secondary | 4 | EditSource `Save`+`Archive`; EditTwistInstance-fallback `Save`+`Archive`; ScheduleFocusBlock `Schedule`+`Delete`; AddPriorityWithMatching `Find`+`Create` |
| 1 primary + 2 secondaries | 1 | EditTwistInstance `Save` + `Details` + `Archive` |
| 2+ secondaries, no primary | 0 | — |

**Not part of the bar:** setup flows (e.g. AddTwistInstance) interleave buttons
like `Add account` / `Connect` *between form fields*, separated from the final
primary by other content. Those are contextual mid-form actions, not terminal
peers of the primary, and keep today's inline style.

## Design

### The action bar

An **action bar** is a *maximal trailing run of adjacent buttons* at the bottom
of a modal form group. It renders as one framed unit and is the single home for
terminal peer actions (the primary plus any secondary/destructive peers such as
Archive, Delete, Details, Remove). It renders two ways, chosen by
`context.isMultiPanel`.

### Multi-panel (dialog) — side-by-side

```
──────────────────────────────────────   ← one top rule (always)
   ✓ Save        │ Details │ Archive
──────────────────────────────────────   ← modal bottom edge
```

- **One top rule** frames the bar (the "border above Archive," now consistent
  and owned by the bar — not hand-placed dividers).
- **Primary** is the leftmost cell, `Expanded` to fill the remaining width, with
  its icon+label **centred** and bold accent colour.
- **Secondaries** sit to the right, each at its **natural width**, **muted**
  (quiet text + muted leading icon), separated from the primary and from each
  other by a **hairline vertical divider**.
- With 2 secondaries (the single EditTwistInstance case) they simply cluster
  further right on the same row: `✓ Save │ Details │ Archive`. Labels in every
  real bar are short (≤ "Details"/"Archive"), so one row always fits in a
  multi-panel dialog.
- **Hover/focus fills the whole cell** (top rule to bottom edge) — no floating
  band.

### Single-panel (bottom sheet) — always stacked

```
──────────────────────────────────────   ← border above each row
            ✓  Save                          (primary: centred, bold accent)
──────────────────────────────────────   ← border between every row
            Details                          (secondary: centred, muted)
──────────────────────────────────────
            Archive                          (secondary: centred, muted)
──────────────────────────────────────
```

- Every button is its own full-width row with a **1px top border**, so each
  reads as a distinct button and rows are separated from each other and from the
  form content above.
- **Every label is centred** — primary (bold accent) and secondaries (muted)
  alike.
- **Hover/focus fills the whole row.**
- This is not a width fallback: single-panel **always** stacks, because the
  modal is already a full-width bottom sheet there.

### Shared behaviour

- **Single primary** (most modals): one centred cell filling the bar
  (multi-panel) or one centred, top-bordered row (bottom sheet).
- **Destructive secondaries** (Archive / Delete): muted at rest like any
  secondary; a subtle **danger tint appears on hover/focus** so intent is
  signalled without shouting at rest. *(Proposed default — easy to drop.)*
- **Secondaries keep their leading icon**, muted, for command identity
  (Archive's box, Delete's trash). Centred icon+label group.
- **Mid-form standalone buttons** keep today's inline left-aligned style.

### Keyboard navigation (preserved)

- The bar's buttons remain **distinct focus slots in source order**: primary
  first, then secondaries left-to-right. This is unchanged from the current
  multi-slot model.
- **↑/↓** step through the buttons in both layouts (already true via the linear
  `_moveHighlight`). In the side-by-side bar, **←/→** also move within the bar.
- **Enter** still submits the primary; initial focus lands on the primary.
- The focus ring / highlight renders on whichever cell (multi-panel) or row
  (bottom sheet) is focused.

## Implementation

- **New internal `FormButtonBar` `FormItem`** (modelled on `FormScheduler`):
  owns N focus slots (one per button), and renders the side-by-side Row
  (multi-panel) or the stacked Column (single-panel), driven by the existing
  `highlightedSubIndex` and `context.isMultiPanel`.
- **`FormModal` auto-groups** the maximal trailing run of `FormButton`s within a
  group into a single `FormButtonBar`:
  - A `FormDivider` between or immediately before the run is **absorbed** (the
    bar frames itself), so existing call sites need no change beyond optionally
    deleting now-redundant `FormDivider`s.
  - A `FormButton` that is **not** in the trailing run (followed by non-button
    items — e.g. `Add account` mid-form) stays an individual `FormButton` in
    today's inline style.
  - Single-button groups become a one-cell bar, gaining the centred/top-bordered
    treatment for free — consistency becomes structural rather than per-call-site
    discipline.
- **Reuses existing tokens**: `spacing` (xl/sm padding), `plotColors.highlight`
  (cell/row fill), `colors.primary` (accent), `colors.border` (rules/dividers),
  `iconSizes.leading`, `typography.md`. No new schema, no new theme primitives
  expected.

### Call sites to verify after the change

These groups contain multi-button bars and should be visually checked (and have
redundant `FormDivider`s removed):

- `lib/command/twist.dart:1406` — EditSource (`Save` + `Archive`)
- `lib/command/twist.dart:2785` — EditTwistInstance (`Save` + `Details` + `Archive`)
- `lib/command/twist.dart:2839` — EditTwistInstance fallback (`Save` + `Archive`)
- `lib/command/priority.dart:913` — AddPriorityWithMatching (`Find` + `Create`)
- `lib/command/focus_block.dart:286` — ScheduleFocusBlock (`Schedule` + `Delete`)
- Plus the ~20 single-primary modals (regression: centred label, top border).

## Out of scope

- Restyling mid-form inline buttons (`Add account`, `Connect`).
- Any change to `Command` icons/titles themselves.
- Danger/confirmation flows beyond the hover tint (Archive already routes
  through its own `PromptToArchive*` confirm).

## Testing

- Widget tests for `FormButtonBar`: single primary; 1+1; 1+2; multi-panel vs
  single-panel layout selection (`context.isMultiPanel`); hover/focus fill;
  destructive hover tint.
- Keyboard nav tests: ↑/↓ through bar slots in order; ←/→ within the
  multi-panel bar; Enter submits primary; initial focus on primary.
- Auto-grouping tests in `FormModal`: trailing run collapses to one bar;
  `FormDivider` absorbed; non-trailing button stays inline.
- `flutter analyze` clean.
- Run-app spot check of EditSource, EditTwistInstance, and one single-primary
  modal in both multi-panel and single-panel widths.
