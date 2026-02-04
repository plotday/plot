part of 'store.dart';

/*
 * ids must not change.
 * ids 1-99 are TagType.compute
 * ids 100-999 are TagType.toggle
 * ids 1000+ are TagType.count
 */
enum Tag {
  // Compute tags
  now(
    1,
    PlotIcon.now,
    'Do Now',
    type: TagType.compute,
    shortcodes: ['do', 'arrow_forward'],
  ),
  later(
    2,
    PlotIcon.later,
    'Do Later',
    type: TagType.compute,
    shortcodes: ['later', 'alarm_clock'],
  ),
  someday(
    7,
    PlotIcon.someday,
    'Do Someday',
    type: TagType.compute,
    shortcodes: ['someday'],
  ),
  done(
    3,
    PlotIcon.done,
    'Done',
    type: TagType.compute,
    shortcodes: ['done', 'white_check_mark'],
  ),
  archived(
    4,
    PlotIcon.archived,
    'Archived',
    type: TagType.compute,
    shortcodes: ['archive', 'file_cabinet'],
  ),
  attachment(
    5,
    PlotIcon.attachment,
    'Attachment',
    type: TagType.compute,

    addable: false,
  ),
  link(6, PlotIcon.link, 'Link', type: TagType.compute, addable: false),
  private(
    8,
    PlotIcon.private,
    'Private',
    type: TagType.compute,
    shortcodes: ['private', 'lock'],
  ),

  // Toggle tags
  pinned(100, PlotIcon.pinned, 'Pinned', shortcodes: ['pushpin']),
  inbox(102, PlotIcon.todo, 'Inbox', shortcodes: ['todo', 'inbox_tray']),
  decision(
    104,
    PlotIcon.decision,
    'Decision',
    shortcodes: ['decision', 'thinking_face'],
  ),
  goal(103, PlotIcon.goal, 'Goal', shortcodes: ['goal', 'dart']),
  urgent(101, PlotIcon.urgent, 'Urgent', shortcodes: ['rotating_light']),
  waiting(
    105,
    PlotIcon.waiting,
    'Waiting',
    shortcodes: ['waiting', 'hourglass'],
  ),
  blocked(106, PlotIcon.blocked, 'Blocked', shortcodes: ['blocked', 'x']),
  warning(107, PlotIcon.warning, 'Warning', shortcodes: ['warning']),
  question(108, PlotIcon.question, 'Question', shortcodes: ['question']),
  twist(109, PlotIcon.twist, 'Twisting', shortcodes: ['twist', 'twisting'], addable: false),
  star(110, PlotIcon.star, 'Star', shortcodes: ['star']),
  idea(111, PlotIcon.idea, 'Idea', shortcodes: ['idea', 'bulb', 'lightbulb']),

  // Count tags
  yes(
    1000,
    PlotIcon.yes,
    'Yes',
    type: TagType.count,
    shortcodes: ['yes', '+1', 'thumbsup'],
  ),
  no(
    1001,
    PlotIcon.no,
    'No',
    type: TagType.count,
    shortcodes: ['no', '-1', 'thumbsdown'],
  ),
  volunteer(
    1002,
    PlotIcon.volunteer,
    'Volunteer',
    type: TagType.count,
    shortcodes: ['volunteer', 'raised_hand'],
  ),
  tada(
    1003,
    PlotIcon.celebration,
    'Celebration',
    type: TagType.count,
    shortcodes: ['tada'],
  ),
  fire(1004, PlotIcon.fire, 'Fire', type: TagType.count, shortcodes: ['fire']),
  totally(
    1005,
    PlotIcon.totally,
    '100',
    type: TagType.count,
    shortcodes: ['totally', '100'],
  ),
  looking(
    1006,
    PlotIcon.looking,
    'Looking',
    type: TagType.count,
    shortcodes: ['looking', 'eyes'],
  ),
  love(
    1007,
    PlotIcon.heart,
    'Love',
    type: TagType.count,
    shortcodes: ['love', 'heart'],
  ),
  rocket(
    1008,
    PlotIcon.rocket,
    'Rocket',
    type: TagType.count,
    shortcodes: ['rocket'],
  ),
  sparkles(
    1009,
    PlotIcon.sparkles,
    'Sparkles',
    type: TagType.count,
    shortcodes: ['sparkles'],
  ),
  thanks(
    1010,
    PlotIcon.thanks,
    'Thanks',
    type: TagType.count,
    shortcodes: ['thanks', 'pray'],
  ),
  smile(
    1011,
    PlotIcon.smile,
    'Smile',
    type: TagType.count,
    shortcodes: ['smiley'],
  ),
  wave(1012, PlotIcon.wave, 'Wave', type: TagType.count, shortcodes: ['wave']),
  admiration(
    1015,
    PlotIcon.heartEyes,
    'Admiration',
    type: TagType.count,
    shortcodes: ['admiration', 'heart_eyes'],
  ),
  applause(
    1016,
    PlotIcon.praise,
    'Praise',
    type: TagType.count,
    shortcodes: ['praise', 'applause', 'clap'],
  ),
  cool(
    1017,
    PlotIcon.cool,
    'Cool',
    type: TagType.count,
    shortcodes: ['cool', 'sunglasses'],
  ),
  sad(
    1018,
    PlotIcon.cry,
    'Sad',
    type: TagType.count,
    shortcodes: ['sad', 'cry'],
  ),
  attend(
    1019,
    PlotIcon.attend,
    'Attend',
    type: TagType.count,
    shortcodes: ['attend', 'yes', 'person_gesturing_ok'],
  ),
  skip(
    1020,
    PlotIcon.skip,
    'Skip',
    type: TagType.count,
    shortcodes: ['skip', 'no', 'no_good'],
  ),
  undecided(
    1021,
    PlotIcon.undecided,
    'Undecided',
    type: TagType.count,
    shortcodes: ['undecided', 'shrug', 'person_shrugging'],
  );

  final int id;
  final IconData icon;
  final String name;
  final TagType type;
  final bool addable;
  final List<String> shortcodes;
  final bool _hidden;

  const Tag(
    this.id,
    this.icon,
    this.name, {
    this.type = TagType.toggle,
    this.addable = true,
    this.shortcodes = const [],
  }) : _hidden = false;

  // Get all tags
  static List<Tag> getAll({bool onlyAddable = false}) => Tag.values
      .where((tag) => !tag._hidden && (!onlyAddable || tag.addable))
      .toList();

  // Get tag by id or icon
  static Tag? get({int? id, IconData? icon}) {
    return Tag.values.firstWhereOrNull(
      (tag) =>
          (id != null && tag.id == id) ||
          (icon != null && !tag._hidden && tag.icon == icon),
    );
  }

  // Check if this tag is an RSVP tag (mutually exclusive)
  bool get isRsvp => this == Tag.attend || this == Tag.skip || this == Tag.undecided;

  // Get all RSVP tags (for removal during exclusivity enforcement)
  static List<Tag> get rsvpTags => [Tag.attend, Tag.skip, Tag.undecided];

  @override
  String toString() => name;
}

class TagsConverter extends TypeConverter<Map<Tag, List<ActorId>>?, String?>
    with
        JsonTypeConverter2<
          Map<Tag, List<ActorId>>?,
          String?,
          Map<String, dynamic>?
        > {
  const TagsConverter();

  @override
  Map<Tag, List<ActorId>>? fromSql(String? fromDb) {
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
  String? toSql(Map<Tag, List<ActorId>>? value) {
    if (value == null) return null;
    try {
      return jsonEncode(toJson(value));
    } catch (e, t) {
      log.warning('Error encoding tags to SQL', e, t);
      return null;
    }
  }

  @override
  Map<Tag, List<ActorId>>? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final Map<Tag, List<ActorId>> result = {};

    for (final entry in json.entries) {
      try {
        final id = int.parse(entry.key);
        final userIds = (entry.value as List<dynamic>)
            .map((dynamic id) => ActorId.fromString(id as String))
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
  Map<String, dynamic>? toJson(Map<Tag, List<ActorId>>? value) {
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
