import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Result of [resolveDropOrderWithRepair]: the order for the dropped row
/// plus any (thread, newOrder) rewrites needed first so that order
/// actually sits between its visual neighbours.
typedef DropOrderResolution = ({
  Order dropOrder,
  List<(Thread, Order)> rewrites,
});

/// Compute the order for a row dropped into [bucket] (the target
/// section's rows in VISUAL order, with the dragged row excluded) at
/// [gapIndex] (between `bucket[gapIndex - 1]` and `bucket[gapIndex]`).
///
/// Normally this is a plain `Order.between` of the two neighbours. But
/// legacy data contains runs of IDENTICAL persisted orders — seeded
/// threads created with the same constant, and `state_order IS NULL`
/// rows that all share the [Order.lowerBound] sort fallback. Inside such
/// a run `Order.between(v, v)` returns `v + random`, which sorts after
/// the ENTIRE run (ties break by id), so the dropped row lands at the
/// bottom of the run instead of in the gap.
///
/// When the gap's neighbours tie, this repairs the run: the smaller side
/// of the run (relative to the gap) gets fresh strictly-ascending orders
/// squeezed between the run-bounding values, leaving room for the drop.
/// Visual order of the rewritten rows is preserved exactly — applying
/// the rewrites changes nothing on screen, it only makes the bucket's
/// persisted orders match what was already displayed.
DropOrderResolution resolveDropOrderWithRepair({
  required List<Thread> bucket,
  required int gapIndex,
}) {
  final prev = gapIndex > 0 ? bucket[gapIndex - 1] : null;
  final next = gapIndex < bucket.length ? bucket[gapIndex] : null;
  if (prev == null || next == null || prev.order.compareTo(next.order) < 0) {
    return (
      dropOrder: Order.between(prev?.order, next?.order),
      rewrites: const [],
    );
  }

  // The gap sits inside a run of identical orders (visual order within
  // the run is the id tie-break). Find the run's extent and bounds.
  final v = prev.order;
  var start = gapIndex - 1;
  while (start > 0 && bucket[start - 1].order.compareTo(v) >= 0) {
    start--;
  }
  var end = gapIndex;
  while (end + 1 < bucket.length && bucket[end + 1].order.compareTo(v) <= 0) {
    end++;
  }
  final lower = start > 0 ? bucket[start - 1].order : null;
  final upper = end + 1 < bucket.length ? bucket[end + 1].order : null;

  final beforeCount = gapIndex - start;
  final afterCount = end - gapIndex + 1;
  final rewrites = <(Thread, Order)>[];
  final Order dropOrder;
  if (beforeCount <= afterCount) {
    // Re-place the run's before-side strictly below the tied value,
    // ascending from the lower bound; the drop lands between the last
    // re-placed row and the (unchanged) after-side.
    var prevAssigned = lower;
    for (var i = start; i < gapIndex; i++) {
      final order = Order.between(prevAssigned, v);
      rewrites.add((bucket[i], order));
      prevAssigned = order;
    }
    dropOrder = Order.between(prevAssigned, v);
  } else {
    // Re-place the run's after-side strictly above the tied value,
    // assigned from the run's end toward the gap so each row stays
    // below the upper bound; the drop lands just below the re-placed
    // rows.
    var nextAssigned = upper;
    final reversed = <(Thread, Order)>[];
    for (var i = end; i >= gapIndex; i--) {
      final order = Order.between(v, nextAssigned);
      reversed.add((bucket[i], order));
      nextAssigned = order;
    }
    rewrites.addAll(reversed.reversed);
    dropOrder = Order.between(v, nextAssigned);
  }
  return (dropOrder: dropOrder, rewrites: rewrites);
}

/// The thread rows of [section] — for Scheduled, the [date] bucket — in
/// visual order, excluding [exclude] (the dragged row). Rows are
/// classified by the marker-encoded section headers, mirroring the feed
/// builder's layout.
List<Thread> feedSectionBucket(
  List<AgendaItem> items, {
  required ActivitySection section,
  Date? date,
  ThreadId? exclude,
}) {
  ActivitySection? current;
  Date? currentDate;
  final rows = <Thread>[];
  for (final item in items) {
    item.when<void>(
      header: (h) {
        final marker = h.text == null
            ? null
            : ActivitySectionMarker.tryDecode(h.text!);
        if (marker != null) {
          current = marker.section;
          currentDate = h.date;
        }
      },
      activity: (a) {
        if (current != section) return;
        if (section == ActivitySection.scheduled &&
            date != null &&
            currentDate != date) {
          return;
        }
        if (a.thread.id == exclude) return;
        rows.add(a.thread);
      },
    );
  }
  return rows;
}

/// The insertion index in [bucket] for a feed drop whose slot named
/// [prevId]/[nextId] as the flanking rows. Slots at cluster/section
/// boundaries can name a neighbour that isn't part of the bucket (or
/// none at all); resolution falls back from next → prev → top.
int feedDropGapIndex(
  List<Thread> bucket, {
  required ThreadId? prevId,
  required ThreadId? nextId,
}) {
  if (nextId != null) {
    final i = bucket.indexWhere((t) => t.id == nextId);
    if (i != -1) return i;
  }
  if (prevId != null) {
    final i = bucket.indexWhere((t) => t.id == prevId);
    if (i != -1) return i + 1;
  }
  return 0;
}
