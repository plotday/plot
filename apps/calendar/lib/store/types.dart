import 'package:drift/drift.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:uuid/uuid.dart' as uuid;

class CustomSerializer extends ValueSerializer {
  final ValueSerializer _inner;

  const CustomSerializer(
      [this._inner = const ValueSerializer.defaults(
          serializeDateTimeValuesAsString: true)]);

  @override
  T fromJson<T>(dynamic json) {
    if (T == uuid.UuidValue) {
      return uuid.UuidValue.fromString(json as String) as T;
    }
    if (T == Duration) {
      return Duration(seconds: json as int) as T;
    }

    return _inner.fromJson<T>(json);
  }

  @override
  dynamic toJson<T>(T value) {
    if (value is uuid.UuidValue) {
      return (value as uuid.UuidValue).toFormattedString();
    }
    if (value is Duration) {
      return (value as Duration).inSeconds;
    }

    return _inner.toJson(value);
  }
}

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
