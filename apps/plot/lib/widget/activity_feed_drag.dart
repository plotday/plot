import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/agenda_block_drag.dart';

/// Sentinel DateTimes stashed in `BlockDropTarget.targetPeriodStart` to
/// encode which Activity-feed section a drop slot belongs to. Needed
/// because two empty-section slots otherwise produce equal
/// [BlockDropTarget]s (same null prev/next ids), which the controller
/// would treat as the same slot and the dispatcher couldn't distinguish.
///
/// Only used for non-Scheduled sections; Scheduled is identified by
/// `targetDate` being non-null.
final DateTime _todaySectionMarker = DateTime.utc(1, 1, 1, 0, 0, 1);
final DateTime _newSectionMarker = DateTime.utc(1, 1, 1, 0, 0, 2);
final DateTime _doneSectionMarker = DateTime.utc(1, 1, 1, 0, 0, 3);
final DateTime _eventAgendaSectionMarker = DateTime.utc(1, 1, 1, 0, 0, 4);

DateTime? _sectionToMarker(ActivitySection section) {
  switch (section) {
    case ActivitySection.eventAgenda:
      return _eventAgendaSectionMarker;
    case ActivitySection.doing:
      return _todaySectionMarker;
    case ActivitySection.scheduled:
      return null; // disambiguated by targetDate
    case ActivitySection.updates:
      return _newSectionMarker;
    case ActivitySection.activity:
      return _doneSectionMarker;
  }
}

ActivitySection? _sectionFromTarget(BlockDropTarget target) {
  if (target.targetDate != null) return ActivitySection.scheduled;
  final marker = target.targetPeriodStart;
  if (marker == _eventAgendaSectionMarker) return ActivitySection.eventAgenda;
  if (marker == _todaySectionMarker) return ActivitySection.doing;
  if (marker == _newSectionMarker) return ActivitySection.updates;
  if (marker == _doneSectionMarker) return ActivitySection.activity;
  return null;
}

/// One drop boundary emitted by [computeActivityFeedDropBoundaries].
/// `silent` zones still register with the drag controller for
/// activation purposes but do not visually expand — see [BlockDropZone]
/// for details.
typedef FeedDropSlot = ({BlockDropTarget target, bool silent});

/// Walks the Activity tab item list and emits a [BlockDropTarget] for
/// each drop boundary. Boundaries are placed:
///   * Above each `AgendaHeaderItem` (so a drop just above a section
///     header lands at the top of that section).
///   * Above each `AgendaThreadItem` (between rows) — except inside
///     the Done section, where only the boundary above the FIRST done
///     thread is emitted as a visible gap. Between-done-thread gaps
///     are intentionally omitted so dropping anywhere over Done lands
///     at the top.
///   * After the very last item ([afterList]).
///
/// Each emitted target carries the section identity in its
/// `targetDate` slot when the section is Scheduled (so dispatch can
/// recover the day to schedule for); the section name itself is
/// recovered later by re-walking the items in the dispatcher.
///
/// The boundary just above a section header belongs to the **previous**
/// section's tail — dropping above the "Tomorrow" header drops at the
/// bottom of Today, not the top of Tomorrow. The first drop slot of a
/// section is the boundary above that section's first thread row.
///
/// The single Done boundary uses `prevBlockId: null` and
/// `nextBlockId: null` even when there are done threads below it.
/// Pinning both flanks to null serves two ends:
///   1. The activation algorithm's no-op filter (`isFiltered` =
///      either flank equals the dragged id) never excludes this slot,
///      so dragging the topmost done thread still activates it.
///   2. The dispatcher's no-op skip never short-circuits a drop on
///      Done, so a same-position drop still bumps `bumpedAt` and
///      surfaces the thread at the top.
///
/// Non-empty Done also emits a *silent* tail slot (same target as the
/// visible top slot) at [afterList]. Without it, dragging anywhere
/// below the visible slot's Y would fall outside any activatable
/// bracket — the user would have to drag back up past the first done
/// thread to make the drop fire. The phantom keeps the cursor inside
/// an activatable region; the visible top slot stays expanded via
/// target-equality (see [BlockDropZone]).
({
  Map<int, FeedDropSlot> before,
  FeedDropSlot? afterList,
}) computeActivityFeedDropBoundaries({
  required List<AgendaItem> items,
}) {
  final before = <int, FeedDropSlot>{};
  FeedDropSlot? afterList;

  ActivitySection? currentSection;
  Date? currentScheduledDate;
  String? prevThreadId;
  // Done collapses to a single drop zone above the first done thread
  // (or as `afterList` when Done is empty). Tracks whether that single
  // boundary has been emitted so subsequent done threads don't get one.
  var doneBoundaryEmitted = false;

  BlockDropTarget doneTopTarget() => BlockDropTarget(
    targetDate: null,
    targetPeriodStart: _sectionToMarker(ActivitySection.activity),
    prevBlockId: null,
    prevPriorityId: null,
    nextBlockId: null,
    nextPriorityId: null,
  );

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is AgendaHeaderItem) {
      final marker = item.text == null
          ? null
          : ActivitySectionMarker.tryDecode(item.text!);
      if (marker != null) {
        // Tail-of-previous-section boundary. Emitted whenever there's a
        // previous section, regardless of whether it had threads — when
        // the previous section was empty (`prevThreadId == null`), the
        // boundary still targets that empty section so it remains a
        // valid drop target. The section is encoded via
        // `targetPeriodStart` (or `targetDate` for Scheduled).
        //
        // Done is the special case: its tail boundary is suppressed
        // when it already has a top boundary (non-empty Done) so the
        // section never gets a second visible drop slot. When Done is
        // empty, emit the single Done top target here so the empty
        // section remains a valid drop site.
        if (currentSection != null) {
          if (currentSection == ActivitySection.activity) {
            if (!doneBoundaryEmitted) {
              before[i] = (target: doneTopTarget(), silent: false);
              doneBoundaryEmitted = true;
            }
          } else {
            before[i] = (
              target: BlockDropTarget(
                targetDate: currentSection == ActivitySection.scheduled
                    ? currentScheduledDate
                    : null,
                targetPeriodStart: _sectionToMarker(currentSection),
                prevBlockId: prevThreadId,
                prevPriorityId: null,
                nextBlockId: null,
                nextPriorityId: null,
              ),
              silent: false,
            );
          }
        }
        currentSection = marker.section;
        currentScheduledDate = item.date;
        prevThreadId = null;
      }
      continue;
    }
    if (item is AgendaThreadItem) {
      if (currentSection == null) continue;
      if (currentSection == ActivitySection.activity) {
        // Only the first done thread gets a drop zone — and the target
        // is "top of Done" (prev/next null), not adjacent to the first
        // done thread. Skip emitting a boundary for any subsequent
        // done thread so the gap never opens between done rows.
        if (!doneBoundaryEmitted) {
          before[i] = (target: doneTopTarget(), silent: false);
          doneBoundaryEmitted = true;
        }
        continue;
      }
      final threadIdStr = item.thread.id.toString();
      // Pinned rows (the event row at the top of "Event Agenda") are
      // anchored in place — emit no "before" drop slot for them so
      // the user can't drop above the event. The "prev" tracking still
      // advances so the slot above the first association still gets a
      // sensible neighbour for the dispatcher.
      if (!item.pinned) {
        before[i] = (
          target: BlockDropTarget(
            targetDate: currentSection == ActivitySection.scheduled
                ? currentScheduledDate
                : null,
            targetPeriodStart: _sectionToMarker(currentSection),
            prevBlockId: prevThreadId,
            prevPriorityId: null,
            nextBlockId: threadIdStr,
            nextPriorityId: null,
          ),
          silent: false,
        );
      }
      prevThreadId = threadIdStr;
    }
  }

  // Tail boundary:
  //   * Empty Done → visible top-of-Done slot lives here so the empty
  //     section stays droppable.
  //   * Non-empty Done → silent phantom slot with the same target as
  //     the visible top slot. Lets the cursor activate top-of-Done from
  //     anywhere below the first done thread without having to drag
  //     back up past it; visible expansion still fires at the top via
  //     [BlockDropZone]'s target-equality check.
  //   * Other sections → ordinary tail target.
  if (currentSection != null) {
    if (currentSection == ActivitySection.activity) {
      afterList = (
        target: doneTopTarget(),
        silent: doneBoundaryEmitted,
      );
    } else {
      afterList = (
        target: BlockDropTarget(
          targetDate: currentSection == ActivitySection.scheduled
              ? currentScheduledDate
              : null,
          targetPeriodStart: _sectionToMarker(currentSection),
          prevBlockId: prevThreadId,
          prevPriorityId: null,
          nextBlockId: null,
          nextPriorityId: null,
        ),
        silent: false,
      );
    }
  }

  return (before: before, afterList: afterList);
}

/// Dispatch an Activity-feed drag drop. Recovers the target section
/// from the section-marker stashed in `target.targetPeriodStart` (or
/// `targetDate` for Scheduled), then calls
/// `PriorityBloc.applyActivityFeedThreadDrop`.
void dispatchActivityFeedThreadDrop({
  required PriorityBloc bloc,
  required BlockDragPayload payload,
  required BlockDropTarget target,
}) {
  final section = _sectionFromTarget(target);
  if (section == null) return;

  // Skip no-op drops: dragging a thread to a slot adjacent to itself.
  if (target.prevBlockId == payload.blockId ||
      target.nextBlockId == payload.blockId) {
    return;
  }

  final draggedId = ThreadId.fromString(payload.blockId);
  final prevId = target.prevBlockId == null
      ? null
      : ThreadId.fromString(target.prevBlockId!);
  final nextId = target.nextBlockId == null
      ? null
      : ThreadId.fromString(target.nextBlockId!);

  bloc.applyActivityFeedThreadDrop(
    draggedId: draggedId,
    targetSection: section,
    targetScheduledDate: target.targetDate,
    prevId: prevId,
    nextId: nextId,
  );
}

/// Wraps a single Activity-feed thread row as a [Draggable] over the
/// shared [BlockDragController]. Each thread row is its own one-row
/// "block" — payload carries the thread id (as `blockId`).
class ActivityFeedDraggableRow extends StatefulWidget {
  const ActivityFeedDraggableRow({
    required this.threadId,
    required this.priorityContext,
    required this.child,
    super.key,
  });

  final ThreadId threadId;
  final Priority priorityContext;
  final Widget child;

  @override
  State<ActivityFeedDraggableRow> createState() =>
      _ActivityFeedDraggableRowState();
}

class _ActivityFeedDraggableRowState extends State<ActivityFeedDraggableRow> {
  final GlobalKey _rowKey = GlobalKey();

  // Captured once via post-frame callback after the row first lays out.
  // Avoids a per-row LayoutBuilder (which would force an extra layout
  // pass for every visible row on every build); the one-shot capture
  // costs a single callback per row's lifetime.
  double? _renderedWidth;

  BlockDragPayload _payload() => BlockDragPayload(
    blockId: widget.threadId.toString(),
    priorityId: widget.priorityContext.id,
    sourceDate: null,
    sourcePeriodStart: null,
    // 0 — not 1 — because the source RO is the entire thread row (no
    // separate breadcrumb header sits above it). See the field's doc
    // for the agenda-vs-activity-feed distinction. With 1, the height
    // fallback in `_captureSourceHeight` would double-count when no
    // `K_after_source` slot exists (e.g. dragging a Done thread, since
    // Done collapses to a single boundary with `prevBlockId: null`).
    visibleThreadCount: 0,
  );

  void _captureRenderedWidth() {
    if (!mounted) return;
    final ctx = _rowKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final width = ro.size.width;
    if (_renderedWidth == width) return;
    setState(() => _renderedWidth = width);
  }

  void _onDragStarted() {
    // Refresh width at drag start so a pane resize since first layout
    // doesn't leave the feedback sized to a stale width.
    _captureRenderedWidth();
    final controller = BlockDragScope.maybeOf(context);
    controller?.start(
      _payload(),
      sourceContextProvider: () => _rowKey.currentContext ?? context,
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    BlockDragScope.maybeOf(context)?.updatePointer(details.globalPosition);
  }

  void _onDragEnd(DraggableDetails details) {
    BlockDragScope.maybeOf(context)?.end();
  }

  void _onDragCancelled() {
    BlockDragScope.maybeOf(context)?.end(dispatch: false);
  }

  @override
  Widget build(BuildContext context) {
    // Capture the source row's rendered width once after first layout.
    // Falls back to MediaQuery on the first frame; subsequent rebuilds
    // see the cached value and skip the postFrameCallback.
    if (_renderedWidth == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _captureRenderedWidth();
      });
    }
    final source = KeyedSubtree(key: _rowKey, child: widget.child);
    final hidden = BlockDragHidden(
      parentBlockId: widget.threadId.toString(),
      child: source,
    );
    final feedbackWidth =
        _renderedWidth ?? MediaQuery.sizeOf(context).width;
    // Draggable.feedback is mounted in the root Overlay, which sits
    // above the page-scoped [PriorityBloc] provider. The row subtree
    // (`_ActivityFeedItem`) reads the bloc in `initState`, so without
    // a re-provided value the feedback throws ProviderNotFoundError as
    // soon as Flutter inflates it. Capture the bloc here and bridge it
    // into the feedback subtree.
    final priorityBloc = context.read<PriorityBloc>();
    final feedback = BlocProvider<PriorityBloc>.value(
      value: priorityBloc,
      child: DraggedRowFrame(width: feedbackWidth, child: widget.child),
    );
    if (hasPhysicalKeyboard()) {
      return Draggable<BlockDragPayload>(
        data: _payload(),
        feedback: feedback,
        childWhenDragging: hidden,
        onDragStarted: _onDragStarted,
        onDragUpdate: _onDragUpdate,
        onDragEnd: _onDragEnd,
        onDraggableCanceled: (_, _) => _onDragCancelled(),
        child: hidden,
      );
    }
    return LongPressDraggable<BlockDragPayload>(
      data: _payload(),
      feedback: feedback,
      childWhenDragging: hidden,
      onDragStarted: _onDragStarted,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      onDraggableCanceled: (_, _) => _onDragCancelled(),
      child: hidden,
    );
  }
}
