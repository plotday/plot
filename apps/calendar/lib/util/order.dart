extension type Order._(double value) {
  static double _last() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() * 10;
  static double _first() =>
      (10000000000000 - DateTime.now().millisecondsSinceEpoch).toDouble();
  static double _firstPinned() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() * -10;
  static double _lastPinned() =>
      (10000000000000 - DateTime.now().millisecondsSinceEpoch).toDouble() * -1;
  static double _between(Order? after, Order? before) {
    var a = after?.value;
    var b = before?.value;
    if (a == null) {
      if (b == null) return _last();
      return b > 0 ? _first() : _firstPinned();
    } else if (b == null) {
      return a > 0 ? _last() : _lastPinned();
    }
    return a + (b - a) / 2;
  }

  const Order(this.value);
  Order.last() : this(_last());
  Order.first() : this(_first());
  Order.firstPinned() : this(_firstPinned());
  Order.pinned() : this(_lastPinned());
  Order.between(Order? after, Order? before) : this(_between(after, before));
  Order.fromNumber(dynamic number)
      : this(number is int
            ? number.toDouble()
            : number is double
                ? number
                : throw ArgumentError('Order must be a number'));

  bool get pinned => value < 0;

  int compareTo(Order other) => value.compareTo(other.value);
}
