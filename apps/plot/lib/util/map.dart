extension MapFilterKeys<T1, T2> on Map<T1, T2> {
  Map<String, dynamic> filterKeys(Set<T1> keys) {
    return Map.fromIterable(
      keys,
      value: (key) => this[key],
    );
  }
}

Map<K, Map<L, V>> combineNestedMaps<K, L, V>(
    Map<K, Map<L, V>> mapA, Map<K, Map<L, V>> mapB) {
  Map<K, Map<L, V>> result = {};

  // Merge mapA
  for (var key in mapA.keys) {
    if (mapB.containsKey(key)) {
      // Both maps have the same key, merge inner maps
      result[key] = {}
        ..addAll(mapA[key]!)
        ..addAll(mapB[key]!);
    } else {
      // Only mapA has the key
      result[key] = Map<L, V>.from(mapA[key]!);
    }
  }

  // Add remaining keys from mapB
  for (var key in mapB.keys) {
    if (!result.containsKey(key)) {
      result[key] = Map<L, V>.from(mapB[key]!);
    }
  }

  return result;
}
