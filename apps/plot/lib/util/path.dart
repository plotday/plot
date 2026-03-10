import 'dart:math';
import 'package:drift/drift.dart';

extension type Path(String value) {
  factory Path.generate({Path? parent}) {
    const characters =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    Random random = Random();
    String prefix = "";
    if (parent != null) {
      prefix = "${parent.value}.";
    }
    return Path(
      prefix +
          String.fromCharCodes(
            Iterable.generate(
              4,
              (_) => characters.codeUnitAt(random.nextInt(characters.length)),
            ),
          ),
    );
  }

  int get depth => value.split('.').length;

  bool get isRoot => !value.contains('.');

  Path? get parent {
    if (isRoot) return null;
    final segments = value.split('.');
    return Path(segments.take(segments.length - 1).join('.'));
  }

  Path get root => Path(value.split('.').first);

  bool isParent(Path other) => other.value.startsWith("$value.");
  bool isChild(Path? other) =>
      other == null || value.startsWith("${other.value}.");

  /// Replace the prefix of this path with a new prefix.
  /// Used when moving a priority and all its descendants to a new parent.
  Path replacePrefix(Path oldPrefix, Path newPrefix) {
    if (!value.startsWith("${oldPrefix.value}.") && value != oldPrefix.value) {
      // This path doesn't start with the old prefix
      return this;
    }

    if (value == oldPrefix.value) {
      // This is the exact path being replaced
      return newPrefix;
    }

    // Replace the prefix
    final suffix = value.substring(oldPrefix.value.length);
    return Path('${newPrefix.value}$suffix');
  }
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
