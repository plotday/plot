import 'package:plot/store/store.dart';

/// Session-scoped, in-memory record of the focuses a thread was most recently
/// moved into, newest first. Used by the Move modal to float just-used move
/// destinations to the top during a triage burst.
///
/// Intentionally not persisted and not a Bloc: it is a lightweight cross-cutting
/// cache shared between the move command (which records) and the Move modal
/// (which reads). A fresh app run starts empty, so between sessions role
/// affinity leads.
class MoveRecency {
  MoveRecency._();

  /// The app-wide instance.
  static final MoveRecency instance = MoveRecency._();

  final List<Uuid> _recent = []; // newest first, deduped

  /// Most-recently moved-into focus ids, newest first.
  List<Uuid> get recent => List.unmodifiable(_recent);

  /// Record a move destination: move it to the front, deduped.
  void record(Uuid focusId) {
    _recent
      ..remove(focusId)
      ..insert(0, focusId);
  }

  /// Clears the recency list (sign-out / store reset / test isolation).
  void clear() => _recent.clear();
}

/// Reorders [focuses] for the Move modal into three stable tiers:
///
/// Tier 0: focuses recently moved-into this session ([recentMoves]), newest first;
/// Tier 1: focuses sharing [currentRoleId] (the moved thread's current role), in
///    incoming order;
/// Tier 2: everything else, in incoming order.
///
/// [focuses] arrives in the desired Tier-3 base order (visit-recency, then
/// alphabetical). The sort is stable: ties fall back to the incoming index, so
/// the base order survives within tiers 2 and 3, while tier 1 is driven by MRU
/// position. [currentRoleId] may be null (the model types `roleId` nullable);
/// when null, the same-role tier is empty.
List<Priority> orderMoveTargets({
  required List<Priority> focuses,
  required List<Uuid> recentMoves,
  required Uuid? currentRoleId,
}) {
  int tierOf(Priority p) {
    if (recentMoves.contains(p.id)) return 0;
    if (currentRoleId != null && p.roleId == currentRoleId) return 1;
    return 2;
  }

  final indexed = <(int, Priority)>[
    for (var i = 0; i < focuses.length; i++) (i, focuses[i]),
  ];
  indexed.sort((a, b) {
    final ta = tierOf(a.$2);
    final tb = tierOf(b.$2);
    if (ta != tb) return ta.compareTo(tb);
    if (ta == 0) {
      // Both recent: smaller MRU index = more recent = earlier.
      return recentMoves.indexOf(a.$2.id).compareTo(recentMoves.indexOf(b.$2.id));
    }
    return a.$1.compareTo(b.$1); // preserve incoming order
  });
  return [for (final e in indexed) e.$2];
}

/// The role shared by an entire bulk selection, or null when the selection
/// spans more than one role (or has no role at all). Used by the bulk Move
/// modal to decide whether same-role affinity is meaningful: it only is when
/// every selected thread sits in the same role. A single distinct null (every
/// thread role-less) also yields null — there is no role to favor.
Uuid? sharedRoleId(Iterable<Uuid?> roleIds) {
  final distinct = roleIds.toSet();
  return distinct.length == 1 ? distinct.first : null;
}
