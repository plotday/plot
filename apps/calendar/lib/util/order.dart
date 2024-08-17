import 'package:equatable/equatable.dart';

class Order extends Equatable implements Comparable<Order> {
  static double _last() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() * 10;
  static double _first() =>
      (10000000000000 - DateTime.now().millisecondsSinceEpoch).toDouble();
  static double _firstPinned() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() * -10;
  static double _lastPinned() =>
      (10000000000000 - DateTime.now().millisecondsSinceEpoch).toDouble() * -1;

  static double _between(Order? after, Order? before) {
    var a = after?._value;
    var b = before?._value;
    if (a == null) {
      if (b == null) return _last();
      return b > 0 ? _first() : _firstPinned();
    } else if (b == null) {
      return a > 0 ? _last() : _lastPinned();
    }
    return a + (b - a) / 2;
  }

  Order() : _value = _last();
  Order.first() : _value = _first();
  Order.firstPinned() : _value = _firstPinned();
  Order.pinned() : _value = _lastPinned();

  Order.between(Order? after, Order? before) : _value = _between(after, before);

  const Order.fromDouble(this._value);
  Order.fromNumber(dynamic value)
      : _value = value is int
            ? value.toDouble()
            : value is double
                ? value
                : 0 {
    if (_value == 0) throw ArgumentError('Order must be a number');
  }

  @override
  int compareTo(Order other) {
    return _value.compareTo(other._value);
  }

  bool get pinned => _value < 0;
  double toDouble() => _value;

  final double _value;

  @override
  List<Object?> get props => [_value];
}
