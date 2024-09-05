import 'package:drift/drift.dart';

import 'package:plot/util/order.dart';

class OrderConverter extends TypeConverter<Order, double> {
  const OrderConverter();

  @override
  Order fromSql(double fromDb) {
    return Order.fromDouble(fromDb);
  }

  @override
  double toSql(Order value) {
    return value.toDouble();
  }
}

class MinutesConverter extends TypeConverter<Duration, int> {
  const MinutesConverter();

  @override
  Duration fromSql(int fromDb) {
    return Duration(minutes: fromDb);
  }

  @override
  int toSql(Duration value) {
    return value.inMinutes;
  }
}
