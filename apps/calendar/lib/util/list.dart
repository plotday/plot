extension ReplaceListItem<T> on List<T> {
  // Replace the given item in the list, or append it if it's not already in the
  // list.
  List<T> replace(T item, bool Function(T, T) match) {
    bool found = false;
    final updatedList = map((i) {
      if (match(i, item)) {
        found = true;
        return item;
      } else {
        return i;
      }
    }).toList();
    if (!found) {
      updatedList.add(item);
    }
    return updatedList;
  }
}
