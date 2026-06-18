import 'package:plot/store/store.dart';

/// Result of splitting the Doing section into its two ordered groups.
typedef DoingSplit = ({List<Thread> active, List<Thread> unreadCluster});

/// Splits Doing-eligible threads into the active-to-do list (sorted by
/// `order`, read and unread intermixed) and the bottom non-active unread
/// cluster (urgent DESC, importance DESC, order ASC, id ASC).
///
/// A thread is "active" iff [Thread.isActiveThread]; everything else passed
/// in is treated as a bottom-cluster row (the caller only passes non-active
/// unread threads + the sticky-pinned open thread here).
DoingSplit splitDoingSection(Iterable<Thread> doingEligible) {
  final active = <Thread>[];
  final unreadCluster = <Thread>[];
  for (final t in doingEligible) {
    (t.isActiveThread ? active : unreadCluster).add(t);
  }

  active.sort((a, b) {
    final ord = a.order.compareTo(b.order);
    if (ord != 0) return ord;
    return a.id.toString().compareTo(b.id.toString());
  });

  unreadCluster.sort((a, b) {
    if (a.urgent != b.urgent) return a.urgent ? -1 : 1;
    final imp = b.importance.compareTo(a.importance);
    if (imp != 0) return imp;
    final ord = a.order.compareTo(b.order);
    if (ord != 0) return ord;
    return a.id.toString().compareTo(b.id.toString());
  });

  return (active: active, unreadCluster: unreadCluster);
}
