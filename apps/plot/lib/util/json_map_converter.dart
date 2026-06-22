import 'dart:convert';

import 'package:drift/drift.dart';

/// Stores a JSON object as an encoded string in SQLite and as a JSON object
/// over the sync wire (matching the server's jsonb columns). Mirrors
/// [StringListConverter] in `string_list_converter.dart` but for a map payload
/// (e.g. `user_settings.move_affinity`).
class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String>
    with
        JsonTypeConverter2<Map<String, dynamic>, String,
            Map<String, dynamic>> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const {};
    final decoded = jsonDecode(fromDb);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  String toSql(Map<String, dynamic> value) => jsonEncode(value);

  @override
  Map<String, dynamic> fromJson(Map<String, dynamic> json) => json;

  @override
  Map<String, dynamic> toJson(Map<String, dynamic> value) => value;
}
