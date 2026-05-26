part of 'store.dart';

/// A reaction is identified by an emoji string. This is either a Unicode
/// grapheme cluster (e.g. `"👍"`, `"👨‍👩‍👧"`) or a provider-scoped custom-emoji
/// reference (e.g. `"slack:T0123ABC/party_parrot"`).
///
/// The discriminator is simple: if the string contains a `:` followed by a
/// known provider scheme (e.g. `slack:`, `google_chat:`) the reference is a
/// custom-emoji ref; otherwise it is rendered directly via the platform /
/// bundled emoji font.
typedef Reaction = String;

/// Stored on a [Note] / [Thread] as `{ <emoji>: [actorId, ...] }`.
typedef Reactions = Map<Reaction, List<ActorId>>;

/// Curated default "quick-picks" row for the reaction picker. These are the
/// emoji we expect users to reach for most often. Pulled in part from the
/// 19 legacy count tags so that the new picker is at least as discoverable as
/// the old chip menu.
const List<Reaction> kReactionQuickPicks = <Reaction>[
  '👍',
  '❤️',
  '😂',
  '🎉',
  '👀',
  '🙏',
  '🔥',
  '🚀',
  '✨',
  '💯',
  '👏',
  '😢',
];

/// Returns true when [emoji] is a provider-scoped custom-emoji ref.
///
/// Examples: `slack:T0123/party_parrot`, `google_chat:customers/ABC/123`.
/// The check is intentionally permissive: any string starting with one of
/// the recognized provider prefixes is treated as a custom-emoji ref.
bool isCustomEmojiRef(Reaction emoji) {
  return emoji.startsWith('slack:') || emoji.startsWith('google_chat:');
}

/// What reactions a connector's source platform supports.
///
/// Mirrors the Twister-side `ReactionCapabilities` discriminated union. The
/// client uses this to filter the picker: `fixed` platforms (e.g. LinkedIn
/// Messaging) show only the allowed set; `open` platforms (Slack, Teams,
/// Google Chat, Plot-native) show the full picker.
sealed class ReactionCapabilities {
  const ReactionCapabilities();

  /// Returns the allowed set as a flat list, or null when any emoji is
  /// allowed (open). Used directly by the picker's `allowed` parameter.
  List<Reaction>? get allowed;
}

class _OpenReactions extends ReactionCapabilities {
  const _OpenReactions();
  @override
  List<Reaction>? get allowed => null;
}

class _FixedReactions extends ReactionCapabilities {
  const _FixedReactions(this._set);
  final List<Reaction> _set;
  @override
  List<Reaction>? get allowed => _set;
}

const ReactionCapabilities _kOpen = _OpenReactions();

/// LinkedIn Messaging's fixed reaction set. Kept here (not on the
/// connector) so the picker can enforce it before LinkedIn lands as a
/// linked connector — and after, without a round-trip to the SDK.
const ReactionCapabilities _kLinkedInReactions = _FixedReactions([
  '👍', '❤️', '👏', '💡', '😂', '😮', '😢',
]);

/// Returns the reaction capabilities for a given link `source`. Recognizes
/// the source-prefix conventions used by the existing connectors
/// (`google-chat:`, `ms-teams:`, `slack.com/app_redirect`, `linkedin:`).
/// Unknown sources and `null` (Plot-native threads) return open Unicode.
ReactionCapabilities reactionCapabilitiesForLinkSource(String? source) {
  if (source == null) return _kOpen;
  if (source.startsWith('linkedin:')) return _kLinkedInReactions;
  // Slack, Teams, Google Chat all accept open Unicode. Even if the
  // source prefix is unrecognised, default to open — the picker stays
  // permissive; outbound dispatch on the server already drops emoji
  // the platform can't accept.
  return _kOpen;
}

/// JSON ↔ SQLite converter for `{ <emoji>: [actorId, ...] }` shaped reactions.
///
/// Mirrors [TagsConverter] but keyed by emoji string rather than [Tag]. The
/// server's `note_reactions` / `thread_reactions` views emit `reactions` as
/// `jsonb_object_agg(emoji, actor_ids)`.
class ReactionsConverter extends TypeConverter<Reactions?, String?>
    with JsonTypeConverter2<Reactions?, String?, Map<String, dynamic>?> {
  const ReactionsConverter();

  @override
  Reactions? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    try {
      final json = jsonDecode(fromDb) as Map<String, dynamic>?;
      if (json == null) return null;
      return fromJson(json);
    } catch (e, t) {
      log.warning('Error decoding reactions from SQL', e, t);
      return null;
    }
  }

  @override
  String? toSql(Reactions? value) {
    if (value == null) return null;
    try {
      return jsonEncode(toJson(value));
    } catch (e, t) {
      log.warning('Error encoding reactions to SQL', e, t);
      return null;
    }
  }

  @override
  Reactions? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final result = <Reaction, List<ActorId>>{};
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! List<dynamic>) continue;
      final actors = value
          .whereType<String>()
          .map(ActorId.fromString)
          .toList();
      result[entry.key] = actors;
    }
    return result;
  }

  @override
  Map<String, dynamic>? toJson(Reactions? value) {
    if (value == null) return null;
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      result[entry.key] = entry.value.map((id) => id.toString()).toList();
    }
    return result;
  }
}

/// JSON ↔ SQLite converter for pending reaction updates: `{ <emoji>: bool }`.
/// Mirrors [TagUpdatesConverter] — represents optimistic add/remove of the
/// current user's reaction, pending push to the server.
class ReactionUpdatesConverter extends TypeConverter<Map<String, bool>?, String?>
    with JsonTypeConverter2<Map<String, bool>?, String?, Map<String, dynamic>?> {
  const ReactionUpdatesConverter();

  @override
  Map<String, bool>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    try {
      final decoded = jsonDecode(fromDb) as Map<String, dynamic>?;
      if (decoded == null) return null;
      return decoded.map((key, value) => MapEntry(key, value as bool));
    } catch (e, t) {
      log.warning('Error decoding reactionUpdates', e, t);
      return null;
    }
  }

  @override
  String? toSql(Map<String, bool>? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return jsonEncode(value);
    } catch (e, t) {
      log.warning('Error encoding reactionUpdates', e, t);
      return null;
    }
  }

  @override
  Map<String, bool>? fromJson(Map<String, dynamic>? json) => null;

  @override
  Map<String, dynamic>? toJson(Map<String, bool>? value) {
    if (value == null) return null;
    return Map<String, dynamic>.from(value);
  }
}
