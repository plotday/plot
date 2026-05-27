part of 'store.dart';

/*
 * ids must not change.
 * ids 1-99 are TagType.compute
 * ids 100-999 are TagType.toggle
 * ids 1000+ are TagType.count
 */
enum Tag {
  // Compute tags
  todo(
    1,
    PlotIcon.todo,
    'Todo',
    type: TagType.compute,
    shortcodes: ['todo', 'do'],
  ),
  done(3, PlotIcon.done, 'Done', shortcodes: ['done', 'white_check_mark']),
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
  unread(9, PlotIcon.unread, 'Unread', type: TagType.compute, addable: false),
  /// Task list filter — threads where the user has set `task = true`
  /// (typically connector-driven assignments like Linear / Todoist).
  task(
    10,
    PlotIcon.activity,
    'Task list',
    type: TagType.compute,
    addable: false,
    shortcodes: ['task', 'tasklist'],
  ),
  /// Reading list filter — threads where the user has set `to_read = true`.
  reading(
    11,
    PlotIcon.bookOpenLines,
    'Reading list',
    type: TagType.compute,
    addable: false,
    shortcodes: ['reading', 'readinglist'],
  ),
  /// Runtime-managed Twisting indicator — the twist runtime sets this on
  /// notes it's currently processing. Reassigned from legacy id 109 to 12
  /// (compute range) when toggle tags were retired.
  twist(
    12,
    PlotIcon.twist,
    'Twisting',
    type: TagType.compute,
    addable: false,
    shortcodes: ['twist', 'twisting'],
  ),

  // Count tags
  yes(
    1000,
    PlotIcon.yes,
    'Yes',
    type: TagType.count,
    shortcodes: ['yes', '+1', 'thumbsup'],
  ),
  looking(
    1006,
    PlotIcon.looking,
    'Looking',
    type: TagType.count,
    shortcodes: ['looking', 'eyes'],
  ),
  volunteer(
    1002,
    PlotIcon.volunteer,
    'Volunteer',
    type: TagType.count,
    shortcodes: ['volunteer', 'raised_hand'],
  ),
  thanks(
    1010,
    PlotIcon.thanks,
    'Thanks',
    type: TagType.count,
    shortcodes: ['thanks', 'pray'],
  ),
  no(
    1001,
    PlotIcon.no,
    'No',
    type: TagType.count,
    shortcodes: ['no', '-1', 'thumbsdown'],
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
  reply(
    1019,
    PlotIcon.flag,
    'Reply',
    type: TagType.count,
    shortcodes: ['reply', 'flag'],
  ),
  thinking(
    1013,
    PlotIcon.thinking,
    'Thinking',
    type: TagType.count,
    shortcodes: ['thinking', 'thinking_face'],
  ),
  remember(
    1014,
    PlotIcon.remember,
    'Remember',
    type: TagType.count,
    shortcodes: ['remember', 'reminder'],
  ),
  agreed(
    1020,
    PlotIcon.agreed,
    'Agreed',
    type: TagType.count,
    shortcodes: ['agreed', 'handshake'],
  ),
  relieved(
    1021,
    PlotIcon.relieved,
    'Relieved',
    type: TagType.count,
    shortcodes: ['relieved'],
  ),
  send(
    1022,
    PlotIcon.send,
    'Send',
    type: TagType.count,
    shortcodes: ['send', 'paper_plane'],
  ),
  noted(
    1023,
    PlotIcon.noted,
    'Noted',
    type: TagType.count,
    shortcodes: ['noted', 'note'],
  ),
  laugh(
    1024,
    PlotIcon.laugh,
    'Laugh',
    type: TagType.count,
    shortcodes: ['laugh', 'lol', 'joy'],
  ),
  surprised(
    1025,
    PlotIcon.surprised,
    'Surprised',
    type: TagType.count,
    shortcodes: ['surprised', 'astonished', 'wow'],
  ),
  confused(
    1026,
    PlotIcon.confused,
    'Confused',
    type: TagType.count,
    shortcodes: ['confused'],
  ),
  dismayed(
    1027,
    PlotIcon.dismayed,
    'Dismayed',
    type: TagType.count,
    shortcodes: ['dismayed', 'anguished'],
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

  bool matchesSearch(String search) {
    final words = search.toLowerCase().trim().split(RegExp(r'\s+'));
    return words.every(
      (word) =>
          name.toLowerCase().startsWith(word) ||
          shortcodes.any((sc) => sc.startsWith(word)),
    );
  }

  @override
  String toString() => name;
}

/// A list of actor IDs for a tag, with an optional total count that may differ
/// from the list length when some actors are hidden (e.g. viewer privacy).
/// Extends DelegatingList so it works as a drop-in `List<ActorId>` everywhere.
class TagActors extends DelegatingList<ActorId> {
  /// Total count of actors including hidden ones.
  final int count;

  TagActors(super.actors, [int? count]) : count = count ?? actors.length;

  /// Create a TagActors with no count override.
  factory TagActors.from(List<ActorId> actors) => TagActors(actors);

  /// Get total count from a tag actor list, using [TagActors.count] when
  /// available (includes hidden voters), falling back to list length.
  static int countOf(List<ActorId>? actors) {
    if (actors == null) return 0;
    if (actors is TagActors) return actors.count;
    return actors.length;
  }
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
        final tag = Tag.get(id: id);
        if (tag == null) {
          log.warning('No tag found for id: $id');
          continue;
        }

        final value = entry.value;
        if (value is Map<String, dynamic>) {
          // New format: { "c": totalCount, "a": [actorIds] }
          final count = value['c'] as int;
          final actors = (value['a'] as List<dynamic>)
              .whereType<String>()
              .map(ActorId.fromString)
              .toList();
          result[tag] = TagActors(actors, count);
        } else if (value is List<dynamic>) {
          // Standard format: [actorIds]
          final actors = value
              .whereType<String>()
              .map(ActorId.fromString)
              .toList();
          result[tag] = TagActors(actors);
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
      final Map<String, dynamic> result = {};

      for (final entry in value.entries) {
        final tag = entry.key;
        final actors = entry.value;
        if (actors is TagActors && actors.count != actors.length) {
          // Preserve count override for local storage round-trip
          result[tag.id.toString()] = {
            'c': actors.count,
            'a': actors.map((uuid) => uuid.toString()).toList(),
          };
        } else {
          result[tag.id.toString()] = actors
              .map((uuid) => uuid.toString())
              .toList();
        }
      }

      return result;
    } catch (e, t) {
      log.warning('Error encoding tags to JSON', e, t);
      return null;
    }
  }
}

class TagUpdatesConverter extends TypeConverter<Map<String, bool>?, String?>
    with
        JsonTypeConverter2<Map<String, bool>?, String?, Map<String, dynamic>?> {
  const TagUpdatesConverter();

  @override
  Map<String, bool>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    try {
      final decoded = jsonDecode(fromDb) as Map<String, dynamic>?;
      if (decoded == null) return null;

      return decoded.map((key, value) => MapEntry(key, value as bool));
    } catch (e, t) {
      log.warning('Error decoding tagUpdates', e, t);
      return null;
    }
  }

  @override
  String? toSql(Map<String, bool>? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return jsonEncode(value);
    } catch (e, t) {
      log.warning('Error encoding tagUpdates', e, t);
      return null;
    }
  }

  @override
  Map<String, bool>? fromJson(Map<String, dynamic>? json) {
    return null;
  }

  @override
  Map<String, dynamic>? toJson(Map<String, bool>? value) {
    if (value == null) return null;
    try {
      final Map<String, bool> result = {};
      for (final entry in value.entries) {
        result[entry.key] = entry.value;
      }
      return result;
    } catch (e, t) {
      log.warning('Error encoding tags to JSON', e, t);
      return null;
    }
  }
}
