import 'package:drift/drift.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';

class UuidConverter extends TypeConverter<Uuid, Uint8List> {
  const UuidConverter();

  @override
  Uuid fromSql(Uint8List fromDb) {
    return Uuid.fromBytes(fromDb);
  }

  @override
  Uint8List toSql(Uuid value) {
    return value.toBytes();
  }
}

class PathConverter extends TypeConverter<Path, String> {
  const PathConverter();

  @override
  Path fromSql(String fromDb) {
    return Path(fromDb);
  }

  @override
  String toSql(Path value) {
    return value.value;
  }
}

class OrderConverter extends TypeConverter<Order, double> {
  const OrderConverter();

  @override
  Order fromSql(double fromDb) {
    return Order(fromDb);
  }

  @override
  double toSql(Order value) {
    return value.value;
  }
}

class DurationConverter extends TypeConverter<Duration, int> {
  const DurationConverter();

  @override
  Duration fromSql(int fromDb) {
    return Duration(seconds: fromDb);
  }

  @override
  int toSql(Duration value) {
    return value.inSeconds;
  }
}
