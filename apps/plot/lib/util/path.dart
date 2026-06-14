import 'package:drift/drift.dart';

/// Legacy ltree-style priority path. The client is path-independent: routing,
/// focus scoping, and display all key on the priority id. This type now only
/// backs the nullable `priorities.path` storage column (via [PathConverter])
/// and the few residual descendant-walking reads that still inspect the path
/// tree while the server keeps emitting it. The held server follow-up removes
/// `path` entirely.
extension type Path(String value) {
  bool get isRoot => !value.contains('.');

  Path? get parent {
    if (isRoot) return null;
    final segments = value.split('.');
    return Path(segments.take(segments.length - 1).join('.'));
  }

  bool isParent(Path other) => other.value.startsWith("$value.");
  bool isChild(Path? other) =>
      other == null || value.startsWith("${other.value}.");
}

class PathConverter extends TypeConverter<Path, String>
    with JsonTypeConverter2<Path, String, String> {
  const PathConverter();

  @override
  Path fromSql(String fromDb) => Path(fromDb);

  @override
  String toSql(Path value) => value.value;

  @override
  Path fromJson(String json) => fromSql(json);

  @override
  String toJson(Path value) => toSql(value);
}
