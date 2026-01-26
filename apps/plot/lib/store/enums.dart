import 'package:collection/collection.dart';
import 'package:change_case/change_case.dart';

enum TagType { toggle, count, compute }

enum ActivityType { action, event, note }

enum ActivityKind {
  document,
  messages,
  meeting,
  videoconference,
  phone,
  focus,
  meal,
  exercise,
  family,
  travel,
  social,
  entertainment,
}

enum ActorType { user, contact, priorityTwist }

enum EnterBehavior { enterNewline, enterSubmits }

extension StringToEnum on String {
  T toEnum<T extends Enum>() {
    List<T>? values;
    if (T == TagType) values = TagType.values as List<T>;
    if (T == ActivityType) values = ActivityType.values as List<T>;
    if (T == ActivityKind) values = ActivityKind.values as List<T>;
    if (T == ActorType) values = ActorType.values as List<T>;
    if (T == EnterBehavior) values = EnterBehavior.values as List<T>;
    if (values == null) {
      throw ArgumentError('Missing enum for $T');
    }
    final value = values.firstWhereOrNull(
      (e) => (e as Enum).name == toCamelCase(),
    );
    if (value == null) {
      throw ArgumentError('Unknown enum value for $T: $this');
    }
    return value;
  }
}
