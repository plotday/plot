import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';

/// Payload carried by the block-level drag system.
///
/// Distinct generic type from any thread-level drag — Flutter's payload
/// matching means the block-level drop machinery is the only thing that
/// can accept this, and existing thread reorder paths (which use
/// `SliverReorderableList`'s untyped index-based plumbing) are
/// unaffected.
class BlockDragPayload {
  const BlockDragPayload({
    required this.blockId,
    required this.priorityId,
    required this.sourceDate,
    required this.sourcePeriodStart,
    required this.visibleThreadCount,
  });

  /// Id of the [AgendaBlock] being dragged.
  final String blockId;

  /// Priority id of the dragged block — used by the bloc-side dispatch
  /// (`reorderBlockWithinPeriod`, `moveBlock`).
  final PriorityId priorityId;

  /// Date the source block lives in (null = "Now"/no-date section).
  final Date? sourceDate;

  /// Gap-anchor of the source block's period (null = above any gap on
  /// the source date).
  final DateTime? sourcePeriodStart;

  /// Number of thread row heights *below* the source's render box —
  /// i.e. rows the source RO does NOT already cover. Used as a fallback
  /// when [BlockDragController._captureSourceHeight] can't locate a
  /// `K_after_source` slot at drag start, and as the deepest fallback
  /// in [dropZoneHeightFor].
  ///
  /// In the agenda, a block's drag handle sits on a small priority-
  /// breadcrumb header row; the N thread rows live below it, so this
  /// equals N. In the activity feed, each draggable IS the thread row
  /// itself (no separate header), so the source RO already accounts
  /// for the row's full height — set this to 0 to avoid double-counting.
  final int visibleThreadCount;
}

/// Resolved target description for a block drop.
///
/// Value equality matters: the parent agenda rebuilds the
/// `beforeBoundaries` map (and thus a fresh [BlockDropTarget] for
/// each [BlockDropZone]) on every list build. Without `==` the
/// `_BlockDropZoneState.didUpdateWidget` re-register logic would
/// fire on every parent rebuild and call `unregisterSlot`, which
/// nulls `_activeTarget` if the rebuild happens to run for the
/// currently-active slot — silently swallowing the user's drop.
class BlockDropTarget extends Equatable {
  const BlockDropTarget({
    required this.targetDate,
    required this.targetPeriodStart,
    required this.prevBlockId,
    required this.prevPriorityId,
    required this.nextBlockId,
    required this.nextPriorityId,
    this.nextIsEvent = false,
  });

  final Date? targetDate;
  final DateTime? targetPeriodStart;

  /// Block id immediately above this drop zone (null = top of section).
  final String? prevBlockId;

  /// Priority id of the block above (null = top of section).
  final PriorityId? prevPriorityId;

  /// Block id immediately below this drop zone (null = bottom of section).
  final String? nextBlockId;

  /// Priority id of the block below (null = bottom of section).
  final PriorityId? nextPriorityId;

  /// True when the block immediately below this drop zone is a scheduled
  /// event. Used by the activation algorithm to treat the event's vertical
  /// footprint as a deadzone — a dragged block can't land "inside" or
  /// adjacent to an event because events are anchored to a fixed time and
  /// a drop there has no useful semantics.
  final bool nextIsEvent;

  @override
  List<Object?> get props => [
    targetDate,
    targetPeriodStart,
    prevBlockId,
    prevPriorityId,
    nextBlockId,
    nextPriorityId,
    nextIsEvent,
  ];
}

typedef BlockDropDispatcher =
    void Function(BlockDragPayload payload, BlockDropTarget target);

/// Pure boundary builder.
///
/// Walks an agenda's flat item list and emits the [BlockDropTarget]
/// metadata for each [BlockDropZone] the page renders.
///
/// Returns:
///   * `before[i]` — boundary rendered ABOVE item `i` (block-introducing
///     headers and date/text section breaks).
///   * `after[i]` — boundary rendered BELOW item `i` (only set on date
///     headers of empty sections so users can still drop on those dates).
///   * `afterList` — boundary rendered after the last item, when the
///     trailing section ended on a non-empty block.
///
/// **Period attribution rule** (the subtle bit):
/// the boundary just ABOVE a *gap header* belongs to that gap's own
/// period, not the surrounding period. Visually the boundary is the top
/// edge of the gap block — dragging another block onto it should land
/// inside that block. Boundaries above events / priority blocks keep
/// the surrounding period because those blocks live IN that period.
({
  Map<int, BlockDropTarget> before,
  Map<int, BlockDropTarget> after,
  BlockDropTarget? afterList,
}) computeBlockDropBoundaries({
  required List<AgendaItem> items,
}) {
  final before = <int, BlockDropTarget>{};
  final after = <int, BlockDropTarget>{};
  BlockDropTarget? afterList;

  Date? currentDate;
  DateTime? currentPeriodStart;
  String? prevBlockId;
  PriorityId? prevPriorityId;
  int? sectionDateIndex;
  Date? sectionDateValue;

  void resetSection() {
    currentDate = null;
    currentPeriodStart = null;
    prevBlockId = null;
    prevPriorityId = null;
  }

  void maybeEmitEmptySectionAfter() {
    if (sectionDateIndex == null || sectionDateValue == null) return;
    if (prevBlockId != null) return;
    after[sectionDateIndex] = BlockDropTarget(
      targetDate: sectionDateValue,
      targetPeriodStart: null,
      prevBlockId: null,
      prevPriorityId: null,
      nextBlockId: null,
      nextPriorityId: null,
    );
  }

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! AgendaHeaderItem) continue;
    final isSectionBreak = item.date != null ||
        (item.text != null &&
            item.dateTimeRange == null &&
            item.thread == null &&
            item.parentBlockId == null);
    if (isSectionBreak) {
      if (prevBlockId != null) {
        before[i] = BlockDropTarget(
          targetDate: currentDate,
          targetPeriodStart: currentPeriodStart,
          prevBlockId: prevBlockId,
          prevPriorityId: prevPriorityId,
          nextBlockId: null,
          nextPriorityId: null,
        );
      }
      maybeEmitEmptySectionAfter();
      resetSection();
      if (item.date != null) {
        currentDate = item.date;
        sectionDateIndex = i;
        sectionDateValue = item.date;
      } else {
        sectionDateIndex = null;
        sectionDateValue = null;
      }
      continue;
    }
    if (item.parentBlockId != null) {
      final isGapHeader = item.dateTimeRange != null &&
          item.thread == null &&
          item.sourcePeriodStart != null;
      before[i] = BlockDropTarget(
        targetDate: currentDate,
        targetPeriodStart: isGapHeader
            ? item.sourcePeriodStart
            : currentPeriodStart,
        prevBlockId: prevBlockId,
        prevPriorityId: prevPriorityId,
        nextBlockId: item.parentBlockId,
        nextPriorityId: item.blockPriority?.id,
        nextIsEvent: item.thread != null,
      );
      if (isGapHeader) {
        currentPeriodStart = item.sourcePeriodStart;
      }
      prevBlockId = item.parentBlockId;
      prevPriorityId = item.blockPriority?.id;
    }
  }
  maybeEmitEmptySectionAfter();
  if (prevBlockId != null) {
    afterList = BlockDropTarget(
      targetDate: currentDate,
      targetPeriodStart: currentPeriodStart,
      prevBlockId: prevBlockId,
      prevPriorityId: prevPriorityId,
      nextBlockId: null,
      nextPriorityId: null,
    );
  }

  return (before: before, after: after, afterList: afterList);
}

/// Builds a dimmed preview widget representing the dragged block's
/// content (its header + visible thread rows). The active
/// [BlockDropZone] renders this so the gap shows what will land there
/// instead of empty space. Returns `null` when the source block can't
/// be located in the current agenda items (treated as a fallback to
/// the empty-gap behavior).
typedef BlockDragPreviewBuilder = Widget? Function(BlockDragPayload payload);

/// Internal record of one [BlockDropZone] currently mounted in the tree.
///
/// [owner] is an opaque identity (the registering State instance) used to
/// guard against stale unregisters. When two widgets transiently share a
/// slotKey across a rebuild — Flutter mounts the new State, the new State
/// calls `registerSlot`, and only THEN does the old State's `dispose` fire
/// `unregisterSlot` with the same key — the old State's unregister would
/// otherwise wipe the entry the new State just wrote. By comparing
/// `owner`, the controller skips unregisters from a State that's no
/// longer the rightful owner of the slot.
class _SlotEntry {
  _SlotEntry({
    required this.target,
    required this.contextProvider,
    required this.owner,
  });

  final BlockDropTarget target;

  /// Closure that yields the current [BuildContext] of the zone — used
  /// to read its [RenderBox] for vertical anchor capture.
  final BuildContext Function() contextProvider;

  /// Identity of the State that registered this entry. Used by
  /// [BlockDragController.unregisterSlot] to skip stale unregisters
  /// from a previous-but-displaced State.
  final Object owner;
}

/// Helper record for the block-center activation algorithm.
class _OrderedSlot {
  _OrderedSlot({
    required this.key,
    required this.y,
    required this.target,
  });

  final Object key;
  final double y;
  final BlockDropTarget target;
}

/// Result of one activation pass — which slot won (if any).
@visibleForTesting
class BlockDragActivation {
  const BlockDragActivation({this.key, this.target});

  /// Stable key of the active slot. Null when the cursor sits inside
  /// the source's at-rest region with no prior active slot (= "no
  /// swap" / preview-at-source / cancel-on-release), or when the
  /// agenda has no valid drop slots at all.
  final Object? key;

  /// Target metadata of the active slot. Always paired with [key]:
  /// both null or both non-null.
  final BlockDropTarget? target;

  static const none = BlockDragActivation();
}

/// Pure activation logic, exposed for unit testing.
///
/// **Model — direction-aware drop-target activation.**
///
/// Each non-source block X owns a "drop area" = X's region in the
/// live layout. The slot the cursor activates depends on drag
/// direction — cursor above vs. below source's CURRENT preview
/// position (the active slot when one exists, else `sourceAtRestTopY`):
///
///   * **Drag-down** (cursor below the preview): cursor in X →
///     K_after_X (the slot just after X). Threshold for the next
///     swap is at the next block's TOP edge.
///
///   * **Drag-up** (cursor above the preview): cursor in X →
///     K_above_X (the slot just before X). Threshold for the next
///     swap is at X's TOP edge (= the previous block's BOTTOM edge).
///
/// The asymmetry mirrors how a drop reads visually: dragging down,
/// the dropped block lands BELOW the cursor's block; dragging up,
/// ABOVE. Without it, drag-up would not advance source as the
/// cursor crosses each block boundary — the user would have to
/// overshoot by a full block height before the next swap fired.
///
/// **Carve-outs:**
///
///   1. **Tie-breaker — never move a placeholder while the cursor is
///      inside it.** If a slot is currently active and the cursor is
///      inside its expanded preview band `[Y, Y + activeSlotExpansion]`,
///      no transition. If no slot is active and the cursor is inside
///      the source's at-rest region (the bracket between
///      `K_above_source` and `K_after_source`), no transition. This
///      takes precedence over every other rule.
///
///   2. **Source-flank no-swap.** A block whose K_after slot is filtered
///      (the immediate upper neighbor of the source) has no valid drop
///      target — cursor here holds the previously-active slot, or
///      sits at "no swap" (preview at source) if nothing has activated
///      yet. Per "preview never bounces back to source," once a slot
///      has been active, returning to a no-swap zone holds it.
///
///   3. **First-block-of-agenda split.** When the very first block of
///      the agenda is not source AND `K_above_first` is valid, the
///      first block's drop area is split: top H pixels (where H =
///      `activeSlotExpansion` = source's height) → `K_above_first`;
///      remaining → `K_after_first`. This avoids needing the cursor
///      to go off-agenda above to reach the top slot.
///
///   4. **Combined event deadzone.** When two or more events are
///      adjacent with no gap between them, the slots between them
///      (where prev and next are both events) are filtered just like
///      no-op slots — nothing can drop there. The combined region
///      uses a halfway-flip: top half holds at the slot above the
///      first event of the chain; bottom half snaps to the first
///      valid slot below the chain.
///
/// [activeSlotKey]/[activeSlotExpansion] describe the currently-active
/// slot at call time. Pass `null` and `0` for a fresh activation.
@visibleForTesting
BlockDragActivation computeBlockDragActivation({
  required List<({Object key, double y, BlockDropTarget target})> slots,
  required String draggingId,
  required double pointerY,
  Object? activeSlotKey,
  double activeSlotExpansion = 0,
  double? sourceAtRestTopY,
}) {
  if (slots.isEmpty) return BlockDragActivation.none;
  final ordered = [
    for (final s in slots)
      _OrderedSlot(key: s.key, y: s.y, target: s.target),
  ]..sort((a, b) => a.y.compareTo(b.y));

  bool isFiltered(BlockDropTarget t) =>
      t.prevBlockId == draggingId || t.nextBlockId == draggingId;

  // === TIE-BREAKER: cursor inside the active slot's preview band ===
  // No transition. Stability fallback — the active slot's expansion
  // is part of its own activation zone, so cursor over the preview
  // keeps the slot active even if the live layout would otherwise
  // bracket it differently.
  if (activeSlotKey != null && activeSlotExpansion > 0) {
    for (final s in ordered) {
      if (s.key == activeSlotKey &&
          pointerY >= s.y &&
          pointerY < s.y + activeSlotExpansion) {
        return BlockDragActivation(key: activeSlotKey, target: s.target);
      }
    }
  }

  // Off-agenda: pointer past the agenda's ends → hold the previously
  // active slot. Falls through to none on the first pointer event.
  if (pointerY < ordered.first.y || pointerY >= ordered.last.y) {
    return _holdActive(activeSlotKey, ordered);
  }

  // === FIND THE BLOCK CONTAINING THE CURSOR ===
  // Each consecutive pair (ordered[i], ordered[i+1]) brackets one
  // block. Boundaries between source and a neighbor belong to the
  // neighbor (non-source side). Concretely:
  //   - Source's block: bracket is exclusive at any boundary shared
  //     with an adjacent (non-source) block.
  //   - Non-source block: standard [start, end), except the upper
  //     boundary becomes inclusive when the next slot is K_above_source
  //     (= the next block IS source) — so the boundary belongs to this
  //     block, not to source.
  var blockIdx = 0;
  for (var i = 0; i < ordered.length - 1; i++) {
    final isSourceBlock = ordered[i].target.nextBlockId == draggingId &&
        ordered[i + 1].target.prevBlockId == draggingId;
    final bool inLower;
    final bool inUpper;
    if (isSourceBlock) {
      final hasBlockAbove = i > 0;
      final hasBlockBelow = i + 1 < ordered.length - 1;
      inLower = hasBlockAbove
          ? pointerY > ordered[i].y
          : pointerY >= ordered[i].y;
      inUpper = hasBlockBelow
          ? pointerY < ordered[i + 1].y
          : pointerY <= ordered[i + 1].y;
    } else {
      final upperIsAboveSource =
          ordered[i + 1].target.nextBlockId == draggingId;
      inLower = pointerY >= ordered[i].y;
      inUpper = upperIsAboveSource
          ? pointerY <= ordered[i + 1].y
          : pointerY < ordered[i + 1].y;
    }
    if (inLower && inUpper) {
      blockIdx = i;
      break;
    }
  }

  final kAbove = ordered[blockIdx];
  final kAfter = ordered[blockIdx + 1];

  // Source block (both flanks reference source): only fires when no
  // slot is active. With an active slot, source is collapsed to 0
  // height in the live layout, so the bracket between K_above_source
  // and K_after_source is degenerate and should not catch the cursor
  // (which is over a different live block that happens to overlap
  // source's at-rest screen area). The date-aware swap-back below
  // handles the active case.
  final isSource = kAbove.target.nextBlockId == draggingId &&
      kAfter.target.prevBlockId == draggingId;
  if (isSource && activeSlotKey == null) {
    return _holdActive(activeSlotKey, ordered);
  }

  // === SWAP-BACK: cursor in source's at-rest screen region ===
  // Cursor inside the source's original screen area means "preview
  // at source" — return none, regardless of whether a slot is
  // currently active. Firing this in the inactive state too is what
  // prevents oscillation: without it, mid-animation (slot deactivating
  // → layout settling) the bracketing finds a same-day block whose
  // K_after is filtered (= source-flank), and the default rule's
  // fall-back would re-activate the same slot, kicking off another
  // animation cycle. With the swap-back firing in both states, the
  // result stays "none" once the cursor is in source's at-rest.
  //
  // The date-match guard ensures different-day blocks that have
  // shifted into source's at-rest screen area (because of source-
  // collapse) keep their own day's activation rules — only same-day
  // blocks trigger return-to-source.
  if (sourceAtRestTopY != null && activeSlotExpansion > 0) {
    final topY = sourceAtRestTopY;
    final bottomY = sourceAtRestTopY + activeSlotExpansion;
    var sourceAtTop = false;
    var sourceAtBottom = false;
    Date? sourceDate;
    for (final s in ordered) {
      if (s.target.nextBlockId == draggingId) {
        if (s.target.prevBlockId == null) sourceAtTop = true;
        sourceDate = s.target.targetDate;
      }
      if (s.target.prevBlockId == draggingId &&
          s.target.nextBlockId == null) {
        sourceAtBottom = true;
      }
    }
    final inLower = sourceAtTop ? pointerY >= topY : pointerY > topY;
    final inUpper =
        sourceAtBottom ? pointerY <= bottomY : pointerY < bottomY;
    if (inLower && inUpper) {
      // Same date as source → cursor is returning to source's day,
      // deactivate. Different date → cursor is over a different day's
      // content, fall through to that block's activation rules.
      if (kAbove.target.targetDate == sourceDate) {
        return BlockDragActivation.none;
      }
    }
  }

  // === COMBINED EVENT DEADZONE ===
  // Block X is an event AND the next block is also an event (= the
  // slot K_after_X is between two events). The chain might span
  // several events; find its full extent and apply the halfway flip.
  final isEvent = kAbove.target.nextIsEvent;
  if (isEvent &&
      blockIdx + 1 < ordered.length - 1 &&
      ordered[blockIdx + 1].target.nextIsEvent) {
    var chainStart = blockIdx;
    while (chainStart > 0 && ordered[chainStart - 1].target.nextIsEvent) {
      chainStart--;
    }
    var chainEnd = blockIdx;
    while (chainEnd + 1 < ordered.length - 1 &&
        ordered[chainEnd + 1].target.nextIsEvent) {
      chainEnd++;
    }
    final chainTop = ordered[chainStart].y;
    final chainBottom = ordered[chainEnd + 1].y;
    final midpoint = (chainTop + chainBottom) / 2;
    if (pointerY < midpoint) {
      // Last valid slot at or before the chain start.
      var idx = chainStart;
      while (idx >= 0 && isFiltered(ordered[idx].target)) {
        idx--;
      }
      if (idx < 0) return _holdActive(activeSlotKey, ordered);
      return BlockDragActivation(
        key: ordered[idx].key,
        target: ordered[idx].target,
      );
    }
    // First valid slot at or after the chain end.
    var idx = chainEnd + 1;
    while (idx < ordered.length && isFiltered(ordered[idx].target)) {
      idx++;
    }
    if (idx >= ordered.length) return _holdActive(activeSlotKey, ordered);
    return BlockDragActivation(
      key: ordered[idx].key,
      target: ordered[idx].target,
    );
  }

  // === FIRST-BLOCK-OF-SECTION SPLIT ===
  // Any block that's the first of its section (K_above.prev == null,
  // meaning the boundary builder reset prevBlockId at a date/section
  // header just before this block) owns its top H pixels for
  // K_above_X. The remaining height falls through to the default
  // rule. This lets the user reach "drop at the top of this section"
  // without going off-agenda above, AND it makes the swap into first
  // position of any new day (not just the first block of the agenda)
  // work both ways: drag down enters the top-H zone first, drag back
  // up re-enters the same zone.
  if (kAbove.target.prevBlockId == null && !isFiltered(kAbove.target)) {
    final topThreshold = kAbove.y + activeSlotExpansion;
    if (pointerY <= topThreshold) {
      return BlockDragActivation(key: kAbove.key, target: kAbove.target);
    }
    // Fall through to the default rule for the bottom portion.
  }

  // === DEFAULT RULE: direction-aware ===
  // Drag-up (cursor above source's CURRENT preview position):
  // cursor in X → K_above_X (drop just before X). As the cursor
  // crosses each block boundary going up, source advances one
  // position; threshold sits at the entered block's TOP edge.
  //
  // Drag-down (cursor at or below source's preview): cursor in X →
  // K_after_X (drop just after X). Symmetric — entering each block
  // going down advances source; threshold at the next block's TOP.
  //
  // **Reference tracks source's PREVIEW, not its at-rest top.**
  // When a slot is active, source is collapsed and the active
  // slot's expanded band stands in for source's vertical
  // occupancy. After a downward drag, source's at-rest screen
  // region is occupied by other blocks (the live layout shifted
  // them up to fill source's collapse). Using `sourceAtRestTopY`
  // as the reference there would mis-classify drag-up movement as
  // drag-down for any block now sitting between source's at-rest
  // bottom and the active band — landing the preview one position
  // too low. The fallback is `sourceAtRestTopY` only when no slot
  // is active (drag start, or after a swap-back deactivated).
  //
  // Source-flank fallback: if the preferred slot is filtered (its
  // prev or next equals source — would be a no-op drop), use the
  // other side. Both filtered → hold the previously active slot.
  // The drag-up + drag-down rules already pick the correct slot
  // for cursor-over-source's-immediate-neighbor cases; this
  // fallback covers degenerate edges (unknown direction with a
  // filtered preferred slot).
  double? referenceTopY;
  if (activeSlotKey != null) {
    for (final s in ordered) {
      if (s.key == activeSlotKey) {
        referenceTopY = s.y;
        break;
      }
    }
  }
  referenceTopY ??= sourceAtRestTopY;
  final isDragUp = referenceTopY != null && pointerY < referenceTopY;
  final preferred = isDragUp ? kAbove : kAfter;
  final fallback = isDragUp ? kAfter : kAbove;
  if (!isFiltered(preferred.target)) {
    return BlockDragActivation(key: preferred.key, target: preferred.target);
  }
  if (!isFiltered(fallback.target)) {
    return BlockDragActivation(key: fallback.key, target: fallback.target);
  }
  return _holdActive(activeSlotKey, ordered);
}

/// Return the [BlockDragActivation] for [key] if it's still in
/// [ordered]; otherwise [BlockDragActivation.none].
BlockDragActivation _holdActive(Object? key, List<_OrderedSlot> ordered) {
  if (key == null) return BlockDragActivation.none;
  for (final s in ordered) {
    if (s.key == key) {
      return BlockDragActivation(key: key, target: s.target);
    }
  }
  return BlockDragActivation.none;
}

/// Controller for the block drag interaction.
///
/// **Model — block-region drop areas with thresholds at block tops.**
/// See [computeBlockDragActivation] for the full algorithm; in
/// summary:
///
///   1. **Default rule (direction-aware)**: cursor in block X →
///      preview at K_after_X when dragging down (cursor below
///      source's current preview), K_above_X when dragging up
///      (cursor above it). The preview position is the active
///      slot's live Y when a slot is active, else source's at-rest
///      top. Threshold for the next swap sits at the next block's
///      TOP for drag-down and at the current block's TOP for
///      drag-up — so as the cursor crosses each block boundary in
///      either direction, source advances by one position.
///
///   2. **Tie-breaker**: cursor inside the current placeholder
///      (active slot's preview band, or source's at-rest region with
///      no prior active) → no transition. The placeholder you're
///      hovering over never moves under you.
///
///   3. **Source-flank no-swap**: a block whose K_after is filtered
///      (the upper neighbor of source) has no valid drop target —
///      cursor here holds the previously-active slot, or no swap if
///      nothing has activated yet. Per "preview never bounces back to
///      source," once a slot has been active, returning to a no-swap
///      zone holds it.
///
///   4. **First-block-of-agenda split**: when the very first block
///      is not source AND K_above_first is valid, the first block's
///      top H pixels (H = source's height) → K_above_first; the rest
///      → K_after_first. Avoids needing the cursor to go off-agenda.
///
///   5. **Combined event deadzone**: when adjacent events have no
///      gap between them, the slot between them is filtered (nothing
///      can drop there) and the combined region uses a halfway-flip
///      between the slot above the chain and the first valid slot
///      below the chain.
///
/// **Why live reads (not snapshot at drag start).** Auto-scroll and
/// pagination shift slot positions independently of activation. Live
/// reads always see the current layout, which is what the user is
/// interacting with. Activation-induced layout shift (source collapse
/// + active slot expansion = total height conserved) is handled by
/// the tie-breaker rule above, not by trying to lock slot Ys.
class BlockDragController extends ChangeNotifier {
  BlockDragController({TickerProvider? vsync}) {
    if (vsync != null) {
      _animController = AnimationController(
        vsync: vsync,
        duration: kBlockBoundaryAnimDuration,
      )..addListener(notifyListeners);
    }
  }

  String? _draggingBlockId;
  BlockDragPayload? _draggingPayload;
  Offset? _pointerPosition;
  Object? _activeSlotKey;
  BlockDropTarget? _activeTarget;
  BlockDropDispatcher? _dispatcher;
  BlockDragPreviewBuilder? _previewBuilder;

  /// Drives slot-height transitions via a single coordinated animation
  /// instead of per-[BlockDropZone] [AnimatedContainer]s. Critical for
  /// height conservation under rapid active-slot changes: independent
  /// per-slot tweens retarget from mid-anim values, breaking the mirror
  /// that keeps the running sum at `H` — items that should be stable
  /// jiggle by a few pixels while the user drags. With one shared
  /// controller, every active change snapshots the current configuration
  /// and animates a unified `0→1` progress to the new configuration; sum
  /// is `lerp(snapshot_sum, target_sum, p)` which stays at `H` because
  /// both endpoints are `H`. Null when no [TickerProvider] was supplied
  /// (synthetic test cases that exercise the algorithm only).
  AnimationController? _animController;

  /// Snapshot of every registered slot's height at the moment the
  /// current animation began. Combined with each slot's target height
  /// (`H` for the active slot, `0` otherwise) this lets [slotHeight]
  /// return `lerp(snapshot, target, animProgress)` without per-slot
  /// animation state.
  Map<Object, double> _snapshotHeights = const {};

  /// Total height of the source block (header + visible threads),
  /// captured at drag start. The active drop slot expands to exactly
  /// this height so the agenda's overall height is conserved when
  /// source collapses and slot expands together.
  double? _sourceTotalHeight;

  /// Screen-Y of the source block's TOP at drag start (= top of the
  /// source row's RenderBox). Together with [_sourceTotalHeight], this
  /// defines the source's at-rest screen region — used by the
  /// activation algorithm so cursor returning to the source's
  /// original visual position deactivates whatever slot is active and
  /// brings the source back (swap-back).
  double? _sourceAtRestTopY;

  /// Total height of the source block, or `null` if no drag is in
  /// progress. Used by [BlockDropZone] to size its expanded gap.
  double? get sourceTotalHeight => _sourceTotalHeight;

  /// Current animated height for a slot. Reads `lerp(snapshot, target,
  /// easeOut(progress))` so all slots interpolate against a single
  /// shared progress value — the mirror across active-slot transitions
  /// is exact, and items that should be stable stay stable even when
  /// active changes faster than the animation duration.
  ///
  /// Returns the static target height (no animation) when no
  /// [TickerProvider] was supplied to the controller — used by
  /// synthetic test cases that exercise the activation algorithm
  /// without driving widget animations.
  double slotHeight(Object slotKey) {
    final isActive = _activeSlotKey == slotKey;
    final to = isActive ? (_sourceTotalHeight ?? 0) : 0.0;
    final ctrl = _animController;
    if (ctrl == null) return to;
    final from = _snapshotHeights[slotKey] ?? 0.0;
    final p = Curves.easeOut.transform(ctrl.value);
    return from + (to - from) * p;
  }

  final Map<Object, _SlotEntry> _slots = <Object, _SlotEntry>{};

  String? get draggingBlockId => _draggingBlockId;
  BlockDragPayload? get draggingPayload => _draggingPayload;
  Offset? get pointerPosition => _pointerPosition;
  bool get isDragging => _draggingBlockId != null;

  /// Stable key of the slot currently active (null while the pointer
  /// sits inside the source's footprint deadzone). [BlockDropZone]
  /// listens and expands when this matches its own key.
  Object? get activeSlotKey => _activeSlotKey;

  /// Resolved target for the active slot — passed to the dispatcher on
  /// drag end. Null while the pointer is in the source's deadzone
  /// (drop is then a no-op).
  BlockDropTarget? get activeTarget => _activeTarget;

  /// True while no slot has won — source widgets render "dimmed in
  /// place" rather than "collapsed."
  bool get isSourceVisible => _activeSlotKey == null;

  /// Set the dispatcher fired on a successful drop. The page wires this
  /// to its drop-handling closure (which knows the agenda items).
  set dispatcher(BlockDropDispatcher? value) {
    _dispatcher = value;
  }

  /// Set the preview builder used by the active [BlockDropZone] to
  /// render a dimmed copy of the source block inside the gap. The page
  /// wires this to a closure that walks its current agenda items —
  /// re-set on every build (like [dispatcher]) so the preview always
  /// reflects the latest list.
  set previewBuilder(BlockDragPreviewBuilder? value) {
    _previewBuilder = value;
  }

  /// Build the dimmed preview for the in-flight drag, or `null` if
  /// there's no drag in progress / no builder wired up / the source
  /// block can't be located. Callers wrap the result in [Opacity] +
  /// [IgnorePointer] (the builder returns the raw widgets so callers
  /// control dim styling).
  Widget? buildPreview() {
    final builder = _previewBuilder;
    final payload = _draggingPayload;
    if (builder == null || payload == null) return null;
    return builder(payload);
  }

  /// Register a [BlockDropZone] under [key] so the controller can
  /// consider it when picking the active slot. Idempotent —
  /// re-registering the same key just overwrites the entry.
  ///
  /// Slot positions are read live on every pointer event, so there's
  /// no capture step here. Slots that mount mid-drag (scrolled into
  /// view by auto-scroll) become candidates as soon as their
  /// RenderBox is laid out.
  ///
  /// **Never notifies.** Register runs during the build phase (called
  /// from `didChangeDependencies` / `didUpdateWidget`); notifying from
  /// inside build would mark dirty other listening widgets that are
  /// concurrently being built — crashing with the "setState during
  /// build" error.
  void registerSlot({
    required Object key,
    required BlockDropTarget target,
    required BuildContext Function() contextProvider,
    required Object owner,
  }) {
    _slots[key] = _SlotEntry(
      target: target,
      contextProvider: contextProvider,
      owner: owner,
    );
  }

  /// Remove a previously-registered slot. Clears the active reference
  /// if it pointed at this slot.
  void unregisterSlot(Object key, {required Object owner}) {
    final entry = _slots[key];
    if (entry == null) return;
    if (!identical(entry.owner, owner)) {
      // A newer State has claimed this key. The caller is the old
      // State whose dispose is firing AFTER the new State already
      // registered. Skip the removal — otherwise we'd wipe the
      // entry the new State just wrote.
      return;
    }
    _slots.remove(key);
    if (_activeSlotKey == key) {
      _activeSlotKey = null;
      _activeTarget = null;
    }
  }

  /// Read a slot's current screen Y from its [RenderBox]. Returns
  /// `null` when the widget isn't laid out yet.
  double? _readSlotY(Object key) {
    final entry = _slots[key];
    if (entry == null) return null;
    final ctx = entry.contextProvider();
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return null;
    return ro.localToGlobal(Offset.zero).dy;
  }

  /// Begin a drag. [sourceContextProvider] yields the source header's
  /// [BuildContext] so the controller can read its natural height at
  /// drag start (before the source visually collapses).
  void start(
    BlockDragPayload payload, {
    required BuildContext Function() sourceContextProvider,
  }) {
    if (_draggingBlockId == payload.blockId) return;
    _draggingBlockId = payload.blockId;
    _draggingPayload = payload;

    // Reset to a clean "no slot active" baseline. If the previous
    // drag's close animation hadn't finished, residual snapshot
    // heights would feed into the first activation animation as a
    // non-zero "from" — sum would temporarily exceed `H` until they
    // settle. Forcing the controller to its terminal value here
    // makes [slotHeight] return the static target (0 for every
    // slot, since `_activeSlotKey` is still null) until the first
    // [_setActive] kicks off a fresh transition.
    _snapshotHeights = const {};
    _animController?.value = 1;

    _captureSourceHeight(sourceContextProvider);
    notifyListeners();
  }

  /// Capture the source block's natural height at drag start. The
  /// drop zone expands to this height when active, so source-collapse
  /// + slot-expansion conserve total agenda height.
  ///
  /// Computed as `afterSourceY - sourceTopY` where afterSourceY is
  /// the slot whose `prevBlockId == source.id` (i.e. the boundary
  /// rendered immediately below source). That slot has zero height
  /// at rest, so its top Y is the next block's top — i.e. source's
  /// natural bottom. Falls back to header height when no such slot
  /// is mounted.
  void _captureSourceHeight(BuildContext Function() sourceContextProvider) {
    _sourceTotalHeight = null;
    _sourceAtRestTopY = null;

    final sourceCtx = sourceContextProvider();
    final sourceRO = sourceCtx.findRenderObject();
    final draggingId = _draggingBlockId;
    final payload = _draggingPayload;
    if (sourceRO is! RenderBox || !sourceRO.hasSize) return;
    final sourceTopY = sourceRO.localToGlobal(Offset.zero).dy;
    final sourceHeaderHeight = sourceRO.size.height;
    _sourceAtRestTopY = sourceTopY;

    double? afterSourceY;
    for (final entry in _slots.entries) {
      if (entry.value.target.prevBlockId == draggingId) {
        afterSourceY = _readSlotY(entry.key);
        if (afterSourceY != null) break;
      }
    }

    // Primary: use the K_after_source slot's Y to compute the source's
    // full block height (header + threads + separators).
    if (afterSourceY != null) {
      _sourceTotalHeight = afterSourceY - sourceTopY;
      return;
    }

    // Fallback: estimate from payload.visibleThreadCount + header.
    // The slot-based measurement fails when K_after_source's
    // BlockDropZone is not yet mounted/registered (e.g., a rebuild is
    // in flight when the drag started). Vastly better than the
    // header-only fallback, which would leave the agenda treating this
    // drag as if the source were a 23 px block.
    if (payload != null && payload.visibleThreadCount > 0) {
      _sourceTotalHeight = sourceHeaderHeight +
          payload.visibleThreadCount * kThreadRowApproxHeight;
      return;
    }

    _sourceTotalHeight = sourceHeaderHeight;
  }

  void updatePointer(Offset global) {
    _pointerPosition = global;
    if (isDragging) {
      _recomputeActiveSlot();
    } else {
      notifyListeners();
    }
  }

  /// Called by the source header on drag end. If a slot is currently
  /// active and the dispatcher is wired up, the drop fires before the
  /// drag state is cleared.
  void end({bool dispatch = true}) {
    final dispatcher = _dispatcher;
    final payload = _draggingPayload;
    final target = _activeTarget;

    _draggingBlockId = null;
    _draggingPayload = null;
    _pointerPosition = null;
    // Snap slot heights to 0 immediately on drag end. `_setActive(null,
    // null)` would animate them, but that leaves an in-flight 150ms
    // close animation racing the user's next drag — and reading from
    // `_sourceTotalHeight` mid-animation collides with the cleanup
    // below. Snapping is consistent with the historical AnimatedContainer
    // remount behavior (which forced fresh state on each drag boundary)
    // and avoids visible drift if the user starts another drag immediately.
    _activeSlotKey = null;
    _activeTarget = null;
    _sourceTotalHeight = null;
    _sourceAtRestTopY = null;
    _snapshotHeights = const {};
    _animController?.value = 1;
    notifyListeners();

    if (dispatch && dispatcher != null && payload != null && target != null) {
      dispatcher(payload, target);
    }
  }

  /// Pick the active slot for the current pointer position using the
  /// block-center model with **live slot reads**.
  ///
  /// Read each registered slot's current screen Y from its [RenderBox],
  /// sort by Y, find the bracketing pair for the pointer, and split
  /// that block in half: top half → "before" slot; bottom half →
  /// "after" slot. Filter out candidates that would be no-op drops
  /// (the slot's prev or next equals the dragged block).
  ///
  /// Live reads keep the comparison consistent with the visible
  /// layout — source collapse, slot expansion, and auto-scroll all
  /// shift screen positions, but each slot's RenderBox always reports
  /// its CURRENT frame, so the pointer maps to the slot it's visually
  /// over. Block-center activation prevents oscillation: even though
  /// other slots move when the active slot changes, the pointer stays
  /// in the same logical block (= gap between flanking slots) and the
  /// same slot stays active.
  void _recomputeActiveSlot() {
    final pointer = _pointerPosition;
    final draggingId = _draggingBlockId;
    if (pointer == null || draggingId == null) {
      _setActive(null, null);
      return;
    }

    final slots = <({Object key, double y, BlockDropTarget target})>[];
    for (final entry in _slots.entries) {
      final y = _readSlotY(entry.key);
      if (y == null) continue;
      slots.add((key: entry.key, y: y, target: entry.value.target));
    }

    final result = computeBlockDragActivation(
      slots: slots,
      draggingId: draggingId,
      pointerY: pointer.dy,
      activeSlotKey: _activeSlotKey,
      activeSlotExpansion: _sourceTotalHeight ?? 0,
      sourceAtRestTopY: _sourceAtRestTopY,
    );

    _setActive(result.key, result.target);
  }

  void _setActive(Object? key, BlockDropTarget? target) {
    if (key == _activeSlotKey && target == _activeTarget) return;

    // Snapshot every registered slot's CURRENT animated height — this
    // is the "from" state for the new transition. Capturing all slots
    // (not just the changing pair) keeps the running sum at `H` even
    // when active changes mid-animation: snapshot_sum equals the
    // previous animation's running sum (which is `H` because that
    // animation was conserving), and target_sum is `H` (one slot at
    // `H`, others at `0`). Sum during the new animation is
    // `lerp(H, H, p)` = `H`, so items in the stable region stay put.
    //
    // Read heights via the public [slotHeight] getter so the snapshot
    // uses the same `_activeSlotKey`/`_animController.value` as the
    // current frame's [BlockDropZone] paints. Computing snapshots
    // BEFORE mutating `_activeSlotKey` is what makes this correct.
    final ctrl = _animController;
    if (ctrl != null) {
      final snapshot = <Object, double>{};
      for (final slotKey in _slots.keys) {
        snapshot[slotKey] = slotHeight(slotKey);
      }
      _snapshotHeights = snapshot;
    }

    _activeSlotKey = key;
    _activeTarget = target;

    if (ctrl != null) {
      ctrl.value = 0;
      ctrl.forward();
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _animController?.dispose();
    super.dispose();
  }
}

/// Inherited scope that provides [BlockDragController] access via
/// [BlockDragScope.of].
class BlockDragScope extends InheritedWidget {
  const BlockDragScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final BlockDragController controller;

  static BlockDragController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<BlockDragScope>()
        ?.controller;
  }

  static BlockDragController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'BlockDragScope.of called outside scope');
    return controller!;
  }

  @override
  bool updateShouldNotify(BlockDragScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Default heights for [BlockDropZone].
const double kBlockBoundaryRestHeight = 0;

/// Approximate intrinsic height of an [AgendaTile] block-header row
/// (priority-tinted breadcrumb at xs typography + vertical padding).
/// Used as a baseline when the dropped block has no thread rows.
const double kBlockHeaderApproxHeight = 28;

/// Approximate height of one [ThreadWidget] row in the agenda (incl.
/// padding + separator). Block drop zones expand by
/// [kBlockHeaderApproxHeight] + this × visibleThreadCount so the gap
/// matches the dragged block's height.
const double kThreadRowApproxHeight = 56;

const Duration kBlockBoundaryAnimDuration = Duration(milliseconds: 150);

/// Duration of a priority block's expand/collapse animation. Matches
/// the boundary animation so the two transitions read as one motion
/// when a block-drag drop lands inside a collapsing block.
const Duration kBlockExpandAnimDuration = Duration(milliseconds: 200);

/// Compute the expanded height of a [BlockDropZone] for a payload —
/// matches the dragged block's (header + visible threads) height so
/// dropping in a zone "fits" the source block.
double dropZoneHeightFor(BlockDragPayload payload) {
  return kBlockHeaderApproxHeight +
      payload.visibleThreadCount * kThreadRowApproxHeight;
}

/// Wraps an agenda row inside a block. While the parent block is being
/// dragged the row dims (cursor still in source deadzone) or collapses
/// (cursor over a real drop slot, so the source's space has logically
/// moved). Non-matching rows pass through unchanged.
class BlockDragHidden extends StatefulWidget {
  const BlockDragHidden({
    required this.parentBlockId,
    required this.child,
    super.key,
  });

  final String? parentBlockId;
  final Widget child;

  @override
  State<BlockDragHidden> createState() => _BlockDragHiddenState();
}

class _BlockDragHiddenState extends State<BlockDragHidden> {
  BlockDragController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = BlockDragScope.maybeOf(context);
    if (newController != _controller) {
      _controller?.removeListener(_onChanged);
      _controller = newController;
      _controller?.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.parentBlockId;
    final controller = _controller;
    final isThis = id != null && controller?.draggingBlockId == id;
    if (!isThis) return widget.child;
    final visible = controller!.isSourceVisible;
    return AnimatedSize(
      duration: kBlockBoundaryAnimDuration,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: visible
          ? Opacity(opacity: 0.4, child: widget.child)
          : const SizedBox.shrink(),
    );
  }
}

/// A drop slot rendered between two adjacent agenda blocks (or at the
/// top/bottom of a date section). Stays at [kBlockBoundaryRestHeight]
/// at rest. Expands to the dragged block's full height when the
/// controller marks it active. The expanded gap *is* the drop indicator
/// — there's no separate placeholder line, so the user sees the agenda
/// open up exactly where the block will land.
///
/// Drop dispatch happens on the source header's drag-end via the
/// [BlockDragController.activeTarget], not on this widget — see the
/// controller class doc for why we don't use [DragTarget] here.
class BlockDropZone extends StatefulWidget {
  const BlockDropZone({
    required this.target,
    required this.slotKey,
    this.silent = false,
    this.dividerAbove = false,
    this.dividerBelow = false,
    super.key,
  });

  final BlockDropTarget target;

  /// Stable key the controller uses to identify this slot across
  /// rebuilds. The page passes a value derived from the surrounding
  /// row's stableKey + boundary position so reorders/scrolls don't
  /// churn registrations.
  final Object slotKey;

  /// When true the zone never visually expands. It still registers as a
  /// drop slot so the activation algorithm can pick it up — but a
  /// sibling [BlockDropZone] with an equal [target] is what visually
  /// shows the gap. Used by the Activity feed's Done section: a
  /// "phantom" tail slot below the last done thread keeps the cursor
  /// inside an activatable region while the visible gap stays anchored
  /// at the top of Done.
  final bool silent;

  /// When true, a 1px divider in the standard border color is painted
  /// at the top edge of the expanded gap. Use this when the zone sits
  /// directly below another row in the same column with no separator
  /// between them, so the active gap and the row above are visually
  /// separated. Drawn within the expanded height (so the total layout
  /// footprint is unchanged).
  final bool dividerAbove;

  /// When true, a 1px divider in the standard border color is painted
  /// at the bottom edge of the expanded gap. Use this when the zone
  /// sits directly above another row in the same column, so the active
  /// gap and the row below it are visually separated. Drawn within the
  /// expanded height (so the total layout footprint is unchanged).
  final bool dividerBelow;

  @override
  State<BlockDropZone> createState() => _BlockDropZoneState();
}

class _BlockDropZoneState extends State<BlockDropZone> {
  BlockDragController? _controller;

  /// Last preview rendered while this slot was active. Held through the
  /// close animation so the gap doesn't snap to empty mid-shrink when
  /// another slot wins. Cleared when the close animation completes (and
  /// when the drag itself ends).
  Widget? _heldPreview;
  Timer? _clearHeldTimer;

  /// True when this zone should visually display the active drop gap.
  /// Silent zones never show; otherwise the zone activates either when
  /// the controller picked its own slotKey (the normal 1:1 case) or
  /// when a sibling slot with an equal target is active. Target-equality
  /// is what lets the visible top-of-Done zone keep its gap open while
  /// the cursor sits over a phantom sibling below the last done thread.
  bool get _isActive {
    if (widget.silent) return false;
    final controller = _controller;
    if (controller == null) return false;
    if (controller.activeSlotKey == widget.slotKey) return true;
    return controller.activeTarget == widget.target;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = BlockDragScope.maybeOf(context);
    if (newController != _controller) {
      _controller?.removeListener(_onChanged);
      _controller?.unregisterSlot(widget.slotKey, owner: this);
      _controller = newController;
      _controller?.addListener(_onChanged);
      _controller?.registerSlot(
        key: widget.slotKey,
        target: widget.target,
        contextProvider: () => context,
        owner: this,
      );
    }
  }

  @override
  void didUpdateWidget(BlockDropZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slotKey != widget.slotKey) {
      // Genuine slot change — unregister the old key, register the
      // new one. If the old key was the active slot, the controller
      // clears `_activeSlotKey` (the next pointer event re-resolves
      // activation against the new slots).
      _controller?.unregisterSlot(oldWidget.slotKey, owner: this);
      _controller?.registerSlot(
        key: widget.slotKey,
        target: widget.target,
        contextProvider: () => context,
        owner: this,
      );
    } else if (oldWidget.target != widget.target) {
      // Same slot key, fresh target metadata (e.g., parent rebuilt
      // because items shifted but the boundary's logical position is
      // unchanged). Overwrite the entry without unregister/register
      // churn — `_activeSlotKey` is preserved, so an in-flight drag
      // with this slot active doesn't lose its activation when the
      // parent rebuilds.
      _controller?.registerSlot(
        key: widget.slotKey,
        target: widget.target,
        contextProvider: () => context,
        owner: this,
      );
    }
  }

  @override
  void dispose() {
    _clearHeldTimer?.cancel();
    // Pass `this` as owner so the controller can guard against the
    // dispose-after-new-mount ordering: if a new State has already
    // registered the same slotKey before this old State's dispose
    // runs, the controller skips the unregister.
    _controller?.unregisterSlot(widget.slotKey, owner: this);
    _controller?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final payload = controller?.draggingPayload;
    final isActive = _isActive && payload != null;

    // Read the slot's height from the controller's coordinated animation.
    // When no controller is in scope (the widget renders outside a
    // [BlockDragScope]), there's no drag in progress so the slot is at
    // rest. The coordinated animation keeps the running sum across all
    // slots conserved during active-slot changes — items below a
    // transitioning region stay stable even when the user crosses
    // several block boundaries faster than the 150ms animation duration.
    // See [BlockDragController.slotHeight].
    final height = controller?.slotHeight(widget.slotKey) ??
        kBlockBoundaryRestHeight;

    // Resolve the dimmed preview widget. While active, ask the
    // controller for a freshly-built preview and cache it. While
    // inactive but still mid-close-animation, keep showing the cached
    // preview so the user sees the block content shrink away (not the
    // gap snap to blank). Once the drag ends or the close animation
    // finishes, drop the held preview.
    Widget? previewContent;
    if (isActive) {
      _clearHeldTimer?.cancel();
      _clearHeldTimer = null;
      _heldPreview = controller?.buildPreview() ?? _heldPreview;
      previewContent = _heldPreview;
    } else if (_heldPreview != null) {
      if (payload == null) {
        // Drag ended — clear immediately. The slot collapses on the
        // next frame regardless.
        _heldPreview = null;
      } else {
        // Close animation: keep the preview mounted for one animation
        // duration, then drop it.
        _clearHeldTimer ??= Timer(kBlockBoundaryAnimDuration, () {
          if (!mounted) return;
          setState(() {
            _heldPreview = null;
          });
        });
        previewContent = _heldPreview;
      }
    }

    final dimmed = previewContent != null
        ? IgnorePointer(
            child: Opacity(opacity: 0.4, child: previewContent),
          )
        : null;

    // [OverflowBox] lets the preview render at its full intrinsic height
    // even when the slot's animated height is smaller — without it, mid-
    // animation frames (animated height < preview height) trip Flutter's
    // RenderFlex overflow check on the preview's [Column]. The surrounding
    // [ClipRect] still clips the visual to the slot's animated height.
    final dividerColor = Color.alphaBlend(
      context.theme.colors.border,
      context.colour.background,
    );

    // Top/bottom border paint inside the box's bounds, so each divider
    // occupies a 1px slice of the expanded gap without growing the
    // footprint. Only applied when the zone is active and the caller
    // opted in via the corresponding flag.
    final showTop = isActive && widget.dividerAbove;
    final showBottom = isActive && widget.dividerBelow;
    return ClipRect(
      child: Container(
        height: height,
        decoration: showTop || showBottom
            ? BoxDecoration(
                border: Border(
                  top: showTop
                      ? BorderSide(color: dividerColor, width: 1)
                      : BorderSide.none,
                  bottom: showBottom
                      ? BorderSide(color: dividerColor, width: 1)
                      : BorderSide.none,
                ),
              )
            : null,
        child: dimmed == null
            ? null
            : OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: 0,
                maxHeight: double.infinity,
                child: dimmed,
              ),
      ),
    );
  }
}

/// Wraps a row in the floating-feedback frame used by every block drag
/// (activity-feed thread, agenda block, …). The 1px border is painted
/// at double the theme's native border alpha so the lifted card reads
/// as a distinct object on top of whatever it's dragged over —
/// `theme.colors.border` is a translucent line built for at-rest
/// separation between rows that share a background, which is too
/// subtle on a transient overlay. Mirrors the brightened-border
/// treatment used by hover/focus dividers in [BlockListSeparator].
class DraggedRowFrame extends StatelessWidget {
  const DraggedRowFrame({
    required this.width,
    required this.child,
    super.key,
  });

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderColor = context.theme.colors.border;
    final bright = borderColor.withValues(
      alpha: (borderColor.a * 2).clamp(0.0, 1.0),
    );
    final dividerColor = Color.alphaBlend(bright, context.colour.background);
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colour.background,
          border: Border.all(color: dividerColor, width: 1),
        ),
        child: child,
      ),
    );
  }
}
