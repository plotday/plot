import 'package:drift/drift.dart';

/// Stores a `List<String>` as a comma-joined string in SQLite and as a JSON
/// array over the sync wire (matching the server's jsonb array columns).
/// Mirrors [UuidListConverter] in `uuid.dart`. Values must not contain commas;
/// the only use is stable identifier keys (focus-suggestion keys), which never
/// do.
class StringListConverter extends TypeConverter<List<String>, String>
    with JsonTypeConverter2<List<String>, String, List<dynamic>> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    return fromDb.split(',');
  }

  @override
  String toSql(List<String> value) => value.join(',');

  @override
  List<String> fromJson(List<dynamic> json) =>
      json.map((e) => e as String).toList();

  @override
  List<dynamic> toJson(List<String> value) => value;
}
