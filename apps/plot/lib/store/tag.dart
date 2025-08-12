part of 'store.dart';

/*
 * ids must not change.
 * ids 1-99 are TagType.compute
 * ids 100-999 are TagType.toggle
 * ids 1000+ are TagType.count
 */
enum Tag {
  doNow(1, PlotIcon.doNow, 'Do Now', type: TagType.compute),
  doLater(2, PlotIcon.doLater, 'Do Later', type: TagType.compute),
  done(3, PlotIcon.done, 'Done', type: TagType.compute),
  archived(4, PlotIcon.archived, 'Archived', type: TagType.compute),

  pinned(100, PlotIcon.pinned, 'Pinned'),
  urgent(101, PlotIcon.urgent, 'Urgent'),
  todo(102, PlotIcon.todo, 'To-do'),
  goal(103, PlotIcon.goal, 'Goal'),
  decision(104, PlotIcon.decision, 'Decision'),
  futureToggle1._hide(105),
  futureToggle2._hide(106),
  futureToggle3._hide(107),
  futureToggle4._hide(108),
  futureToggle5._hide(100),
  futureToggle6._hide(110),
  futureToggle7._hide(111),
  futureToggle8._hide(112),
  futureToggle9._hide(113),

  yes(1000, PlotIcon.yes, 'Yes', type: TagType.count),
  no(1001, PlotIcon.no, 'No', type: TagType.count),
  volunteer(1002, PlotIcon.volunteer, 'Volunteer', type: TagType.count),
  tada(1003, PlotIcon.celebration, 'Celebration', type: TagType.count),
  futureCount1._hide(1004),
  futureCount2._hide(1005),
  futureCount3._hide(1006),
  futureCount4._hide(1007),
  futureCount5._hide(1008),
  futureCount6._hide(1009),
  futureCount7._hide(1010),
  futureCount8._hide(1011),
  futureCount9._hide(1012);

  final int id;
  final IconData icon;
  final String name;
  final TagType type;
  final bool _hidden;

  const Tag(this.id, this.icon, this.name, {this.type = TagType.toggle})
    : _hidden = false;

  const Tag._hide(this.id)
    : _hidden = true,
      icon = const IconData(0x003F, fontFamily: 'emoji'), // ?
      name = 'Unknown',
      type = TagType.toggle;

  // Get all tags
  static List<Tag> getAll() => Tag.values.where((tag) => !tag._hidden).toList();

  // Get tag by id or icon
  static Tag? get({int? id, IconData? icon}) {
    return Tag.values.firstWhereOrNull(
      (tag) =>
          (id != null && tag.id == id) ||
          (icon != null && !tag._hidden && tag.icon == icon),
    );
  }

  @override
  String toString() => name;
}

class ActivityTagsConverter
    extends TypeConverter<Map<Tag, List<Uuid>>?, String?>
    with
        JsonTypeConverter2<
          Map<Tag, List<Uuid>>?,
          String?,
          Map<String, dynamic>?
        > {
  const ActivityTagsConverter();

  @override
  Map<Tag, List<Uuid>>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    try {
      final json = jsonDecode(fromDb) as Map<String, dynamic>?;
      if (json == null) return null;
      return fromJson(json);
    } catch (e, t) {
      log.warning('Error decoding tags from SQL', e, t);
      return null;
    }
  }

  @override
  String? toSql(Map<Tag, List<Uuid>>? value) {
    if (value == null) return null;
    try {
      return jsonEncode(toJson(value));
    } catch (e, t) {
      log.warning('Error encoding tags to SQL', e, t);
      return null;
    }
  }

  @override
  Map<Tag, List<Uuid>>? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final Map<Tag, List<Uuid>> result = {};

    for (final entry in json.entries) {
      try {
        final id = int.parse(entry.key);
        final userIds = (entry.value as List<dynamic>)
            .map((dynamic id) => Uuid.fromString(id as String))
            .toList();

        final tag = Tag.get(id: id);
        if (tag != null) {
          result[tag] = userIds;
        } else {
          log.warning('No tag found for id: $id');
        }
      } catch (e, t) {
        log.warning('Error decoding tags from JSON', e, t);
        return null;
      }
    }

    return result;
  }

  @override
  Map<String, dynamic>? toJson(Map<Tag, List<Uuid>>? value) {
    if (value == null) return null;
    try {
      final Map<String, List<String>> result = {};

      for (final entry in value.entries) {
        final tag = entry.key;
        final uuids = entry.value;
        result[tag.id.toString()] = uuids
            .map((uuid) => uuid.toString())
            .toList();
      }

      return result;
    } catch (e, t) {
      log.warning('Error encoding tags to JSON', e, t);
      return null;
    }
  }
}

class TagUpdatesConverter extends TypeConverter<Map<int, bool>?, String?>
    with JsonTypeConverter2<Map<int, bool>?, String?, Map<String, dynamic>?> {
  const TagUpdatesConverter();

  @override
  Map<int, bool>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    try {
      final decoded = jsonDecode(fromDb) as Map<String, dynamic>?;
      if (decoded == null) return null;

      return decoded.map(
        (key, value) => MapEntry(int.parse(key), value as bool),
      );
    } catch (e, t) {
      log.warning('Error decoding tagUpdates', e, t);
      return null;
    }
  }

  @override
  String? toSql(Map<int, bool>? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final stringMap = value.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      return jsonEncode(stringMap);
    } catch (e, t) {
      log.warning('Error encoding tagUpdates', e, t);
      return null;
    }
  }

  @override
  Map<int, bool>? fromJson(Map<String, dynamic>? json) {
    return null;
  }

  @override
  Map<String, dynamic>? toJson(Map<int, bool>? value) {
    if (value == null) return null;
    try {
      final Map<String, bool> result = {};
      for (final entry in value.entries) {
        final tag = entry.key;
        result[tag.toString()] = entry.value;
      }
      return result;
    } catch (e, t) {
      log.warning('Error encoding tags to JSON', e, t);
      return null;
    }
  }
}
