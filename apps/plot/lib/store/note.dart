part of 'store.dart';

typedef NoteId = Uuid;

@DataClassName('NoteRow')
class Notes extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get activityId => blob().map(const UuidConverter())();
  BlobColumn get authorId => blob().map(const ActorIdConverter())();
  BoolColumn get private => boolean().withDefault(const Constant(false))();

  TextColumn get content => text().nullable()();
  TextColumn get links => text().nullable().map(const LinksConverter())();
  TextColumn get mentions =>
      text().nullable().map(const ActorIdListConverter())();
}

class NotesBase extends BaseTable {
  NotesBase({this.activityId})
    : super(
        table: 'user_note',
        writeTable: 'note',
        name: "notes",
        filterName: activityId?.toString(),
        ascending: true, // Order by created_at ascending within an activity
      );

  final ActivityId? activityId;

  @override
  PostgrestFilterBuilder<T2> filter<T2>(
    PostgrestFilterBuilder<T2> query, {
    bool initial = false,
    bool archived = false,
  }) {
    query = super.filter(query, initial: initial, archived: archived);

    // Add activity filtering if activityId is provided
    if (activityId != null) {
      query = query.eq('activity_id', activityId.toString());
    }

    return query;
  }

  @override
  Insertable<NoteRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('user_id');
    return NoteRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Remove author_id - it's set by the database trigger
    json.remove('author_id');

    return json;
  }
}

class Note extends Equatable implements Comparable<Note> {
  factory Note({
    required NoteId id,
    required ActivityId activityId,
    required ActorId authorId,
    required bool draft,
    required bool private,
    String? content,
    List<Link>? links,
    List<ActorId>? mentions,
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? archivedAt,
  }) {
    // Auto-extract mentions from content if content is provided but mentions are not
    final effectiveMentions =
        mentions ??
        (content != null ? _extractMentionsFromMarkdown(content) : null);

    return Note._internal(
      id: id,
      activityId: activityId,
      authorId: authorId,
      draft: draft,
      private: private,
      content: content,
      links: links,
      mentions: effectiveMentions,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt,
      tags: null,
    );
  }

  const Note._internal({
    required this.id,
    required this.activityId,
    required this.authorId,
    required this.draft,
    required this.private,
    this.content,
    this.links,
    this.mentions,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
    NoteTagsRow? tags,
  }) : _tags = tags;

  factory Note._fromStore({required NoteRow noteRow, NoteTagsRow? tags}) {
    // Auto-extract mentions from content if content is provided but mentions are not
    final effectiveMentions =
        noteRow.mentions ??
        (noteRow.content != null
            ? _extractMentionsFromMarkdown(noteRow.content!)
            : null);

    return Note._internal(
      id: noteRow.id,
      activityId: noteRow.activityId,
      authorId: noteRow.authorId,
      draft: noteRow.draft,
      private: noteRow.private,
      content: noteRow.content,
      links: noteRow.links,
      mentions: effectiveMentions,
      createdAt: noteRow.createdAt,
      updatedAt: noteRow.updatedAt,
      archivedAt: noteRow.archivedAt,
      tags: tags,
    );
  }

  final Uuid id;
  final ActivityId activityId;
  final ActorId authorId;
  final bool draft;
  final bool private;
  final String? content;
  final List<Link>? links;
  final List<ActorId>? mentions;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final NoteTagsRow? _tags;

  /// Pull all notes and tags for a specific activity (lazy-loaded on first view).
  /// Tracked in SyncStates as "notes:{activityId}".
  static Future<void> pullForActivity(ActivityId activityId) async {
    // Pull all notes for this activity (first time only)
    await Store.get.pull(
      Store.get.notes,
      NotesBase(activityId: activityId),
      initial: true,
    );

    // Pull all note tags (unfiltered - Drift filters locally based on available notes)
    // We use the activityId in the BaseTable just for sync state tracking
    await Store.get.pull(
      Store.get.noteTags,
      NoteTagsBase(activityId: activityId),
      initial: true,
    );
  }

  /// Pull global updates for all notes and tags (updated since last sync).
  /// Tracked in SyncStates as "notes".
  static Future<void> pullUpdates() async {
    await Store.get.pull(Store.get.notes, NotesBase());
    await Store.get.pull(Store.get.noteTags, NoteTagsBase());
  }

  /// Push pending changes for both notes and note tags.
  static Future<bool> push() async {
    final notesSuccess = await Store.get.push(Store.get.notes, NotesBase());
    final tagsSuccess = await Store.get.push(
      Store.get.noteTags,
      NoteTagsBase(),
    );
    return notesSuccess && tagsSuccess;
  }

  // Legacy method - use pullUpdates() instead
  static Future<void> pull() async {
    await pullUpdates();
  }

  /// Helper to ensure notes are loaded for an activity before watching.
  /// Triggers pullForActivity if this is the first time viewing the activity.
  static void _ensureNotesLoadedForActivity(ActivityId activityId) {
    final entity = "notes:$activityId";

    // Check if we've already loaded notes for this activity (async, don't block)
    (Store.get.select(Store.get.syncStates)
          ..where((s) => s.entity.equals(entity)))
        .getSingleOrNull()
        .then((SyncState? syncState) {
          if (syncState == null) {
            // Never loaded notes for this activity - trigger pull in background
            log.info('First time viewing activity $activityId, pulling notes');
            pullForActivity(activityId).catchError((Object e) {
              log.warning('Failed to pull notes for activity $activityId: $e');
            });
          }
        });
  }

  static Stream<List<Note>> watch(
    ActivityId activityId, {
    bool? archived = false,
    bool? draft = false,
    List<Tag>? filter,
    String? search,
  }) {
    // Check if notes for this activity have been loaded, if not trigger pull
    _ensureNotesLoadedForActivity(activityId);

    // Create a copy of filter to avoid mutating the original
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;

    // Extract special computed tags from filter
    if (mutableFilter?.remove(Tag.archived) == true) {
      archived = true;
    }

    // Trigger archived sync if needed
    if (archived == true || archived == null) {
      Store.get.pullArchived(
        Store.get.notes,
        NotesBase(activityId: activityId),
      );
    }

    final n = Store.get.notes;
    final tags = Store.get.alias(Store.get.noteTags, 'tags');

    // Build query with joins
    var query =
        Store.get.select(n).join([leftOuterJoin(tags, tags.id.equalsExp(n.id))])
          ..where(n.activityId.equalsValue(activityId))
          ..orderBy([OrderingTerm.asc(n.createdAt)])
          ..addColumns([tags.tags]);

    // Filter by archived status if archived parameter is provided
    if (archived != null) {
      query.where(archived ? n.archivedAt.isNotNull() : n.archivedAt.isNull());
    }

    // Filter by draft status if draft parameter is provided
    if (draft != null) {
      query.where(n.draft.equals(draft));
    }

    // Add tag filtering if filter list is provided
    // This must happen AFTER the tags table is joined
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      for (final tag in mutableFilter) {
        query.where(
          CustomExpression<bool>(
            'JSON_EXTRACT(tags.tags, \'\$.${tag.id}\') IS NOT NULL',
          ),
        );
      }
    }

    // Add FTS search filtering if search string is provided
    if (search?.isNotEmpty == true) {
      // Use FTS5 for full-text search with prefix matching on note content
      // Split search into words, escape special characters, and add prefix matching
      final words = search!
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .map(
            (word) => word
                .replaceAll("'", "''") // Escape single quotes for SQL
                .replaceAll('"', '""') // Escape double quotes for FTS5
                .replaceAll('*', '') // Remove asterisks
                .replaceAll('(', '') // Remove parentheses
                .replaceAll(')', ''),
          )
          .where((word) => word.isNotEmpty)
          .map((word) => '$word*') // Add prefix matching to each word
          .join(' '); // AND multiple words together
      if (words.isNotEmpty) {
        // Search note content using note_fts
        query.where(
          CustomExpression<bool>('''
            EXISTS (SELECT 1 FROM note_fts WHERE note_id = notes.id AND note_fts MATCH '$words')
          '''),
        );
      }
    }

    // Watch the query and transform results to Note objects
    return query.watch().map((results) {
      // Group results by note ID
      final noteGroups = <Uuid, List<TypedResult>>{};
      for (final result in results) {
        final noteRow = result.readTable(n);
        noteGroups.putIfAbsent(noteRow.id, () => []).add(result);
      }

      // Create Note instances
      final notes = <Note>[];
      for (final group in noteGroups.values) {
        final noteRow = group.first.readTable(n);
        final tagsRow = group.first.readTableOrNull(tags);
        notes.add(Note._fromStore(noteRow: noteRow, tags: tagsRow));
      }

      return notes;
    });
  }

  /// Watch all tags present in an activity and its notes.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForActivity(ActivityId activityId) {
    final at = Store.get.activityTags;
    final nt = Store.get.noteTags;
    final n = Store.get.notes;

    // Query for activity tags
    final activityTagsQuery = Store.get.select(at)
      ..where((t) => t.id.equalsValue(activityId));

    // Query for note tags belonging to this activity
    final noteTagsQuery = Store.get.select(nt).join([
      innerJoin(n, n.id.equalsExp(nt.id) & n.archivedAt.isNull()),
    ])..where(n.activityId.equalsValue(activityId));

    // COUNT query for stored Tag.archived on notes (notes with archived tag, not archivedAt)
    final noteArchivedQuery = Store.get.selectOnly(n)
      ..addColumns([n.id.count()])
      ..where(n.activityId.equalsValue(activityId) & n.archivedAt.isNull());

    final noteArchivedCountStream = noteArchivedQuery
        // Map the single result row to the count value.
        .map((row) => row.read(n.id.count()))
        // Use watchSingle() to get a Stream<T> for a single result.
        .watchSingle();

    return Rx.combineLatest3(
      activityTagsQuery.watch(),
      noteTagsQuery.watch(),
      noteArchivedCountStream,
      (
        List<ActivityTagsRow> activityTagRows,
        List<TypedResult> noteTagResults,
        int? noteArchivedCount,
      ) {
        final Map<Tag, int> tagCounts = {};
        final Map<Tag, Set<Uuid>> storedTagCounts = {};

        // Count tags from the activity itself
        for (final activityTagsRow in activityTagRows) {
          final tags = activityTagsRow.tags;
          if (tags != null) {
            for (final tag in tags.keys) {
              // Skip computed tags here - we'll add them separately below
              if (tag != Tag.archived) {
                storedTagCounts.putIfAbsent(tag, () => {}).add(activityId);
              }
            }
          }
        }

        // Count tags from notes
        for (final result in noteTagResults) {
          final noteTagsRow = result.readTable(nt);
          final noteId = noteTagsRow.id;
          final tags = noteTagsRow.tags;

          if (tags != null) {
            for (final tag in tags.keys) {
              // Skip computed tags here - we'll add them separately below
              if (tag != Tag.archived) {
                storedTagCounts.putIfAbsent(tag, () => {}).add(noteId);
              }
            }
          }
        }

        // Add stored tag counts (excluding computed tags which are counted separately)
        for (final entry in storedTagCounts.entries) {
          tagCounts[entry.key] = entry.value.length;
        }

        // Add computed tag counts from notes
        if (noteArchivedCount != null && noteArchivedCount > 0) {
          tagCounts[Tag.archived] =
              (tagCounts[Tag.archived] ?? 0) + noteArchivedCount;
        }

        // Convert to list of (Tag, count) and sort by count descending
        final result = tagCounts.entries.map((e) => (e.key, e.value)).toList()
          ..sort((a, b) => b.$2.compareTo(a.$2));

        return result;
      },
    );
  }

  /// Get the most recent draft note for a specific activity
  /// Returns the draft with the most recent updatedAt timestamp
  static Future<Note?> getDraftByActivity(ActivityId activityId) async {
    final n = Store.get.notes;
    final query = Store.get.select(n)
      ..where((tbl) => tbl.activityId.equalsValue(activityId))
      ..where((tbl) => tbl.draft.equals(true))
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
      ..limit(1);

    final results = await query.get();
    if (results.isEmpty) return null;

    return Note._fromStore(noteRow: results.first, tags: null);
  }

  NoteRow toRow() {
    return NoteRow(
      id: id,
      activityId: activityId,
      authorId: authorId,
      draft: draft,
      private: private,
      content: content,
      links: links,
      mentions: mentions,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt,
    );
  }

  Future<void> save() async {
    // Save note row to local DB
    await Store.get.add(Store.get.notes, toRow().toCompanion(false));

    // Save tags row if present
    if (_tags != null) {
      await Store.get.save(
        Store.get.noteTags,
        _tags.toCompanion(false),
        NoteTagsBase(),
      );
    }

    // Update activity's lastNoteCreatedAt to this note's createdAt (only for non-draft notes)
    if (!draft && archivedAt == null) {
      await (Store.get.update(Store.get.activities)
            ..where((a) => a.id.equalsValue(activityId)))
          .write(ActivitiesCompanion(lastNoteCreatedAt: Value(createdAt)));
    }

    // Use orchestrator to ensure parent activity is pushed first, then push note
    await SyncOrchestrator.instance.push(SyncOrchestrator.note);
  }

  Future<void> delete() async {
    await (Store.get.update(Store.get.notes)
          ..where((t) => t.id.equalsValue(id)))
        .write(NotesCompanion(archivedAt: Value(DateTime.now())));
    // Use orchestrator to ensure parent activity is pushed first
    await SyncOrchestrator.instance.push(SyncOrchestrator.note);
  }

  // Tag-related getters
  Map<Tag, List<ActorId>> get tags => _tags?.tags ?? const {};

  /// Get all actors who have Tag.now or Tag.done on this note (i.e., assignees)
  List<ActorId> get assignees {
    final actors = <ActorId>{};
    if (tags[Tag.now] != null) actors.addAll(tags[Tag.now]!);
    if (tags[Tag.done] != null) actors.addAll(tags[Tag.done]!);
    return actors.toList();
  }

  /// Get actors currently working on this note (have Tag.now)
  List<ActorId> get activeAssignees => tags[Tag.now] ?? const [];

  /// Get actors who have completed this note (have Tag.done)
  List<ActorId> get completedAssignees => tags[Tag.done] ?? const [];

  /// Check if all assignees have marked the note as done
  bool get isComplete {
    final allAssignees = assignees;
    if (allAssignees.isEmpty) return false;
    final completed = completedAssignees;
    return allAssignees.every((actor) => completed.contains(actor));
  }

  /// Check if a specific actor has a given tag
  bool hasTag(Tag tag, ActorId actorId) {
    return tags[tag]?.contains(actorId) ?? false;
  }

  /// Check if a specific actor is assigned to this note (has Tag.now)
  bool isAssignedTo(ActorId actorId) => hasTag(Tag.now, actorId);

  /// Check if a specific actor has completed this note (has Tag.done)
  bool isCompletedBy(ActorId actorId) => hasTag(Tag.done, actorId);

  /// Get actor names for a tag, formatted for display in tooltips
  /// Returns a formatted string like "You, Alice, Bob" or "You, Alice, Bob + 2 more"
  Future<String> getTagActorNames(Tag tag) async {
    final actorIds = tags[tag];
    if (actorIds == null || actorIds.isEmpty) {
      return '';
    }

    return Note._formatActorNames(actorIds);
  }

  /// Helper to format a list of actorIds into a display string
  /// - Replaces current user with "You"
  /// - Shows first 3 names + count if more exist
  static Future<String> _formatActorNames(List<ActorId> actorIds) async {
    if (actorIds.isEmpty) return '';

    // Fetch actor names from the database
    final actors =
        await (Store.get.select(Store.get.actors)..where(
              (a) => a.id.isIn(actorIds.map((id) => id.toBytes()).toList()),
            ))
            .get();

    // Create a map of actorId to name
    final actorMap = {for (var actor in actors) actor.id: actor.name};

    // Build the display names list
    final displayNames = <String>[];
    final currentActorId = Base.actorId;

    for (final actorId in actorIds) {
      if (actorId == currentActorId) {
        displayNames.insert(0, 'You'); // Put "You" first
      } else {
        final name = actorMap[actorId] ?? 'Unknown';
        displayNames.add(name);
      }
    }

    // Format the output
    if (displayNames.length <= 3) {
      return displayNames.join(', ');
    } else {
      final first3 = displayNames.take(3).join(', ');
      final remaining = displayNames.length - 3;
      return '$first3 + $remaining more';
    }
  }

  // Tag manipulation methods

  /// Assign this note to an actor by adding Tag.now
  /// Returns a new Note instance with the tag added - caller must call save()
  Note assignTo(ActorId actorId) {
    // Only add Tag.now if the actor doesn't already have it
    if (!hasTag(Tag.now, actorId)) {
      return toggleTag(Tag.now, actorId);
    }
    return this;
  }

  /// Mark this note as complete for an actor by replacing Tag.now with Tag.done
  /// Returns a new Note instance with tags updated - caller must call save()
  Note completeFor(ActorId actorId) {
    // Start with current note
    Note updated = this;

    // Remove Tag.now if the actor has it
    if (hasTag(Tag.now, actorId)) {
      updated = updated.toggleTag(Tag.now, actorId);
    }

    // Add Tag.done if the actor doesn't have it
    if (!updated.hasTag(Tag.done, actorId)) {
      updated = updated.toggleTag(Tag.done, actorId);
    }

    return updated;
  }

  /// Toggle a tag for a specific actor
  /// Returns a new Note instance with the updated tag - caller must call save()
  Note toggleTag(Tag tag, ActorId actorId) {
    final hasIt = hasTag(tag, actorId);
    final add = !hasIt;

    // Get current tags or create empty map
    Map<Tag, List<ActorId>> currentTags = _tags?.tags != null
        ? Map<Tag, List<ActorId>>.from(_tags!.tags!)
        : {};

    // Get current tag updates or create empty map
    Map<int, bool> currentTagUpdates = _tags?.tagsUpdated != null
        ? Map<int, bool>.from(_tags!.tagsUpdated!)
        : {};

    if (add) {
      // Add actor to tag
      currentTags.putIfAbsent(tag, () => []);
      if (!currentTags[tag]!.contains(actorId)) {
        currentTags[tag]!.add(actorId);
      }
    } else {
      // Remove actor from tag
      if (currentTags[tag] != null) {
        currentTags[tag]!.remove(actorId);
        if (currentTags[tag]!.isEmpty) {
          currentTags.remove(tag);
        }
      }
    }

    // Track which tag changed
    currentTagUpdates[tag.id] = add;

    // Create new tags row with updated data
    final newTags = _tags?.copyWith(
      updatedAt: DateTime.now(),
      tags: Value(currentTags.isEmpty ? null : currentTags),
      tagsUpdated: Value(currentTagUpdates),
    ) ?? NoteTagsRow(
      id: id,
      updatedAt: DateTime.now(),
      tags: currentTags.isEmpty ? null : currentTags,
      tagsUpdated: currentTagUpdates.isEmpty ? null : currentTagUpdates,
    );

    // Return new Note instance with modified tags
    return Note._fromStore(
      noteRow: toRow(),
      tags: newTags,
    );
  }

  /// Extract mention UUIDs from markdown text.
  /// Mentions are markdown links in the format: [Name](#@UUID)
  static List<ActorId> _extractMentionsFromMarkdown(String markdown) {
    final mentions = <ActorId>[];
    final mentionPattern = RegExp(
      r'\[([^\]]+)\]\(#@([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)',
    );

    final matches = mentionPattern.allMatches(markdown);

    for (final match in matches) {
      final uuidString = match.group(2);
      if (uuidString != null) {
        try {
          final uuid = ActorId.fromString(uuidString);
          mentions.add(uuid);
        } catch (e) {
          // Skip invalid UUIDs
          log.warning('Invalid UUID in mention: $uuidString');
        }
      }
    }

    return mentions;
  }

  Note copyWith({
    ActivityId? activityId,
    bool? draft,
    bool? private,
    String? content,
    List<Link>? links,
    List<ActorId>? mentions,
    NoteTagsRow? tags,
  }) {
    final now = DateTime.now();

    // Auto-extract mentions from content if content is provided but mentions are not
    final effectiveMentions =
        mentions ??
        (content != null
            ? _extractMentionsFromMarkdown(content)
            : this.mentions);

    return Note._fromStore(
      noteRow: NoteRow(
        id: id,
        activityId: activityId ?? this.activityId,
        authorId: authorId,
        draft: draft ?? this.draft,
        private: private ?? this.private,
        content: content ?? this.content,
        links: links ?? this.links,
        mentions: effectiveMentions,
        createdAt: draft == false && this.draft ? now : createdAt,
        updatedAt: DateTime.now(),
        archivedAt: archivedAt,
      ),
      tags: tags ?? _tags,
    );
  }

  @override
  List<Object?> get props => [
    id,
    activityId,
    authorId,
    draft,
    private,
    content,
    links,
    mentions,
    createdAt,
    updatedAt,
    archivedAt,
    _tags,
  ];

  @override
  int compareTo(Note other) {
    return createdAt.compareTo(other.createdAt);
  }
}
