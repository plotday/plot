import 'package:plot/store/store.dart';

/// Returns the union of [target] and [source] preserving target's order,
/// then appending any ids from source not already present.
///
/// Returns null if the union is empty.
List<Uuid>? mergeAudienceUnion(List<Uuid>? target, List<Uuid>? source) {
  final result = <Uuid>[...?target];
  final seen = result.toSet();
  if (source != null) {
    for (final id in source) {
      if (seen.add(id)) result.add(id);
    }
  }
  return result.isEmpty ? null : result;
}

/// Returns target with ids removed that only [source] contributed —
/// i.e. ids in source that no [otherActiveSources] entry carries.
///
/// Lossy in the rare case where a contact was in both the pre-merge
/// target and source: that overlap is dropped.
///
/// Returns null if the result is empty.
List<Uuid>? splitAudienceSubtract({
  required List<Uuid>? target,
  required List<Uuid>? source,
  required List<List<Uuid>?> otherActiveSources,
}) {
  if (target == null || target.isEmpty) return null;
  if (source == null || source.isEmpty) {
    return List<Uuid>.from(target);
  }
  final keptByOthers = <Uuid>{};
  for (final other in otherActiveSources) {
    if (other != null) keptByOthers.addAll(other);
  }
  final remove = source.where((id) => !keptByOthers.contains(id)).toSet();
  final result = target.where((id) => !remove.contains(id)).toList();
  return result.isEmpty ? null : result;
}

/// Lower rank = more urgent. Mirrors notification_service._urgencyRank
/// so urgency rules stay consistent across merge and notification paths.
int _urgencyRank(String? urgency) => switch (urgency) {
      'interrupt' => 0,
      'inform-requests' => 1,
      'inform-updates' => 2,
      'passive' => 3,
      _ => 4,
    };

/// Returns the more urgent of [a] and [b]. Null/unknown values are least
/// urgent and lose to any recognized urgency.
String? mergeUrgencyMostUrgent(String? a, String? b) {
  final ra = _urgencyRank(a);
  final rb = _urgencyRank(b);
  if (ra <= rb) return ra == 4 ? null : a;
  return rb == 4 ? null : b;
}

/// Returns the larger of two importance values. Defined here so merge code
/// reads symmetrically with the urgency helper.
int mergeImportanceMax(int a, int b) => a >= b ? a : b;
