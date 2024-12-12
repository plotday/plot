import 'package:drift/drift.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:uuid/uuid.dart' as uuid;

bool __isType<T, Y>() => T == Y;
bool _isType<T, Y>() => __isType<T, Y>() || __isType<T, Y?>();

class CustomSerializer extends ValueSerializer {
  final ValueSerializer _inner;

  const CustomSerializer(
      [this._inner = const ValueSerializer.defaults(
          serializeDateTimeValuesAsString: true)]);

  @override
  T fromJson<T>(dynamic json) {
    if (json == null) {
      return null as T;
    }
    if (_isType<T, uuid.UuidValue>()) {
      return uuid.UuidValue.fromString(json as String) as T;
    }
    if (T == Duration) {
      return Duration(seconds: json as int) as T;
    }
    if (T == Date) {
      return Date.fromString(json as String) as T;
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

class ThemeColorConverter extends TypeConverter<ThemeColor, int> {
  const ThemeColorConverter();

  @override
  ThemeColor fromSql(int fromDb) {
    return ThemeColor(fromDb);
  }

  @override
  int toSql(ThemeColor value) {
    return value.index;
  }
}

class DateConverter extends TypeConverter<Date, String> {
  const DateConverter();

  @override
  Date fromSql(String fromDb) {
    return Date.fromString(fromDb);
  }

  @override
  String toSql(Date value) {
    return value.toString();
  }
}
