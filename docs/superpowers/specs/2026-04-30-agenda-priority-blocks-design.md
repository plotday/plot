# Agenda Priority Blocks — Design

**Date:** 2026-04-30
**Status:** Approved (verbal)
**Scope:** `apps/plot` Flutter agenda only. Activity feed unchanged.

## Goal

Group consecutive threads in the agenda by priority (or event, or schedule
gap) under a shared header, instead of repeating the priority label inline on
every thread tile. Restructure the agenda data pipeline around `Block` as a
first-class type so upcoming features — dynamic priority grouping, collapsible
blocks, and block drag — land cleanly.

## User-visible changes (this iteration)

- Every contiguous run of threads sharing a priority appears under a single
  shared header. Every priority block gets a header — including the root
  priority and the current contact priority.
- Existing event headers and schedule-gap headers absorb the priority-header
  role for the block they precede; they render combined (time/event metadata
  *plus* priority breadcrumb + accent borders).
- Date headers still appear and are unaffected.
- The header has a top border in the priority's accent color and a bottom
  border in `veryMuted`.
- Headers are unfocusable.
- The inline priority label / click-to-move affordance is removed from each
  thread tile in the agenda. `MoveThreadToPriority` remains accessible via
  keyboard shortcut and the thread commands menu.
- No changes to thread ordering or grouping in this iteration. Visual
  ordering is bit-identical to today aside from the new headers and the
  removed inline labels.

## Why a pipeline rewrite, not a post-process

The existing pipeline emits a flat `List<AgendaItem>` of header and thread
atoms. Mutation handlers (`_handleThreadUpdate`, `optimisticallyRemoveThread`,
archive flow, `moveAgendaItem`, link-instance-becomes-todo splice) each
imperatively re-splice that flat list — finding event headers to remove,
scanning for date sections, computing insertion points. The reorder closure in
`page/priority.dart` walks the flat list, scanning back for date headers, and
distinguishing "in gap" vs "after event" by inspecting neighboring atoms.

This works because the *block* is implicit — encoded in atom adjacency,
recovered by scanners, and re-encoded by every mutation handler. Adding
priority headers as a post-process keeps the implicit-block model and adds yet
another atom kind to scan past. The next three planned features all want
blocks as first-class:

- **Dynamic priority grouping** — needs to reorder threads within a day into
  priority groups; trivially expressed as "build one block per priority".
- **Collapse to top N** — needs per-block UI state; trivially `Map<blockId,
  bool>`, render is `block.threads.take(N)`.
- **Block drag** — needs a stable block identity and the ability to operate
  on a contiguous range as a unit.

Making `Block` a real type now is the natural alignment with all three.

## Data model

New file: `apps/plot/lib/state/agenda_model.dart`.

```dart
class AgendaModel extends Equatable {
  final List<AgendaSection> sections;
  // Stable identity helpers, lookup by block id, etc.
}

sealed class AgendaSection extends Equatable {
  String get id;            // 'date_<iso>' | 'now' | 'text_<slug>'
  Date? get date;
  bool get isNow;
  String? get text;         // e.g. "From the server"
  DateTime? get scheduleAt; // for "Add to schedule" affordance on date headers
  List<AgendaBlock> get blocks;
}

class DateSection extends AgendaSection { ... }   // `isNow` flag marks the synthetic Today
class TextSection extends AgendaSection { ... }   // server feed banner

sealed class AgendaBlock extends Equatable {
  String get id;            // see "Block IDs" below
  Priority get priority;    // every block has a priority for header rendering
  List<Thread> get threads; // flat list for top-N collapse and rendering
  bool get isOutside;       // dim outside-priority blocks
}

class PriorityBlock extends AgendaBlock {
  final Priority priority;
  final List<Thread> threads;
}

class EventBlock extends AgendaBlock {
  final Thread event;
  final Priority priority;        // event's priority
  final List<Thread> associated; // children (today's `isAssociated` rows)
  final bool isCurrent;           // "now" event highlight
  final bool isOutside;
  @override
  List<Thread> get threads => [event, ...associated];
}

class GapBlock extends AgendaBlock {
  final DateTimeRange range;
  final Priority priority;        // priority of the contained threads
  final List<Thread> threads;
}
```

### Block IDs

Stable across rebuilds so `AnimatedRemoval`, scroll restoration, and
collapse state survive thread updates:

- `PriorityBlock`:  `p_<sectionId>_<priorityPath>`
- `EventBlock`:     `e_<sectionId>_<eventId>[_<occurrence>]`
- `GapBlock`:       `g_<sectionId>_<rangeStartEpochMs>`

The `<sectionId>` prefix scopes blocks to their date section so the same
priority appearing on two days produces two stable, distinct ids.

## Pipeline

```
drift streams
  → patchedThreads (after optimistic overrides + suppression)
  → AgendaBuilder.build(threads, context, associations, now)
  → AgendaModel
  → state.agenda
```

`AgendaBuilder.build` is a pure, deterministic, ~O(n) function. It ports the
ordering rules currently inside `_makeAgenda` verbatim — same date partition,
same event/gap/todo placement — but emits blocks instead of atoms.
*Visual ordering is bit-identical to today.*

`PriorityState` exposes `state.agenda: AgendaModel` as the canonical view. A
`flatItems` getter on `AgendaModel` flattens to the existing `List<AgendaItem>`
shape during the migration so any code we haven't yet rewritten keeps working.

## Mutation handlers

Today, six handlers in `priority.dart` mutate `state.agendaItems` directly
(L759 `_handleThreadUpdate` schedule-change reposition, in-place replacement,
link-instance-becomes-todo splice; `optimisticallyRemoveThread`; archive flow;
`moveAgendaItem`). All are replaced with:

1. Update the *source thread list* (or `_optimisticOverrides` map).
2. Call `AgendaBuilder.build(...)` to produce a fresh `AgendaModel`.
3. `emit(state.copyWith(agenda: ...))`.

The existing `_loadAgenda` debounce + `distinct` + `ExpiringStreamTransformer`
+ optimistic-override suppression machinery already prevents redundant
rebuilds, so full rebuild on each mutation is fine.

This deletes ~600 lines of imperative splice code from `priority.dart`. The
risk is concentrated in animation/scroll continuity (`AnimatedRemoval` keys),
which we mitigate by giving every block and every visible row a stable id (see
"Block IDs" above).

## Renderer

`page/priority.dart` consumes the model directly:

```
AgendaModel
  → for each section: section header (date / now / text)
    → for each block: block header (combined time/event/priority + borders)
      → for each thread: ThreadWidget
```

The combined block header replaces what's today both `AgendaHeader` (for
date/gap/event/text/now) and the per-thread `_PriorityHoverArea`. Concretely:

- **`PriorityBlock` header**: `PriorityLabel(priority, context: priorityContext)`
  with accent top border and `veryMuted` bottom border. No time. Unfocusable.
  Padding consistent with existing date headers.
- **`GapBlock` header**: time on the left in the `agendaLeadingWidth`
  column (as today), priority breadcrumb in the main area, duration text on
  the right. Same accent + veryMuted borders.
- **`EventBlock` header**: time on the left, priority breadcrumb in the main
  area, accent borders. The event row itself renders below as a thread
  (preserving today's `showEventTiming` inline behavior). Associated children
  render after the event row, still inside the block.
- **Date / now / text section headers**: unchanged from today's `AgendaHeader`
  (no priority context, no accent borders). They are *section* headers, not
  block headers — they coexist with the block header below them. This honors
  the user's clarification that date headers are independent of the
  consecutive-header rule.

`AgendaHeader` widget evolves to take an optional `Priority? blockPriority`.
When set, it renders the breadcrumb + accent/veryMuted borders. Section
headers (date/now/text) keep `blockPriority: null` and render as today.

## Reorder

The reorder closure in `page/priority.dart` is rewritten to operate on block
ids instead of scanning a flat list:

```
onReorder(thread, dropTarget):
  sourceBlock = blockContaining(thread)
  targetBlock = blockAt(dropTarget)
  newOrder    = Order.between(prev-thread-in-target, next-thread-in-target)

  if targetBlock is PriorityBlock and targetBlock.priority != thread.priority:
    => drop-handler decision (Option A vs B). See "Cross-block drops" below.
  else if targetBlock is EventBlock:
    => associate(thread, targetBlock.event), set order
  else if targetBlock is GapBlock:
    => set thread.pinnedAfterTime = targetBlock.range.start, set order
  else:
    => same-block reorder, set order only
```

This shrinks the closure dramatically (today: ~350 lines of section/gap
scanning).

### Cross-block drops (deferred decision)

The block model leaves the cross-block-drop semantics open. The decision is
made entirely in the drop handler:

- **A — Change priority**: handler sets `thread.priority =
  targetBlock.priority` and `thread.order = Order.between(...)`. On rebuild
  the dragged thread sits inside the target block. Block stays cohesive.
- **B — Split block**: handler leaves `thread.priority` unchanged, sets
  `thread.order` (or `pinnedAfterTime`). On rebuild the builder's
  consecutive-same-priority rule produces `[target before] / [dragged, 1
  thread] / [target after]` automatically.
- **C — Associate** (EventBlock only): handler creates a `thread_association`
  row, leaves priority alone. Block stays whole. (Today's behavior.)

For this iteration we preserve today's behavior, which is effectively
Option B without the visible split: the drop handler sets `thread.order`
(and `pinnedAfterTime` for gap drops) but does not change `thread.priority`.
Today's grouping rebuilds the dragged thread back into its own priority
group, so the cross-priority drop appears to "snap back". Under the new
block model the same handler produces a real visual split between
`PriorityBlock`s — which is the natural result of the consecutive-same-priority
rule. `EventBlock` drops continue to use Option C (associate). The choice
between A, B, and "snap back" is fully reachable from the same drop
handler. **Caveat for later**: once dynamic priority grouping ships and
actively reorders threads into priority groups within a day, Option B
needs a position-anchor field (e.g. `pinnedAfterThreadId`) so the grouping
pass doesn't undo the split.

## `agendaViewItems` truncation

Today's `agendaViewItems` strips event headers when a "now" event is active
to truncate the view to "now and after". Replace with: filter
`AgendaModel.sections` and within them `section.blocks` to drop blocks that
end before "now". The flat-getter materializes this for legacy consumers.

## Keyboard navigation & focus

`getAgendaItem(offset)` is rewritten to walk threads inside blocks. Headers
(both section and block) are skipped. This matches today's behavior of
skipping `AgendaHeaderItem`s.

## Thread tile changes

In `apps/plot/lib/widget/thread.dart`:

- Remove `_PriorityHoverArea` usage at L564 and L598.
- Remove the `hasSubPriorityLabel` derivation and any code that's only
  reachable when it is true (label-offset compensation when only the
  priority label is the top-row reason; schedule-label paths are unaffected).
- Keep the `showSubPriority` parameter on `ThreadWidget` — the activity
  feed still sets `showSubPriority: true` (`page/priority.dart:2285`) and
  must continue to render an inline label there. Only the agenda call site
  (`:1454`) stops passing `showSubPriority: true`.
- `MoveThreadToPriority` command is unchanged; only the inline UI affordance
  is removed.

## Files touched

- **New:** `apps/plot/lib/state/agenda_model.dart` — `AgendaModel`,
  `AgendaSection`, `AgendaBlock` types, `AgendaBuilder.build`, `flatItems`
  compatibility getter.
- `apps/plot/lib/state/priority_state.dart` — replace `_makeAgenda` (or
  reduce it to a thin call to `AgendaBuilder.build`); update
  `PriorityState` to carry `agenda: AgendaModel`. Keep `agendaItems` as a
  derived getter for transitional compatibility.
- `apps/plot/lib/state/priority.dart` — delete the manual splice paths in
  `_handleThreadUpdate`, `optimisticallyRemoveThread`, `archiveThread`,
  `moveAgendaItem` (the data-mutation half), and the link-instance-becomes-todo
  splice. Replace each with: update source data → rebuild model.
- `apps/plot/lib/widget/agenda.dart` — `AgendaHeader` gains `blockPriority`
  rendering with accent + veryMuted borders.
- `apps/plot/lib/widget/thread.dart` — remove inline `_PriorityHoverArea`
  usage from the agenda path; clean up `hasSubPriorityLabel` derivation.
- `apps/plot/lib/page/priority.dart` — render sections → blocks → threads;
  rewrite the reorder closure on block ids; stop passing `showSubPriority:
  true` from the agenda site (keep on the activity-feed site).

## Out of scope

- Dynamic priority grouping (next iteration; the builder is the only thing
  it touches).
- Collapsible blocks (next iteration; per-block UI state + `take(N)`).
- Block drag (next iteration; block-level reorder API).
- Activity feed redesign — explicitly excluded by the user.
- Schema or sync changes — none required.

## Risks & mitigations

- **Reorder regressions.** The single largest risk. Mitigation: write the
  new block-aware reorder against the same `Order.between` semantics; cover
  the same-block case first (it's the dominant path) and the cross-block
  case with explicit tests for each block kind.
- **Animation/scroll continuity.** Stable block ids and stable per-thread
  keys preserve `AnimatedRemoval` and reorderable list animations across
  rebuilds. Verified by manual interaction in the running app before
  committing.
- **Optimistic update timing.** Existing `_optimisticOverrides`,
  `_pendingReorderOrder`, `_pendingAssociation`, `_pendingDisassociation`,
  and the suppression flags continue to gate emissions; rebuild-from-source
  runs only when suppression clears.
- **Outside-priority events.** Today they render dimmed and bypass
  associations. Preserved by `AgendaBlock.isOutside` propagating through to
  the renderer.

## Validation

1. `flutter analyze apps/plot` clean.
2. Manual interaction in the running app: agenda renders correctly across
   today / future / past sections; reorder within priority block; reorder
   across priority blocks; drop into gap; drop onto event (associate); now
   marker at top of today; outside-priority events still dimmed; archive
   removes thread; schedule-change reposition works without flicker.
3. Activity feed unchanged — inline priority label still present on threads.
