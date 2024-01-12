extension MapFilterKeys<T1, T2> on Map<T1, T2> {
  Map<String, dynamic> filterKeys(Set<T1> keys) {
    return Map.fromIterable(
      keys,
      value: (key) => this[key],
    );
  }
}
