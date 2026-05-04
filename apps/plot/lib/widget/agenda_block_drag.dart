import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:plot/store/store.dart';

final _log = Logger('plot.widget.agenda_block_drag');

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

  /// Number of thread rows the source block currently renders. Combined
  /// with the captured source bounds, this lets the controller leave
  /// the source visually in place and only collapse it when the cursor
  /// crosses out of the source's deadzone.
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

/// Builds a dimmed preview widget representing the dragged block's
/// content (its header + visible thread rows). The active
/// [BlockDropZone] renders this so the gap shows what will land there
/// instead of empty space. Returns `null` when the source block can't
/// be located in the current agenda items (treated as a fallback to
/// the empty-gap behavior).
typedef BlockDragPreviewBuilder = Widget? Function(BlockDragPayload payload);

/// Internal record of one [BlockDropZone] currently mounted in the tree.
class _SlotEntry {
  _SlotEntry({required this.target, required this.contextProvider});

  final BlockDropTarget target;

  /// Closure that yields the current [BuildContext] of the zone — used
  /// to read its [RenderBox] for vertical anchor capture.
  final BuildContext Function() contextProvider;
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

  /// Stable key of the active slot. Null when no slot is active
  /// (pointer in source's deadzone, over an event, or off the agenda).
  final Object? key;

  /// Target metadata of the active slot. Always paired with [key]:
  /// both null or both non-null.
  final BlockDropTarget? target;

  static const none = BlockDragActivation();
}

/// Pure activation logic, exposed for unit testing. Given a list of
/// slots (key + screen Y + target metadata) and the dragged block's
/// id + pointer Y, returns which slot should be active.
///
/// Algorithm: sort slots by Y. Find the bracketing pair for the
/// pointer (the gap between consecutive slots is one block region).
/// Top half of the block → "before" slot; bottom half → "after" slot.
/// Filtered out: slots adjacent to the dragged block (no-op drops),
/// and slots whose `nextIsEvent` is true (events are deadzones —
/// pointer over an event activates nothing).
///
/// Returns [BlockDragActivation.none] when pointer is past the
/// agenda's edges, in source's deadzone (both flanks filtered), or
/// over an event.
@visibleForTesting
BlockDragActivation computeBlockDragActivation({
  required List<({Object key, double y, BlockDropTarget target})> slots,
  required String draggingId,
  required double pointerY,
}) {
  if (slots.isEmpty) return BlockDragActivation.none;
  final ordered = [
    for (final s in slots)
      _OrderedSlot(key: s.key, y: s.y, target: s.target),
  ]..sort((a, b) => a.y.compareTo(b.y));

  if (pointerY < ordered.first.y || pointerY >= ordered.last.y) {
    return BlockDragActivation.none;
  }

  var blockIdx = 0;
  for (var i = 0; i < ordered.length - 1; i++) {
    if (pointerY >= ordered[i].y && pointerY < ordered[i + 1].y) {
      blockIdx = i;
      break;
    }
  }

  final beforeSlot = ordered[blockIdx];
  final afterSlot = ordered[blockIdx + 1];

  // Event-block deadzone: pointer over a scheduled event never
  // activates anything. The block bracketed by (beforeSlot,
  // afterSlot) is identified by `beforeSlot.target.nextIsEvent`.
  if (beforeSlot.target.nextIsEvent) return BlockDragActivation.none;

  final center = (beforeSlot.y + afterSlot.y) / 2;
  final candidate = pointerY < center ? beforeSlot : afterSlot;

  final filtered = candidate.target.prevBlockId == draggingId ||
      candidate.target.nextBlockId == draggingId;
  if (filtered) return BlockDragActivation.none;

  return BlockDragActivation(key: candidate.key, target: candidate.target);
}

/// Controller for the block drag interaction.
///
/// **Model — block-center activation with live reads.** On every
/// pointer event we read each registered slot's CURRENT screen Y from
/// its [RenderBox]. We sort by Y; the gap between two consecutive
/// slots is one block.
///
///   1. Find the block region the pointer falls inside (the gap whose
///      bounds bracket the pointer's Y).
///   2. The block's center splits it in half. Pointer above center →
///      candidate is the "before" slot (top of block). Below center →
///      "after" slot (bottom of block).
///   3. If the candidate would be a no-op drop (`prevBlockId == source`
///      or `nextBlockId == source`), set active = null.
///
/// **Why live reads (not snapshot at drag start).** During a drag
/// three things shift slot positions: source collapse (removes source's
/// height above), active slot expansion (adds source's height back at
/// the active slot), and auto-scroll. A drag-start snapshot drifts out
/// of sync as soon as any of these happen, so the pointer no longer
/// maps to the slot it's visually over. Live reads always see the
/// CURRENT layout, which is what the user is interacting with.
///
/// **Why this doesn't oscillate.** With block-center activation the
/// active slot is determined by which BLOCK the pointer is in (= gap
/// between consecutive slots) and which HALF, not by closest-slot
/// distance. When source collapses + active slot S expands by exactly
/// the same amount, total agenda height is conserved: the layout
/// shift moves OTHER slots' positions, but the gap between the slots
/// flanking the block the pointer is in shifts coherently. The pointer
/// stays in the same logical block, so the same slot stays active.
///
/// **Implicit deadzone.** Source's own block region has both flanking
/// slots filtered (top half → "before source", bottom half → "after
/// source", both no-ops). Pointer in source's range therefore never
/// activates anything.
///
/// **Symmetric activation.** Each non-source block has a clean
/// top-half/bottom-half split, so dragging past a neighbour requires
/// crossing its center — not its top edge — before the neighbour
/// shifts.
class BlockDragController extends ChangeNotifier {
  String? _draggingBlockId;
  BlockDragPayload? _draggingPayload;
  Offset? _pointerPosition;
  Object? _activeSlotKey;
  BlockDropTarget? _activeTarget;
  BlockDropDispatcher? _dispatcher;
  BlockDragPreviewBuilder? _previewBuilder;

  /// Total height of the source block (header + visible threads),
  /// captured at drag start. The active drop slot expands to exactly
  /// this height so the agenda's overall height is conserved when
  /// source collapses and slot expands together.
  double? _sourceTotalHeight;

  /// Total height of the source block, or `null` if no drag is in
  /// progress. Used by [BlockDropZone] to size its expanded gap.
  double? get sourceTotalHeight => _sourceTotalHeight;

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
  }) {
    _slots[key] =
        _SlotEntry(target: target, contextProvider: contextProvider);
  }

  /// Remove a previously-registered slot. Clears the active reference
  /// if it pointed at this slot.
  void unregisterSlot(Object key) {
    final removed = _slots.remove(key);
    if (removed == null) return;
    if (_activeSlotKey == key) {
      _log.info(
        '[block-drag] unregisterSlot cleared active target: '
        'slotKey=$key dragging=$_draggingBlockId',
      );
      _activeSlotKey = null;
      _activeTarget = null;
    } else if (_draggingBlockId != null) {
      _log.fine(
        '[block-drag] unregisterSlot (non-active): slotKey=$key '
        'dragging=$_draggingBlockId',
      );
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
    _captureSourceHeight(sourceContextProvider);
    _log.info(
      '[block-drag] start: blockId=${payload.blockId} '
      'sourceTotalHeight=$_sourceTotalHeight slots=${_slots.length}',
    );
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

    final sourceCtx = sourceContextProvider();
    final sourceRO = sourceCtx.findRenderObject();
    final draggingId = _draggingBlockId;
    if (sourceRO is! RenderBox || !sourceRO.hasSize) return;
    final sourceTopY = sourceRO.localToGlobal(Offset.zero).dy;
    final sourceHeaderHeight = sourceRO.size.height;

    double? afterSourceY;
    for (final entry in _slots.entries) {
      if (entry.value.target.prevBlockId == draggingId) {
        afterSourceY = _readSlotY(entry.key);
        if (afterSourceY != null) break;
      }
    }
    _sourceTotalHeight = afterSourceY != null
        ? afterSourceY - sourceTopY
        : sourceHeaderHeight;
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
    _log.info(
      '[block-drag] end: dispatch=$dispatch '
      'blockId=${payload?.blockId} '
      'hasTarget=${target != null} '
      'targetPrev=${target?.prevBlockId} targetNext=${target?.nextBlockId} '
      'targetDate=${target?.targetDate} '
      'targetPeriodStart=${target?.targetPeriodStart}',
    );

    _draggingBlockId = null;
    _draggingPayload = null;
    _pointerPosition = null;
    _activeSlotKey = null;
    _activeTarget = null;
    _sourceTotalHeight = null;
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
    );
    _setActive(result.key, result.target);
  }

  void _setActive(Object? key, BlockDropTarget? target) {
    if (key == _activeSlotKey && target == _activeTarget) return;
    _log.fine(
      '[block-drag] setActive: key=$key '
      'targetPrev=${target?.prevBlockId} targetNext=${target?.nextBlockId}',
    );
    _activeSlotKey = key;
    _activeTarget = target;
    notifyListeners();
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

/// Approximate intrinsic height of an [AgendaHeader] block-header row
/// (priority-tinted breadcrumb at xs typography + vertical padding).
/// Used as a baseline when the dropped block has no thread rows.
const double kBlockHeaderApproxHeight = 28;

/// Approximate height of one [ThreadWidget] row in the agenda (incl.
/// padding + separator). Block drop zones expand by
/// [kBlockHeaderApproxHeight] + this × visibleThreadCount so the gap
/// matches the dragged block's height.
const double kThreadRowApproxHeight = 56;

const Duration kBlockBoundaryAnimDuration = Duration(milliseconds: 150);

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
    super.key,
  });

  final BlockDropTarget target;

  /// Stable key the controller uses to identify this slot across
  /// rebuilds. The page passes a value derived from the surrounding
  /// row's stableKey + boundary position so reorders/scrolls don't
  /// churn registrations.
  final Object slotKey;

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

  bool get _isActive => _controller?.activeSlotKey == widget.slotKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = BlockDragScope.maybeOf(context);
    if (newController != _controller) {
      _controller?.removeListener(_onChanged);
      _controller?.unregisterSlot(widget.slotKey);
      _controller = newController;
      _controller?.addListener(_onChanged);
      _controller?.registerSlot(
        key: widget.slotKey,
        target: widget.target,
        contextProvider: () => context,
      );
    }
  }

  @override
  void didUpdateWidget(BlockDropZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slotKey != widget.slotKey ||
        oldWidget.target != widget.target) {
      _controller?.unregisterSlot(oldWidget.slotKey);
      _controller?.registerSlot(
        key: widget.slotKey,
        target: widget.target,
        contextProvider: () => context,
      );
    }
  }

  @override
  void dispose() {
    _clearHeldTimer?.cancel();
    _controller?.unregisterSlot(widget.slotKey);
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
    // Match the dragged block's *actual* footprint when expanding so the
    // total agenda height stays constant as the source collapses. Falls
    // back to the constant-based estimate if (for any reason) the
    // controller didn't capture a height.
    final expandedHeight = controller?.sourceTotalHeight ??
        (payload != null
            ? dropZoneHeightFor(payload)
            : kThreadRowApproxHeight);

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

    // Wrap the preview in [OverflowBox] so it always renders at its
    // natural intrinsic height regardless of the [AnimatedContainer]'s
    // animating height. Without this, mid-animation frames (where the
    // animating height is smaller than the preview) trip Flutter's
    // RenderFlex overflow check on the preview's [Column]. The
    // surrounding [ClipRect] still clips the visual to the box.
    //
    // Keying the [AnimatedContainer] on whether a drag is in progress
    // forces a remount on drag boundaries — otherwise an in-flight
    // collapse animation (started when the pointer left this slot
    // shortly before release) keeps running past `end()`, leaving the
    // slot at a partial height into the next drag and shifting
    // block-center activation thresholds so the user has to drag
    // farther on each subsequent attempt. Each drag session starts
    // with a fresh, fully-collapsed slot.
    return ClipRect(
      child: AnimatedContainer(
        key: ValueKey(payload != null),
        duration: kBlockBoundaryAnimDuration,
        curve: Curves.easeOut,
        height: isActive ? expandedHeight : kBlockBoundaryRestHeight,
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
