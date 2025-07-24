import 'package:collection/collection.dart';

extension ReplaceListItem<T> on List<T> {
  // Replace the given item in the list, or append it if it's not already in the
  // list.
  List<T> replace(T item, bool Function(T, T) match) {
    final pos = indexWhere((i) => match(i, item));
    if (pos != -1) {
      this[pos] = item;
    } else {
      add(item);
    }
    return this;
  }

  // Add the item in sorted order, removing an existing match.
  List<T> replaceSorted(T item, bool Function(T, T) match) {
    removeWhere((n) => match(n, item));
    final newPos = lowerBound(this, item);
    insert(newPos, item);
    return this;
  }
}

extension PartitionList<T> on List<T> {
  (List<T>, List<T>) partition(bool Function(T) predicate) {
    var trueList = <T>[];
    var falseList = <T>[];

    for (var item in this) {
      (predicate(item) ? trueList : falseList).add(item);
    }

    return (trueList, falseList);
  }
}
