# Empty-day gap rows in the agenda

## Goal

Days in the agenda that have no scheduled content (no calendar events, no
focus blocks) currently render as a bare date header with nothing beneath
it. Add a gap row to these empty days so they read as deliberately free
time rather than a rendering gap. The gap row shows **no time and no
duration — just the squiggle** that already marks free space between
scheduled blocks.

## Background

The agenda is built by `AgendaBuilder.build` (`apps/plot/lib/state/agenda_builder.dart`).
For each day from today through `fillUntil`, it collects time-anchored
blocks (`anchored`) and interleaves read-only `GapBlock`s in the free
space:

- **Leading edge gap** — midnight → first block (future days only).
- **Between-block gaps** — one per opening between consecutive blocks.
- **Trailing edge gap** — last block → midnight.

All three require `anchored.isNotEmpty`. When a day has no anchored
blocks the loop body never runs and the day's `blocks` list stays empty,
so only the date header renders.

A `GapBlock` flows through `AgendaModel.flatItems()` →
`AgendaHeaderItem` → `isGapHeader` → `_GapHeaderRow`
(`apps/plot/lib/widget/agenda.dart`). The renderer already suppresses
both labels for boundary-touching gaps:

- `centerText` (time) is null when the gap's start is midnight.
- `gapTouchesMidnight` is true when either end is midnight, which omits
  the duration.

So a gap spanning `midnight → nextMidnight` renders as the squiggle
alone, with the hover/touch `+` to schedule a focus block — exactly the
desired empty-day appearance, with no renderer changes.

## Design

Add one branch in `AgendaBuilder.build`, after the trailing-edge gap
(mutually exclusive with the leading/between/trailing gaps, which all
require `anchored.isNotEmpty`):

```dart
// Empty day: nothing scheduled. Mark the whole day free with one
// full-day gap (midnight → midnight). The renderer shows just the
// squiggle — the midnight start omits the time label and the
// day-boundary touch omits the duration — with the + to schedule.
if (anchored.isEmpty) {
  blocks.add(GapBlock(
    id: 'g_empty_$sectionId',
    priority: context,
    range: DateTimeRange(midnight, nextMidnight),
    threads: const [],
    isCurrent: false,
  ));
}
```

### Today, when empty

An empty *today* gets the same full-day squiggle (`isCurrent: false`).
The "Now" label is reserved for an event or focus block actually in
progress; an empty day has neither, so it shows a plain squiggle like any
other empty day. This keeps every empty day uniform and honours the
"no time, no duration" requirement.

## Non-goals / out of scope

- No change to the `_GapHeaderRow` renderer or `_SquigglePainter`.
- No change to drag/drop boundaries; full-day gaps carry a
  `parentBlockId` like any gap and need no special handling.
- Days that already have anchored blocks are untouched.

## Testing

Pure-function tests against `AgendaBuilder.build` (no widgets), added to
`apps/plot/test/state/agenda_builder_test.dart`:

1. A future empty day emits exactly one `GapBlock` spanning
   midnight→midnight (start and end both at midnight), with no threads.
2. An empty today emits the same full-day `GapBlock` with
   `isCurrent == false`.
3. A day with an event emits no empty-day full-day gap (regression guard
   that the branch only fires when `anchored.isEmpty`).
