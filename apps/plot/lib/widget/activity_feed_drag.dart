import 'package:flutter/widgets.dart';

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

DateTime? _sectionToMarker(ActivitySection section) {
  switch (section) {
    case ActivitySection.today:
      return _todaySectionMarker;
    case ActivitySection.scheduled:
      return null; // disambiguated by targetDate
    case ActivitySection.newSection:
      return _newSectionMarker;
    case ActivitySection.done:
      return _doneSectionMarker;
  }
}

ActivitySection? _sectionFromTarget(BlockDropTarget target) {
  if (target.targetDate != null) return ActivitySection.scheduled;
  final marker = target.targetPeriodStart;
  if (marker == _todaySectionMarker) return ActivitySection.today;
  if (marker == _newSectionMarker) return ActivitySection.newSection;
  if (marker == _doneSectionMarker) return ActivitySection.done;
  return null;
}

/// Walks the Activity tab item list and emits a [BlockDropTarget] for
/// each drop boundary. Boundaries are placed:
///   * Above each `AgendaHeaderItem` (so a drop just above a section
///     header lands at the top of that section).
///   * Above each `AgendaThreadItem` (between rows).
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
({
  Map<int, BlockDropTarget> before,
  BlockDropTarget? afterList,
}) computeActivityFeedDropBoundaries({
  required List<AgendaItem> items,
}) {
  final before = <int, BlockDropTarget>{};
  BlockDropTarget? afterList;

  ActivitySection? currentSection;
  Date? currentScheduledDate;
  String? prevThreadId;

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
        if (currentSection != null) {
          before[i] = BlockDropTarget(
            targetDate: currentSection == ActivitySection.scheduled
                ? currentScheduledDate
                : null,
            targetPeriodStart: _sectionToMarker(currentSection),
            prevBlockId: prevThreadId,
            prevPriorityId: null,
            nextBlockId: null,
            nextPriorityId: null,
          );
        }
        currentSection = marker.section;
        currentScheduledDate = item.date;
        prevThreadId = null;
      }
      continue;
    }
    if (item is AgendaThreadItem) {
      if (currentSection == null) continue;
      final threadIdStr = item.thread.id.toString();
      before[i] = BlockDropTarget(
        targetDate: currentSection == ActivitySection.scheduled
            ? currentScheduledDate
            : null,
        targetPeriodStart: _sectionToMarker(currentSection),
        prevBlockId: prevThreadId,
        prevPriorityId: null,
        nextBlockId: threadIdStr,
        nextPriorityId: null,
      );
      prevThreadId = threadIdStr;
    }
  }

  // Tail boundary: always present when there's an active section so the
  // last section remains a valid drop target even when empty.
  if (currentSection != null) {
    afterList = BlockDropTarget(
      targetDate: currentSection == ActivitySection.scheduled
          ? currentScheduledDate
          : null,
      targetPeriodStart: _sectionToMarker(currentSection),
      prevBlockId: prevThreadId,
      prevPriorityId: null,
      nextBlockId: null,
      nextPriorityId: null,
    );
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

  BlockDragPayload _payload() => BlockDragPayload(
    blockId: widget.threadId.toString(),
    priorityId: widget.priorityContext.id,
    sourceDate: null,
    sourcePeriodStart: null,
    visibleThreadCount: 1,
  );

  void _onDragStarted() {
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
    final source = KeyedSubtree(key: _rowKey, child: widget.child);
    final hidden = BlockDragHidden(
      parentBlockId: widget.threadId.toString(),
      child: source,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final feedback = SizedBox(
          width: constraints.maxWidth,
          child: widget.child,
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
      },
    );
  }
}
