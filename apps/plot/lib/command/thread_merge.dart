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

/// Returns the larger of two importance values.
int mergeImportanceMax(int a, int b) => a >= b ? a : b;
