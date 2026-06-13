import 'dart:math';

import 'package:drift/drift.dart';

extension type Order._(double value) {
  static final _random = Random();
  static const lowerBound = -10_000_536_000_000.0;
  // `_step` is the fractional offset used by open-ended drops to guarantee
  // strict monotonicity vs an existing neighbour. `_random.nextDouble()` is
  // in [0, 1) so a 1.0 step is always strictly larger than any random tail
  // already attached to a neighbour's order.
  static const double _step = 1.0;
  static double _last() =>
      -DateTime.now().millisecondsSinceEpoch.toDouble() + _random.nextDouble();
  static double _first() =>
      DateTime.now().millisecondsSinceEpoch.toDouble() + _random.nextDouble();
  static double _between(Order? after, Order? before) {
    var a = after?.value;
    var b = before?.value;
    if (a == null && b == null) return _first();
    // One-sided cases: produce a value that is *strictly* on the correct
    // side of the known neighbour. Returning `_first()` / `_last()`
    // unconditionally can land on the wrong side when neighbours have
    // orders close to the current wall-clock timestamp (drop-at-end
    // landing above an item whose order was assigned moments earlier).
    if (a == null) {
      // Result must be < b. Pick min(_last(), b - step) and add a random
      // fractional offset (when falling back to the bound) so successive
      // drops don't collide.
      final fresh = _last();
      final bound = b! - _step;
      return fresh < bound ? fresh : bound - _random.nextDouble();
    }
    if (b == null) {
      // Result must be > a. Pick max(_first(), a + step) and add a random
      // fractional offset (when falling back to the bound) so successive
      // drops don't collide.
      final fresh = _first();
      final bound = a + _step;
      return fresh > bound ? fresh : bound + _random.nextDouble();
    }
    if (a == b) return a + _random.nextDouble();
    return (a + b) / 2;
  }

  const Order(this.value);

  /// Creates an order value that places the new item at the visual TOP
  /// of its list (smallest value, sorted ASC). The list is conventionally
  /// rendered top-to-bottom in ascending order, so a negative-timestamp
  /// value sorts before any existing positive-timestamp value, and newer
  /// `first()` calls produce ever-smaller values (more negative
  /// `millisecondsSinceEpoch`).
  Order.first() : this(_last());

  /// Creates an order value that places the new item at the visual BOTTOM
  /// of its list (largest value, sorted ASC). A positive now-timestamp is
  /// strictly larger than every order assigned earlier — [Order.first]'s
  /// negative values, [Order.between] midpoints, and one-sided bounds all
  /// derive from an earlier wall clock — so no neighbour scan is needed.
  /// NOTE: two `last()` calls in the same millisecond tie-break randomly;
  /// for bulk appends chain `Order.between(prev, null)` after the first.
  Order.last() : this(_first());

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

class OrderConverter extends TypeConverter<Order, double>
    with JsonTypeConverter2<Order, double, double> {
  const OrderConverter();

  @override
  Order fromSql(double fromDb) {
    return Order(fromDb);
  }

  @override
  double toSql(Order value) {
    return value.value;
  }

  @override
  Order fromJson(double json) {
    return Order(json);
  }

  @override
  double toJson(Order value) {
    return value.value;
  }
}
