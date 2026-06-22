import 'package:logging/logging.dart';

import 'package:plot/store/store.dart';

// Per-source-focus move affinity: persisted to `user_settings.move_affinity`
// (jsonb via Drift) and synced across devices. The top-level helpers below drive
// both the Move modal's ordering and the write-back when a move completes.
final Logger _log = Logger('plot.move_affinity');

/// Cross-device per-source-focus move affinity. Wraps the JSON map stored on
/// `user_settings.move_affinity`, shaped
/// `{ "<sourceFocusId>": { "<destFocusId>": <epochMillis> } }`. Immutable;
/// [recordMove] returns a new instance. Drives the Move modal's recency tier:
/// destinations recently moved into *from the current focus*, newest first.
class MoveAffinity {
  MoveAffinity._(this._bySource);

  /// Max destinations retained per source focus (older ones are dropped on
  /// write — ordering relevance falls off quickly).
  static const int maxPerSource = 8;

  // { source : { dest : epochMillis } }, owned/immutable.
  final Map<Uuid, Map<Uuid, int>> _bySource;

  /// Tolerant parse: null / empty / malformed entries yield an empty map and
  /// never throw (the Move modal must order even with garbage on disk).
  factory MoveAffinity.fromMap(Map<String, dynamic>? raw) {
    final parsed = <Uuid, Map<Uuid, int>>{};
    if (raw != null) {
      for (final entry in raw.entries) {
        final dests = entry.value;
        if (dests is! Map) continue;
        final Uuid source;
        try {
          source = Uuid.fromString(entry.key);
        } catch (_) {
          continue;
        }
        final destMap = <Uuid, int>{};
        for (final d in dests.entries) {
          final at = d.value;
          if (at is! num) continue;
          try {
            destMap[Uuid.fromString(d.key as String)] = at.toInt();
          } catch (_) {
            // Skip unparseable dest id.
          }
        }
        if (destMap.isNotEmpty) parsed[source] = destMap;
      }
    }
    return MoveAffinity._(parsed);
  }

  /// Destinations recently moved into from [source], newest first, capped at
  /// [maxPerSource]. The cap also applies on write, but a cross-device merge
  /// can transiently leave more than [maxPerSource] cells (the server unions
  /// rather than re-capping), so guard the read too.
  List<Uuid> destsFor(Uuid source) {
    final dests = _bySource[source];
    if (dests == null) return const [];
    final entries = dests.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // newest (largest ms) first
    return [for (final e in entries.take(maxPerSource)) e.key];
  }

  /// A new instance recording a move from [source] to [dest] at [at], with the
  /// source's destination list re-capped to [maxPerSource] newest entries.
  MoveAffinity recordMove(Uuid source, Uuid dest, DateTime at) {
    final next = <Uuid, Map<Uuid, int>>{
      for (final e in _bySource.entries) e.key: Map<Uuid, int>.from(e.value),
    };
    final dests = next.putIfAbsent(source, () => <Uuid, int>{});
    dests[dest] = at.millisecondsSinceEpoch;
    if (dests.length > maxPerSource) {
      final kept = dests.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      next[source] = {
        for (final e in kept.take(maxPerSource)) e.key: e.value,
      };
    }
    return MoveAffinity._(next);
  }

  /// Serialize back to the `user_settings.move_affinity` JSON shape.
  Map<String, dynamic> toMap() => {
        for (final s in _bySource.entries)
          s.key.toString(): {
            for (final d in s.value.entries) d.key.toString(): d.value,
          },
      };
}

/// The source focus shared by an entire bulk selection, or null when the
/// selection is empty or spans more than one source focus. Mirrors
/// [sharedRoleId]: the per-source recency tier only applies to a bulk move
/// when every selected thread sits in the same source focus.
Uuid? sharedSourceFocusId(Iterable<Uuid> sourceIds) {
  final distinct = sourceIds.toSet();
  return distinct.length == 1 ? distinct.first : null;
}

/// Distinct source focuses from a bulk selection, each paired with the single
/// [dest]. Preserves first-seen order. Used to coalesce a bulk move so each
/// source records one affinity write rather than one per thread.
List<(Uuid source, Uuid dest)> movePairs(Iterable<Uuid> sources, Uuid dest) {
  final seen = <String>{};
  final pairs = <(Uuid, Uuid)>[];
  for (final s in sources) {
    if (seen.add(s.toString())) pairs.add((s, dest));
  }
  return pairs;
}

/// The user's persisted move affinity from the local `user_settings` row.
/// Offline-safe: a local Drift read, empty when the row/value is absent.
Future<MoveAffinity> loadMoveAffinity() async {
  final row = await UserSettingsEntity.get();
  return MoveAffinity.fromMap(row?.moveAffinity);
}

/// Record [pairs] (source → dest) into the persisted affinity, local-first.
/// `UserSettingsEntity.save` fire-and-forgets the sync push, so this is
/// offline-safe; any failure is logged, never thrown (callers fire-and-forget).
Future<void> recordMoveAffinity(List<(Uuid, Uuid)> pairs) async {
  if (pairs.isEmpty) return;
  try {
    var affinity = await loadMoveAffinity();
    final now = DateTime.now();
    for (final (source, dest) in pairs) {
      affinity = affinity.recordMove(source, dest, now);
    }
    await UserSettingsEntity.save(
      UserSettingsCompanion(moveAffinity: Value(affinity.toMap())),
    );
  } catch (e, st) {
    // Expected when offline / racing sign-out; the move itself already landed.
    _log.warning('Error recording move affinity', e, st);
  }
}

/// Order [focuses] for the Move modal: per-source recency (destinations moved
/// into from [sourceId]) → same role ([currentRoleId]) → base order. Reads the
/// persisted affinity locally (offline-safe).
Future<List<Priority>> orderedMoveTargets({
  required List<Priority> focuses,
  required Uuid? sourceId,
  required Uuid? currentRoleId,
}) async {
  final affinity = await loadMoveAffinity();
  return orderMoveTargets(
    focuses: focuses,
    recentMoves: sourceId == null ? const [] : affinity.destsFor(sourceId),
    currentRoleId: currentRoleId,
  );
}

/// Reorders [focuses] for the Move modal into three stable tiers:
///
/// Tier 1: destinations recently moved into from the current focus
///    ([recentMoves]), newest first;
/// Tier 2: focuses sharing [currentRoleId] (the moved thread's current role),
///    in incoming order;
/// Tier 3: everything else, in incoming order.
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
