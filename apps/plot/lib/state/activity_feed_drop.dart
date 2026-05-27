/// Identity of an order-sort sub-cluster within the unified feed's
/// Doing section.
///
/// The Doing section's unread cluster is sorted urgent DESC, importance
/// DESC, order ASC — so threads only share an order space with siblings
/// of the same `(urgent, importance)`. The read cluster sorts purely by
/// order ASC and is treated as one cluster. Cross-cluster drops have to
/// either change the dragged thread's bucket (urgent / importance / read
/// flag) or land it at the boundary slot of a same-cluster neighbour;
/// they never share an order computation with the opposing cluster.
class DoingCluster {
  const DoingCluster.read()
      : unread = false,
        urgent = false,
        importance = 0;
  const DoingCluster.unread({required this.urgent, required this.importance})
      : unread = true;

  final bool unread;
  // urgent / importance are only meaningful in the unread cluster.
  final bool urgent;
  final int importance;

  @override
  bool operator ==(Object other) =>
      other is DoingCluster &&
      other.unread == unread &&
      (!unread ||
          (other.urgent == urgent && other.importance == importance));

  @override
  int get hashCode => unread ? Object.hash(true, urgent, importance) : 0;

  @override
  String toString() => unread
      ? 'unread(urgent=$urgent imp=$importance)'
      : 'read';
}

/// Result of resolving a Doing-section drop: which cluster the dragged
/// row should land in, and which neighbours should bound the resulting
/// `Order.between` call. A `false` `usePrev` / `useNext` flag means the
/// corresponding neighbour belongs to a different cluster and must not
/// be used as an order bound (its order lives in an independent space).
class DoingDropResolution {
  const DoingDropResolution({
    required this.destination,
    required this.usePrev,
    required this.useNext,
  });

  final DoingCluster destination;
  final bool usePrev;
  final bool useNext;
}

/// Pick the destination cluster and order bounds for a drop into the
/// unified feed's Doing section.
///
/// Rules:
///   * Both neighbours present and in different clusters (boundary
///     slot): if the dragged thread already belongs to one of those
///     clusters, preserve it. Dropping a read row at the top of reads
///     stays read; dropping an imp=75 unread row between an imp=100
///     unread and an imp=75 unread stays imp=75. If the dragged row
///     matches neither side, absorb the prev neighbour's cluster — the
///     drop is an explicit cross-bucket move, with prev winning as the
///     anchor.
///   * Both neighbours present and same cluster: that cluster wins
///     regardless of the dragged row's current bucket. A mid-cluster
///     drop is the user moving the thread INTO that bucket.
///   * Only one neighbour: it wins.
///   * No neighbours (empty Doing): drop becomes a read-cluster drop
///     at the top — there's no unread cluster to join.
///
/// Order bounds (`usePrev` / `useNext`) are filtered to the chosen
/// cluster so cross-cluster orders don't bleed into the computation.
DoingDropResolution resolveDoingDrop({
  required DoingCluster? prev,
  required DoingCluster? next,
  required DoingCluster dragged,
}) {
  DoingCluster destination;
  if (prev != null && next != null && prev != next) {
    if (dragged == prev || dragged == next) {
      destination = dragged;
    } else {
      destination = prev;
    }
  } else if (prev != null) {
    destination = prev;
  } else if (next != null) {
    destination = next;
  } else {
    destination = const DoingCluster.read();
  }
  return DoingDropResolution(
    destination: destination,
    usePrev: prev == destination,
    useNext: next == destination,
  );
}
