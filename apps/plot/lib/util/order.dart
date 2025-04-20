extension type Order._(double value) {
  static const lowerBound = -10_000_536_000_000;
  static double _last() => -DateTime.now().millisecondsSinceEpoch.toDouble();
  static double _first() => DateTime.now().millisecondsSinceEpoch.toDouble();
  static double _between(Order? after, Order? before) {
    var a = after?.value;
    var b = before?.value;
    if (a == null) {
      return b == null ? _first() : _last();
    } else if (b == null) {
      return _first();
    }
    return (a + b) / 2;
  }

  const Order(this.value);
  Order.first() : this(_first());
  Order.between(Order? after, Order? before) : this(_between(after, before));
  Order.fromNumber(dynamic number)
    : this(
        number is int
            ? number.toDouble()
            : number is double
            ? number
            : throw ArgumentError('Order must be a number'),
      );

  int compareTo(Order other) => value.compareTo(other.value);
}
