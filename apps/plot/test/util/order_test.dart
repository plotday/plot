import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/order.dart';

void main() {
  group('Order.last', () {
    test('sorts after Order.first and between-derived orders', () async {
      final top = Order.first();
      final afterTop = Order.between(top, null);
      // Orders assigned in the same millisecond tie-break randomly (the
      // documented caveat), so put the bottom placement in a strictly
      // later millisecond — matching real usage, where "earlier" means an
      // earlier wall clock.
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final bottom = Order.last();
      // Order.first is a negative timestamp (top of an ASC list);
      // Order.last is a positive timestamp, strictly after anything
      // assigned earlier.
      expect(bottom.compareTo(top), greaterThan(0));
      expect(bottom.compareTo(afterTop), greaterThan(0));
      expect(bottom.value, greaterThan(0));
    });

    test('Order.between(prev, null) extends a bottom-append chain', () {
      final first = Order.last();
      final second = Order.between(first, null);
      final third = Order.between(second, null);
      expect(second.compareTo(first), greaterThan(0));
      expect(third.compareTo(second), greaterThan(0));
    });
  });
}
