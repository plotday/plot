import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:change_case/change_case.dart';

import 'enums.dart';

enum AuthProvider { google, microsoft, slack, apple, github, discord, other }

class EnumConverter<T extends Enum> extends TypeConverter<T, String>
    with JsonTypeConverter2<T, String, String> {
  const EnumConverter();

  @override
  T fromSql(String fromDb) {
    return fromDb.toEnum<T>();
  }

  @override
  String toSql(T value) => (value as Enum).name.toSnakeCase();

  @override
  T fromJson(String json) {
    return fromSql(json);
  }

  @override
  String toJson(T value) {
    return toSql(value);
  }
}


/// This class overrides JSON serialization for particular types.
/// PREFER using JsonTypeConverter2 mixin on individual TypeConverters for field-specific conversions.
/// CustomSerializer should only be used to override default conversions for types that don't have dedicated converters.
class CustomSerializer extends ValueSerializer {
  final ValueSerializer _inner;

  const CustomSerializer([
    this._inner = const ValueSerializer.defaults(
      serializeDateTimeValuesAsString: true,
    ),
  ]);

  @override
  T fromJson<T>(dynamic json) {
    if (json == null) {
      return null as T;
    }
    // Handle BigInt conversion from int/String
    // When PostgreSQL bigint values are small enough, they're deserialized as Dart int
    if (T == BigInt) {
      if (json is int) {
        return BigInt.from(json) as T;
      } else if (json is String) {
        return BigInt.parse(json) as T;
      }
    }
    return _inner.fromJson<T>(json);
  }

  @override
  dynamic toJson<T>(T value) {
    if (value is DateTime) {
      return (value as DateTime).toUtc().toIso8601String();
    }
    return _inner.toJson(value);
  }
}


class LocalDateTimeConverter extends TypeConverter<DateTime, DateTime> {
  const LocalDateTimeConverter();

  @override
  DateTime fromSql(DateTime fromDb) {
    return fromDb.toLocal();
  }

  @override
  DateTime toSql(DateTime value) {
    return value.toUtc();
  }
}

class JsonConverter extends TypeConverter<Map<String, dynamic>, String>
    with JsonTypeConverter2<Map<String, dynamic>, String, Map<String, dynamic>> {
  const JsonConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) {
    return jsonDecode(fromDb) as Map<String, dynamic>;
  }

  @override
  String toSql(Map<String, dynamic> value) {
    return jsonEncode(value);
  }

  @override
  Map<String, dynamic> fromJson(Map<String, dynamic> json) {
    return json;
  }

  @override
  Map<String, dynamic> toJson(Map<String, dynamic> value) {
    return value;
  }
}
