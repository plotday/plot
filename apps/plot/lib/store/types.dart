import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:change_case/change_case.dart';
import 'package:logging/logging.dart';

import '../util/uuid.dart';
import 'enums.dart';

final _serializerLog = Logger('plot.serializer');

enum AuthProvider { google, microsoft, slack, apple, github, discord, notion, atlassian, linear, monday, asana, hubspot, airtable, linkedin, other }

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
      // Non-nullable primitives can't take a null cast. When the API omits a
      // newer column (deploy window where the server is on an older schema
      // than the client), default to the type's zero value rather than
      // crashing the entire row — `T == bool` distinguishes `bool` from
      // `bool?`, so genuinely nullable fields still parse as null.
      if (T == bool) return false as T;
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
    try {
      return _inner.fromJson<T>(json);
    } catch (e) {
      _serializerLog.severe(
        'fromJson<$T> failed — json type: ${json.runtimeType}, value: $json',
        e,
      );
      rethrow;
    }
  }

  @override
  dynamic toJson<T>(T value) {
    if (value is DateTime) {
      return (value as DateTime).toUtc().toIso8601String();
    }
    try {
      return _inner.toJson<T>(value);
    } catch (e) {
      _serializerLog.severe(
        'toJson<$T> failed — value type: ${value.runtimeType}, value: $value',
        e,
      );
      rethrow;
    }
  }
}


/// A single external account mapping for a contact, scoped to one
/// connection ([twistInstanceId]). The same Plot contact reachable through
/// multiple connections (two Slack workspaces, Gmail + Google Chat, etc.)
/// has multiple [ContactExternalAccount] entries. The DM picker filters by
/// `twistInstanceId` so each connection only sees its own roster.
///
/// [provider] is kept for display only (the Flutter UI shows "Slack" /
/// "Gmail" tags) and is not load-bearing for filtering.
class ContactExternalAccount {
  const ContactExternalAccount({
    required this.twistInstanceId,
    required this.accountId,
    this.provider,
  });

  final Uuid twistInstanceId;
  final String accountId;
  final String? provider;

  factory ContactExternalAccount.fromJson(Map<String, dynamic> json) {
    return ContactExternalAccount(
      twistInstanceId: Uuid.fromString(json['twist_instance_id'] as String),
      accountId: json['account_id'] as String,
      provider: json['provider'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'twist_instance_id': twistInstanceId.toString(),
    'account_id': accountId,
    if (provider != null) 'provider': provider,
  };

  @override
  String toString() =>
      'ContactExternalAccount($twistInstanceId, $accountId${provider == null ? '' : ', $provider'})';

  @override
  bool operator ==(Object other) =>
      other is ContactExternalAccount &&
      other.twistInstanceId == twistInstanceId &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(twistInstanceId, accountId);
}

/// Drift converter for a list of [ContactExternalAccount] objects.
/// Stored in SQLite as a JSON string. The sync layer sends a JSON array of
/// {provider, account_id} objects (aggregated by the user.actor view).
class ExternalAccountListConverter
    extends TypeConverter<List<ContactExternalAccount>, String>
    with JsonTypeConverter2<List<ContactExternalAccount>, String, List<dynamic>> {
  const ExternalAccountListConverter();

  @override
  List<ContactExternalAccount> fromSql(String fromDb) {
    if (fromDb.isEmpty || fromDb == '[]') return [];
    final decoded = jsonDecode(fromDb);
    if (decoded is! List) return [];
    return decoded
        .map((item) => ContactExternalAccount.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  String toSql(List<ContactExternalAccount> value) {
    return jsonEncode(value.map((e) => e.toJson()).toList());
  }

  @override
  List<ContactExternalAccount> fromJson(List<dynamic> json) {
    return json
        .map((item) => ContactExternalAccount.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  List<dynamic> toJson(List<ContactExternalAccount> value) {
    return value.map((e) => e.toJson()).toList();
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
