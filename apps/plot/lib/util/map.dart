extension MapFilterKeys<T1, T2> on Map<T1, T2> {
  Map<String, dynamic> filterKeys(Set<T1> keys) {
    return Map.fromIterable(
      keys,
      value: (key) => this[key],
    );
  }
}

Map<K, Map<L, V>> combineNestedMaps<K, L, V>(List<Map<K, Map<L, V>>> maps) {
  if (maps.isEmpty) {
    return {};
  }

  Map<K, Map<L, V>> result = {};

  for (var map in maps) {
    for (var key in map.keys) {
      if (result.containsKey(key)) {
        // If the key exists, merge the inner maps
        result[key] ??= {};
        result[key]!.addAll(map[key]!);
      } else {
        // If the key doesn't exist, add the entire inner map
        result[key] = Map<L, V>.from(map[key]!);
      }
    }
  }

  return result;
}
