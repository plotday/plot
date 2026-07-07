import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Identity key for feed items used by the move diff and ghost splicing.
/// Section headers key on their marker-encoded text, day headers on their
/// date, thread rows on thread id (+ association disambiguator) — matching
/// the page's widget-key identities.
String feedItemKey(AgendaItem item) => item.when(
  header: (h) => h.date != null ? 'h_date_${h.date}' : 'h_text_${h.text}',
  // The pinned "Event Agenda" copy and the Scheduled copy of one event are
  // both unassociated, so `_pinned` is what keeps their identities distinct —
  // without it the two sibling rows share a key and the second one's state
  // (its RSVP chip) collides with the first's.
  activity: (a) =>
      't_${a.thread.id}'
      '${a.thread.occurrence != null ? '_${a.thread.occurrence}' : ''}'
      '${a.thread.isLinkScheduleInstance ? '_link' : ''}'
      '${a.isAssociated ? '_assoc_${a.associationParentId ?? ''}' : ''}'
      '${a.pinned ? '_pinned' : ''}',
);

/// A collapsing ghost: [item]'s pre-move row, rendered directly after the
/// stable item with key [anchorKey] (null = at the very top of the list).
class FeedGhost {
  const FeedGhost({required this.item, required this.anchorKey});
  final AgendaItem item;
  final String? anchorKey;
}

/// The animated difference between two sectioned-feed item lists.
/// [ghosts] collapse (height 1 → 0) at the source; rows/headers whose keys
/// are in [expandingKeys] expand (0 → 1) at the destination. Driven by one
/// shared animation so total height between source and destination stays
/// constant — nothing outside that range shifts.
class FeedMoveDiff {
  const FeedMoveDiff({required this.ghosts, required this.expandingKeys});

  static const empty = FeedMoveDiff(ghosts: [], expandingKeys: {});

  final List<FeedGhost> ghosts;
  final Set<String> expandingKeys;

  bool get isEmpty => ghosts.isEmpty && expandingKeys.isEmpty;
}

/// Diff [oldItems] → [newItems] for a state-change move animation.
///
/// [movedIds] are the threads whose state the user explicitly changed;
/// their rows are treated as removed-from-old + added-to-new even when
/// present in both lists. Every other item present in both lists is
/// "stable". When stable items don't preserve their relative order — or
/// the change is too large to be a state-change move ([maxAnimatedItems])
/// — the diff is ambiguous and [FeedMoveDiff.empty] is returned so the
/// caller snaps instead of animating.
FeedMoveDiff computeFeedMoveDiff(
  List<AgendaItem> oldItems,
  List<AgendaItem> newItems,
  Set<ThreadId> movedIds, {
  int maxAnimatedItems = 12,
}) {
  bool isMoved(AgendaItem item) =>
      item is AgendaThreadItem && movedIds.contains(item.thread.id);

  final oldKeys = [for (final i in oldItems) feedItemKey(i)];
  final newKeys = [for (final i in newItems) feedItemKey(i)];

  // Nothing repositioned (e.g. an in-place field edit) — no animation.
  if (oldKeys.length == newKeys.length) {
    var same = true;
    for (var i = 0; i < oldKeys.length; i++) {
      if (oldKeys[i] != newKeys[i]) {
        same = false;
        break;
      }
    }
    if (same) return FeedMoveDiff.empty;
  }

  final oldKeySet = oldKeys.toSet();
  final newKeySet = newKeys.toSet();
  // Duplicate keys make identity ambiguous — snap.
  if (oldKeySet.length != oldKeys.length ||
      newKeySet.length != newKeys.length) {
    return FeedMoveDiff.empty;
  }

  // Ghosts: removed items plus the moved rows' old positions, each
  // anchored to the nearest stable item above it in the old list.
  final ghosts = <FeedGhost>[];
  final stableOld = <String>[];
  String? anchor;
  for (var i = 0; i < oldItems.length; i++) {
    if (!isMoved(oldItems[i]) && newKeySet.contains(oldKeys[i])) {
      anchor = oldKeys[i];
      stableOld.add(oldKeys[i]);
    } else {
      ghosts.add(FeedGhost(item: oldItems[i], anchorKey: anchor));
    }
  }

  // Expanders: added items plus the moved rows' new positions.
  final expanding = <String>{};
  final stableNew = <String>[];
  for (var i = 0; i < newItems.length; i++) {
    if (isMoved(newItems[i]) || !oldKeySet.contains(newKeys[i])) {
      expanding.add(newKeys[i]);
    } else {
      stableNew.add(newKeys[i]);
    }
  }

  if (ghosts.isEmpty && expanding.isEmpty) return FeedMoveDiff.empty;
  if (ghosts.length + expanding.length > maxAnimatedItems) {
    return FeedMoveDiff.empty;
  }

  // The size-transition invariant requires stable rows to keep their
  // relative order; bail out (snap) when they don't.
  if (stableOld.length != stableNew.length) return FeedMoveDiff.empty;
  for (var i = 0; i < stableOld.length; i++) {
    if (stableOld[i] != stableNew[i]) return FeedMoveDiff.empty;
  }

  return FeedMoveDiff(
    ghosts: List.unmodifiable(ghosts),
    expandingKeys: Set.unmodifiable(expanding),
  );
}
