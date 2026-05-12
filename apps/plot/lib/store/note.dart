part of 'store.dart';

typedef NoteId = Uuid;

@DataClassName('NoteRow')
class Notes extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get threadId => blob().map(const UuidConverter())();
  BlobColumn get authorId => blob().map(const ActorIdConverter())();
  TextColumn get accessContacts => text().nullable().map(const ActorIdListConverter())();

  TextColumn get content => text().nullable()();
  DateTimeColumn get sourceCreatedAt =>
      dateTime().map(const LocalDateTimeConverter())();
  TextColumn get actions => text().nullable().map(const UserActionsConverter())();
  TextColumn get mentions =>
      text().nullable().map(const ActorIdListConverter())();
  BlobColumn get reNoteId => blob().nullable().map(const UuidConverter())();
  BlobColumn get mergedFromThreadId => blob().nullable().map(const UuidConverter())();
}

class NotesBase extends BaseTable {
  NotesBase({this.threadId})
    : super(
        table: 'user_note',
        syncEndpoint: 'notes',
        name: "notes",
        filterName: threadId?.toString(),
        ascending: true, // Order by created_at ascending within an activity
      );

  final ThreadId? threadId;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      lastHorizon: lastHorizon,
      pageSeq: pageSeq,
      pageId: pageId,
      initial: initial,
      archived: archived,
    );
    if (threadId != null) {
      params['thread_id'] = threadId.toString();
    }
    return params;
  }

  @override
  Insertable<NoteRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id');
    return NoteRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // The client sets author_id correctly to Base.actorId (contact ID)
    // Do NOT remove - the sync API needs it to set the correct author

    return json;
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final noteRow = row as NoteRow;
      final local = await (store.select(store.notes)
            ..where((t) => t.id.equals(noteRow.id.toBytes())))
          .getSingleOrNull();
      if (local != null && local.pending != null) {
        // Local has pending changes — don't overwrite with remote data
        continue;
      }
      result.add(row);
    }
    return result;
  }
}

class Note extends Equatable implements Comparable<Note> {
  factory Note({
    required NoteId id,
    required ThreadId threadId,
    required ActorId authorId,
    required bool draft,
    List<ActorId>? accessContacts,
    String? content,
    List<UserAction>? actions,
    List<ActorId>? mentions,
    NoteId? reNoteId,
    required DateTime createdAt,
    required DateTime sourceCreatedAt,
    required DateTime updatedAt,
    DateTime? archivedAt,
    ThreadId? mergedFromThreadId,
  }) {
    // Auto-extract mentions from content if content is provided but mentions are not
    final effectiveMentions =
        mentions ??
        (content != null ? _extractMentionsFromMarkdown(content) : null);

    return Note._internal(
      id: id,
      threadId: threadId,
      authorId: authorId,
      draft: draft,
      accessContacts: accessContacts,
      content: content,
      sourceCreatedAt: sourceCreatedAt,
      actions: actions,
      mentions: effectiveMentions,
      reNoteId: reNoteId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt,
      mergedFromThreadId: mergedFromThreadId,
      tags: null,
    );
  }

  Note.draft({required this.threadId})
    : draft = true,
      accessContacts = null,
      id = NoteId.generate(),
      authorId = Base.actorId,
      content = null,
      actions = null,
      mentions = null,
      reNoteId = null,
      createdAt = DateTime.now(),
      sourceCreatedAt = DateTime.now(),
      updatedAt = DateTime.now(),
      archivedAt = null,
      mergedFromThreadId = null,
      _tags = null;

  const Note._internal({
    required this.id,
    required this.threadId,
    required this.authorId,
    required this.draft,
    this.accessContacts,
    this.content,
    this.actions,
    this.mentions,
    this.reNoteId,
    required this.createdAt,
    required this.sourceCreatedAt,
    required this.updatedAt,
    this.archivedAt,
    this.mergedFromThreadId,
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
      threadId: noteRow.threadId,
      authorId: noteRow.authorId,
      draft: noteRow.draft,
      accessContacts: noteRow.accessContacts,
      content: noteRow.content,
      sourceCreatedAt: noteRow.sourceCreatedAt,
      actions: noteRow.actions,
      mentions: effectiveMentions,
      reNoteId: noteRow.reNoteId,
      createdAt: noteRow.createdAt,
      updatedAt: noteRow.updatedAt,
      archivedAt: noteRow.archivedAt,
      mergedFromThreadId: noteRow.mergedFromThreadId,
      tags: tags,
    );
  }

  final Uuid id;
  final ThreadId threadId;
  final ActorId authorId;
  final bool draft;
  final List<ActorId>? accessContacts;
  bool get isPrivate => accessContacts != null;
  bool get isAuthorOnly => accessContacts != null && accessContacts!.isEmpty;

  /// Whether this note's effective contacts (author + accessContacts) exactly
  /// match the thread's contacts — meaning everyone on the thread can see it,
  /// so showing a private icon would be misleading.
  bool matchesThreadContacts(List<Uuid>? threadContacts) {
    if (!isPrivate || threadContacts == null) return !isPrivate;
    final noteUuids = <Uuid>{authorId.value, ...?accessContacts?.map((c) => c.value)};
    final threadSet = threadContacts.toSet();
    return noteUuids.length == threadSet.length &&
        noteUuids.containsAll(threadSet);
  }

  final String? content;
  final List<UserAction>? actions;
  final List<ActorId>? mentions;
  final NoteId? reNoteId;
  final DateTime createdAt;
  final DateTime sourceCreatedAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final ThreadId? mergedFromThreadId;
  final NoteTagsRow? _tags;

  /// Pull all notes and tags for a specific activity (lazy-loaded on first view).
  /// Tracked in SyncStates as "notes:{threadId}".
  static Future<void> pullForActivity(ThreadId threadId) async {
    // Pull all notes for this activity (first time only)
    await Store.get.pull(
      Store.get.notes,
      NotesBase(threadId: threadId),
      initial: true,
    );

    // Pull all note tags (unfiltered - Drift filters locally based on available notes)
    // We use the threadId in the BaseTable just for sync state tracking
    await Store.get.pull(
      Store.get.noteTags,
      NoteTagsBase(threadId: threadId),
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

  /// Get all notes for a thread (one-shot query with tags).
  static Future<List<Note>> getForThread(
    ThreadId threadId, {
    bool? draft = false,
  }) async {
    final n = Store.get.notes;
    final tags = Store.get.alias(Store.get.noteTags, 'tags');

    var query =
        Store.get.select(n).join([leftOuterJoin(tags, tags.id.equalsExp(n.id))])
          ..where(n.threadId.equalsValue(threadId))
          ..where(n.archivedAt.isNull())
          ..addColumns([tags.tags]);

    if (draft != null) {
      query.where(n.draft.equals(draft));
    }

    final results = await query.get();
    final noteGroups = <Uuid, List<TypedResult>>{};
    for (final result in results) {
      final noteRow = result.readTable(n);
      noteGroups.putIfAbsent(noteRow.id, () => []).add(result);
    }

    return noteGroups.values.map((group) {
      final noteRow = group.first.readTable(n);
      final tagsRow = group.first.readTableOrNull(tags);
      return Note._fromStore(noteRow: noteRow, tags: tagsRow);
    }).toList();
  }

  /// Get a single note by ID with its tags
  static Future<Note?> get(NoteId id) async {
    final n = Store.get.notes;
    final tags = Store.get.alias(Store.get.noteTags, 'tags');

    final query =
        Store.get.select(n).join([leftOuterJoin(tags, tags.id.equalsExp(n.id))])
          ..where(n.id.equalsValue(id))
          ..addColumns([tags.tags])
          ..limit(1);

    final results = await query.get();
    if (results.isEmpty) return null;

    final noteRow = results.first.readTable(n);
    final tagsRow = results.first.readTableOrNull(tags);
    return Note._fromStore(noteRow: noteRow, tags: tagsRow);
  }

  /// Helper to ensure notes are loaded for an activity before watching.
  /// Triggers pullForActivity if this is the first time viewing the activity.
  static void _ensureNotesLoadedForActivity(ThreadId threadId) {
    final entity = "notes:$threadId";

    // Check if we've already loaded notes for this activity (async, don't block)
    (Store.get.select(Store.get.syncStates)
          ..where((s) => s.entity.equals(entity)))
        .getSingleOrNull()
        .then((SyncState? syncState) {
          if (syncState == null) {
            // Never loaded notes for this activity - trigger pull in background
            log.info('First time viewing activity $threadId, pulling notes');
            pullForActivity(threadId).catchError((Object e) {
              log.warning('Failed to pull notes for activity $threadId: $e');
            });
          }
        });
  }

  static Stream<List<Note>> watch(
    ThreadId threadId, {
    bool? archived = false,
    bool? draft = false,
    List<Tag>? filter,
    NoteId? threadNoteId,
  }) {
    // Check if notes for this activity have been loaded, if not trigger pull
    _ensureNotesLoadedForActivity(threadId);

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
        NotesBase(threadId: threadId),
      );
    }

    final n = Store.get.notes;
    final tags = Store.get.alias(Store.get.noteTags, 'tags');

    // Build query with joins
    var query =
        Store.get.select(n).join([leftOuterJoin(tags, tags.id.equalsExp(n.id))])
          ..where(n.threadId.equalsValue(threadId))
          ..orderBy([OrderingTerm.desc(n.sourceCreatedAt)])
          ..addColumns([tags.tags]);

    // Filter by archived status if archived parameter is provided
    if (archived != null) {
      query.where(archived ? n.archivedAt.isNotNull() : n.archivedAt.isNull());
    }

    // Filter by draft status if draft parameter is provided
    if (draft != null) {
      query.where(n.draft.equals(draft));
    }

    // Filter to thread: show the root note and all its replies
    if (threadNoteId != null) {
      query.where(
        n.id.equalsValue(threadNoteId) | n.reNoteId.equalsValue(threadNoteId),
      );
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

  /// Watch the count of non-draft notes for a thread.
  /// Lightweight alternative to [watch] when only the count is needed.
/// Watch all tags present in an activity and its notes.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForActivity(ThreadId threadId) {
    final at = Store.get.threadTags;
    final nt = Store.get.noteTags;
    final n = Store.get.notes;

    // Query for activity tags
    final threadTagsQuery = Store.get.select(at)
      ..where((t) => t.id.equalsValue(threadId));

    // Query for note tags belonging to this activity
    final noteTagsQuery = Store.get.select(nt).join([
      innerJoin(n, n.id.equalsExp(nt.id) & n.archivedAt.isNull()),
    ])..where(n.threadId.equalsValue(threadId));

    // COUNT query for stored Tag.archived on notes (notes with archived tag, not archivedAt)
    final noteArchivedQuery = Store.get.selectOnly(n)
      ..addColumns([n.id.count()])
      ..where(n.threadId.equalsValue(threadId) & n.archivedAt.isNull());

    final noteArchivedCountStream = noteArchivedQuery
        // Map the single result row to the count value.
        .map((row) => row.read(n.id.count()))
        // Use watchSingle() to get a Stream<T> for a single result.
        .watchSingle();

    return Rx.combineLatest3(
      threadTagsQuery.watch(),
      noteTagsQuery.watch(),
      noteArchivedCountStream,
      (
        List<ThreadTagsRow> threadTagRows,
        List<TypedResult> noteTagResults,
        int? noteArchivedCount,
      ) {
        final Map<Tag, int> tagCounts = {};
        final Map<Tag, Set<Uuid>> storedTagCounts = {};

        // Count tags from the activity itself
        for (final activityTagsRow in threadTagRows) {
          final tags = activityTagsRow.tags;
          if (tags != null) {
            for (final tag in tags.keys) {
              // Skip computed tags here - we'll add them separately below
              if (tag != Tag.archived) {
                storedTagCounts.putIfAbsent(tag, () => {}).add(threadId);
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
  static Future<Note?> getDraftByActivity(ThreadId threadId) async {
    final n = Store.get.notes;
    final query = Store.get.select(n)
      ..where((tbl) => tbl.threadId.equalsValue(threadId))
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
      threadId: threadId,
      authorId: authorId,
      draft: draft,
      accessContacts: accessContacts,
      content: content,
      sourceCreatedAt: sourceCreatedAt,
      actions: actions,
      mentions: mentions,
      reNoteId: reNoteId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt,
      mergedFromThreadId: mergedFromThreadId,
    );
  }

  Future<void> save({bool pushToRemote = true, bool skipReplyPropagation = false}) async {
    // Save note row to local DB
    await Store.get.add(Store.get.notes, toRow().toCompanion(false));

    // Save tags row if present (local only - orchestrator will push in correct order)
    if (_tags != null) {
      await Store.get.add(Store.get.noteTags, _tags.toCompanion(false));
    }

    // Skip thread-level side effects for draft notes — these will run when
    // the note is published (draft → non-draft).
    if (!draft) {
      // Note todo → thread todo propagation:
      // When Tag.todo is added to a note for the current user, ensure a per-user
      // schedule exists on the thread (makes the thread appear on the user's todo list).
      if (hasTag(Tag.todo, Base.actorId)) {
        await _ensureTodoForUser(threadId, Base.userId);
      }

      // Recompute outstandingTasks on the per-user schedule when todo/done tags change
      if (_tags?.tagsUpdated != null) {
        final todoId = Tag.todo.id.toString();
        final doneId = Tag.done.id.toString();
        final hasTodoChange = _tags!.tagsUpdated!.keys.any(
          (k) => k == todoId || k.startsWith('$todoId:') ||
                 k == doneId || k.startsWith('$doneId:'),
        );
        if (hasTodoChange) {
          await _recomputeOutstandingTasks(threadId, Base.userId);
        }
      }

      // Reply tag propagation: note → thread
      if (!skipReplyPropagation) {
        final replyUpdated = _tags?.tagsUpdated?[Tag.reply.id.toString()];
        if (replyUpdated == true) {
          // Reply added to note → ensure reply exists on thread
          await _ensureReplyOnThread(threadId);
        } else if (replyUpdated == false) {
          // Reply removed from note → remove from thread if no other notes have it
          await _removeReplyFromThreadIfNoneLeft(threadId);
        }
      }
    }

    // Update thread's lastNoteCreatedAt/lastNoteSourceCreatedAt locally
    // (only for non-draft notes). Uses update().write() so the thread row is
    // NOT marked pending for remote sync — the server trigger handles that.
    if (!draft && archivedAt == null) {
      await (Store.get.update(Store.get.threads)
            ..where((a) => a.id.equalsValue(threadId)))
          .write(ThreadsCompanion(
            lastNoteCreatedAt: Value(createdAt),
            lastNoteSourceCreatedAt: Value(sourceCreatedAt),
          ));
    }

    // Push to remote eagerly. We previously deferred this to Priority.idle
    // to yield CPU to in-flight nav transitions, but under load the idle
    // slot could be starved with no retry, leaving notes stuck at
    // pending=2 until the app restarted.
    if (pushToRemote) {
      unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));
    }
  }

  /// Ensures a per-user schedule exists on the thread for the given user.
  /// Creates one if it doesn't exist, unarchives if it was archived.
  static Future<void> _ensureTodoForUser(ThreadId threadId, Uuid userId) async {
    final existing = await (Store.get.select(Store.get.schedules)
      ..where((s) => s.threadId.equalsValue(threadId) &
                     s.userId.equalsValue(userId) &
                     s.occurrence.isNull()))
        .getSingleOrNull();
    if (existing == null) {
      // Create per-user schedule (no at/on = current and ongoing todo)
      final newSchedule = ScheduleRow(
        id: Uuid.generate(),
        updatedAt: DateTime.now(),
        threadId: threadId,
        userId: userId,
        startOn: Thread.todoNowDate,
        order: Order.first(),
        outstandingTasks: true,
      );
      await Store.get.save(
        Store.get.schedules,
        newSchedule.toCompanion(false),
        SchedulesBase(),
      );
    } else if (existing.archivedAt != null) {
      // Unarchive existing schedule (re-add to todo)
      await Store.get.save(
        Store.get.schedules,
        existing.copyWith(
          archivedAt: const Value(null),
          updatedAt: DateTime.now(),
          startOn: existing.startOn == null ? Value(Thread.todoNowDate) : const Value.absent(),
          outstandingTasks: true,
        ).toCompanion(false),
        SchedulesBase(),
      );
    }
  }

  /// Ensures the reply tag exists on the thread for the current user.
  static Future<void> _ensureReplyOnThread(ThreadId threadId) async {
    final thread = await Thread.getOne(threadId);
    final hasReply = thread.hasTag(Tag.reply, actorId: Base.actorId);
    if (!hasReply) {
      await thread.toggleTag(Tag.reply).save();
    }
  }

  /// Removes the reply tag from the thread if no other notes have it for the current user.
  static Future<void> _removeReplyFromThreadIfNoneLeft(ThreadId threadId) async {
    final notes = await Note.getForThread(threadId);
    final anyReply = notes.any(
      (n) => n.hasTag(Tag.reply, Base.actorId) && n.archivedAt == null,
    );
    if (!anyReply) {
      final thread = await Thread.getOne(threadId);
      final hasReply = thread.hasTag(Tag.reply, actorId: Base.actorId);
      if (hasReply) {
        await thread.toggleTag(Tag.reply).save();
      }
    }
  }

  /// Recomputes the outstandingTasks flag on the per-user schedule for a thread.
  static Future<void> _recomputeOutstandingTasks(ThreadId threadId, Uuid userId) async {
    final hasOutstanding = await _checkOutstandingTasks(threadId);
    final schedule = await (Store.get.select(Store.get.schedules)
      ..where((s) => s.threadId.equalsValue(threadId) &
                     s.userId.equalsValue(userId) &
                     s.occurrence.isNull()))
        .getSingleOrNull();
    if (schedule != null && schedule.outstandingTasks != hasOutstanding) {
      await Store.get.save(
        Store.get.schedules,
        schedule.copyWith(outstandingTasks: hasOutstanding, updatedAt: DateTime.now()).toCompanion(false),
        SchedulesBase(),
      );
    }
  }

  /// Checks if a thread has outstanding tasks for the current user.
  static Future<bool> _checkOutstandingTasks(ThreadId threadId) async {
    final actorId = Base.actorId;
    // Check notes with active todo tag
    final notes = await Note.getForThread(threadId);
    if (notes.any((n) => n.hasTag(Tag.todo, actorId))) return true;
    // Check links assigned to user (or unassigned) with non-done status
    final links = await Link.getForThread(threadId);
    for (final link in links) {
      if (link.assigneeId != null &&
          !Actor.sameIdentity(link.assigneeId!, actorId)) {
        continue;
      }
      final doneStatuses =
          link.getTypeConfig()?.statuses?.where((s) => s.done) ?? [];
      if (doneStatuses.isEmpty) continue;
      if (!doneStatuses.any((s) => s.status == link.status)) return true;
    }
    return false;
  }

  Future<void> archive() => copyWith(archivedAt: Value(DateTime.now())).save();

  // Tag-related getters
  //
  // Each tag's actor list is deduped by canonical identity: linked-contact
  // aliases (multiple email contacts for the same user) collapse to the
  // user's primary actor id. The raw `note_tag` rows can target any
  // linked-contact alias; collapsing here gives the rest of the app a
  // stable per-user view.
  Map<Tag, List<ActorId>> get tags => {
    if (isPrivate) Tag.private: [authorId],
    for (final entry in (_tags?.tags ?? const {}).entries)
      entry.key: Actor.dedupeByIdentity(entry.value),
  };

  /// Get all actors who have Tag.todo or Tag.done on this note (i.e., assignees).
  ///
  /// Only includes actors whose identity the viewer is allowed to see —
  /// announce-topic-only assignees are filtered out by the API. Use
  /// [assigneeCount] for the true total.
  List<ActorId> get assignees {
    final actors = <ActorId>{};
    if (tags[Tag.todo] != null) actors.addAll(tags[Tag.todo]!);
    if (tags[Tag.done] != null) actors.addAll(tags[Tag.done]!);
    return actors.toList();
  }

  /// Total number of distinct assignees, including any hidden by privacy
  /// filtering (announce-topic-only members the viewer can't see).
  int get assigneeCount {
    final activeTotal = TagActors.countOf(tags[Tag.todo]);
    final doneTotal = TagActors.countOf(tags[Tag.done]);
    final activeVisible = tags[Tag.todo] ?? const [];
    final doneVisible = tags[Tag.done] ?? const [];
    final visibleOverlap = doneVisible
        .where(activeVisible.contains)
        .length;
    final visibleUnion = activeVisible.length + doneVisible.length - visibleOverlap;
    final hiddenActive = activeTotal - activeVisible.length;
    final hiddenDone = doneTotal - doneVisible.length;
    // Hidden actors may overlap between todo/done. Without identities we
    // can't dedupe them, so assume worst case (no overlap) for the count.
    return visibleUnion + hiddenActive + hiddenDone;
  }

  /// Get actors currently working on this note (have Tag.todo)
  List<ActorId> get activeAssignees => tags[Tag.todo] ?? const [];

  /// Get actors who have completed this note (have Tag.done)
  List<ActorId> get completedAssignees => tags[Tag.done] ?? const [];

  Future<Note> refresh() async {
    return await Note.get(id) ?? this;
  }

  /// Check if all assignees have marked the note as done.
  ///
  /// Returns false when there are still active todo assignees, including
  /// hidden ones (announce-topic-only) — we can't claim completion on
  /// behalf of assignees we can't see.
  bool get isComplete {
    if (TagActors.countOf(tags[Tag.todo]) > 0) return false;
    if (TagActors.countOf(tags[Tag.done]) == 0) return false;
    return true;
  }

  /// Check if a specific actor has a given tag.
  ///
  /// Linked-contact aliases are equivalent to their primary, so a tag set
  /// for any of a user's linked contacts counts as set for any other one.
  bool hasTag(Tag tag, [ActorId? actorId]) {
    if (tag == Tag.private) return isPrivate;
    final actors = tags[tag];
    if (actorId == null) {
      return actors?.isNotEmpty == true;
    }
    if (actors == null) return false;
    final canonical = Actor.canonicalId(actorId);
    return actors.any((id) => Actor.canonicalId(id) == canonical);
  }

  /// Check if a specific actor is assigned to this note (has Tag.todo)
  bool isAssignedTo(ActorId actorId) => hasTag(Tag.todo, actorId);
  bool isAssigned() => hasTag(Tag.todo);

  /// Check if a specific actor has completed this note (has Tag.done)
  bool isCompletedBy(ActorId actorId) => hasTag(Tag.done, actorId);

  /// Get actor names for a tag, formatted for display in tooltips
  /// Returns a formatted string like "You, Alice, Bob" or "You, Alice, Bob + 2 more"
  Future<String> getTagActorNames(Tag tag) async {
    final actorIds = tags[tag];
    if (actorIds == null || actorIds.isEmpty) {
      return '';
    }

    final hiddenCount = actorIds is TagActors
        ? actorIds.count - actorIds.length
        : 0;

    return Note._formatActorNames(actorIds, hiddenCount: hiddenCount);
  }

  /// Get the author name formatted for display
  /// Returns "You" for current user or the actor's name
  Future<String> getAuthorName() async {
    return Note._formatActorNames([authorId]);
  }

  /// Get the full Author actor for display (name, email, etc.)
  Future<Actor?> getAuthor() async {
    try {
      return await Actor.getOne(authorId);
    } catch (_) {
      return null;
    }
  }

  /// Helper to format a list of actorIds into a display string
  /// - Replaces current user with "You"
  /// - Shows first 3 names + count if more exist
  static Future<String> _formatActorNames(
    List<ActorId> actorIds, {
    int hiddenCount = 0,
  }) async {
    // Collapse linked-contact aliases so a user with multiple email
    // addresses appears once.
    actorIds = Actor.dedupeByIdentity(actorIds);
    if (actorIds.isEmpty && hiddenCount == 0) return '';

    // Fetch actor names from the database
    final actorRows =
        await (Store.get.select(Store.get.actors)..where(
              (a) => a.id.isIn(actorIds.map((id) => id.toBytes()).toList()),
            ))
            .get();

    // Convert to Actor objects and create a map of actorId to nameOrEmail
    final actors = actorRows.map((row) => Actor.fromStore(row)).toList();
    final actorMap = {for (var actor in actors) actor.id: actor.nameOrEmail};

    // Build the display names list
    final displayNames = <String>[];

    for (final actorId in actorIds) {
      if (actorId.isCurrentUser) {
        displayNames.insert(0, 'You'); // Put "You" first
      } else {
        final name = actorMap[actorId] ?? 'Unknown';
        if (!actorMap.containsKey(actorId)) {
          log.warning('Actor not found in local DB: $actorId');
        }
        displayNames.add(name);
      }
    }

    // Format the output
    final totalExtra = (displayNames.length > 3 ? displayNames.length - 3 : 0) + hiddenCount;
    if (totalExtra == 0) {
      return displayNames.join(', ');
    } else {
      final first3 = displayNames.take(3).join(', ');
      return '$first3 + $totalExtra more';
    }
  }

  // Tag manipulation methods

  /// Assign this note to an actor by adding Tag.todo
  /// Returns a new Note instance with the tag added - caller must call save()
  Note assignTo(ActorId actorId) {
    // Only add Tag.todo if the actor doesn't already have it
    if (!hasTag(Tag.todo, actorId)) {
      return toggleTag(Tag.todo, actorId);
    }
    return this;
  }

  /// Mark this note as complete for an actor by replacing Tag.todo with Tag.done
  /// Returns a new Note instance with tags updated - caller must call save()
  Note completeFor(ActorId actorId) {
    // Start with current note
    Note updated = this;

    // Remove Tag.todo if the actor has it
    if (hasTag(Tag.todo, actorId)) {
      updated = updated.toggleTag(Tag.todo, actorId);
    }

    // Add Tag.done if the actor doesn't have it
    if (!updated.hasTag(Tag.done, actorId)) {
      updated = updated.toggleTag(Tag.done, actorId);
    }

    return updated;
  }

  /// Sets or unsets a tag for a specific actor.
  /// Returns a new Note instance with the updated tag - caller must call save().
  Note setTag(Tag tag, ActorId actorId, [bool value = true]) {
    // Handle compute tags that map to direct fields.
    // Private notes must include the toggling user in accessContacts — an
    // empty array hides the note from everyone unless created_by matches
    // the viewer's user_id (not true for twist-created notes like emails).
    if (tag == Tag.private) {
      return copyWith(accessContacts: Value(value ? [actorId] : null));
    }

    // Resolve the target to its canonical (primary) actor id and treat
    // linked-contact aliases as equivalent to the canonical for both the
    // self-check and the local optimistic state.
    final canonicalActorId = Actor.canonicalId(actorId);

    // Count tags can only be set for the current user (any linked alias).
    if (tag.type == TagType.count &&
        !Actor.sameIdentity(actorId, Base.actorId)) {
      log.warning(
        'Attempted to set count tag ${tag.name} for actor $actorId, but only current user can modify count tags',
      );
      // Return unchanged note - don't allow modifying other users' count tags
      return this;
    }

    // Get current tags or create empty map
    Map<Tag, List<ActorId>> currentTags = _tags?.tags != null
        ? Map<Tag, List<ActorId>>.from(_tags!.tags!)
        : {};

    // Get current tag updates or create empty map
    Map<String, bool> currentTagUpdates = _tags?.tagsUpdated != null
        ? Map<String, bool>.from(_tags!.tagsUpdated!)
        : {};

    if (value) {
      // Add the canonical actor if no linked-alias entry already covers it.
      currentTags.putIfAbsent(tag, () => []);
      final hasIdentity = currentTags[tag]!.any(
        (id) => Actor.canonicalId(id) == canonicalActorId,
      );
      if (!hasIdentity) {
        currentTags[tag]!.add(canonicalActorId);
      }
    } else {
      // Remove every entry that resolves to the same identity — clearing
      // a tag for a user clears it for all of their linked-contact aliases.
      if (currentTags[tag] != null) {
        currentTags[tag]!.removeWhere(
          (id) => Actor.canonicalId(id) == canonicalActorId,
        );
        if (currentTags[tag]!.isEmpty) {
          currentTags.remove(tag);
        }
      }
    }

    // Track which tag changed. Use the canonical actor id in the composite
    // key so the server stores the row against the user's current primary
    // contact. The DB function (update_note_tags) sibling-expands the
    // target on both writes and clears.
    final tagKey = Actor.sameIdentity(actorId, Base.actorId)
        ? tag.id.toString()
        : '${tag.id}:$canonicalActorId';
    currentTagUpdates[tagKey] = value;

    // Create new tags row with updated data
    final newTags =
        _tags?.copyWith(
          updatedAt: DateTime.now(),
          tags: Value(currentTags.isEmpty ? null : currentTags),
          tagsUpdated: Value(currentTagUpdates),
        ) ??
        NoteTagsRow(
          id: id,
          updatedAt: DateTime.now(),
          tags: currentTags.isEmpty ? null : currentTags,
          tagsUpdated: currentTagUpdates.isEmpty ? null : currentTagUpdates,
        );

    // Return new Note instance with modified tags
    return Note._fromStore(noteRow: toRow(), tags: newTags);
  }

  /// Toggles a tag for a specific actor.
  /// Returns a new Note instance with the updated tag - caller must call save().
  Note toggleTag(Tag tag, ActorId actorId) {
    final hasIt = hasTag(tag, actorId);
    return setTag(tag, actorId, !hasIt);
  }

  /// Extract mention UUIDs from markdown text.
  /// Mentions are markdown links in the format: [Name](#@UUID)
  static List<ActorId> _extractMentionsFromMarkdown(String markdown) {
    final mentions = <ActorId>[];
    // Regex matches [Name](#@UUID). Group 1 is name, Group 2 is UUID.
    final mentionPattern = RegExp(
      r'\[([^\]]+)\]\(#@([0-9a-fA-F-]{32,36})\)',
    );

    final matches = mentionPattern.allMatches(markdown);

    for (final match in matches) {
      final uuidString = match.group(2); // Group 2 is the UUID
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
    ThreadId? threadId,
    bool? draft,
    Value<List<ActorId>?> accessContacts = const Value.absent(),
    String? content,
    List<UserAction>? actions,
    List<ActorId>? mentions,
    List<ActorId>? addMentions,
    NoteId? reNoteId,
    bool clearReNoteId = false,
    NoteTagsRow? tags,
    Value<DateTime?> archivedAt = const Value.absent(),
    bool clearArchivedAt = false,
    Value<ThreadId?> mergedFromThreadId = const Value.absent(),
  }) {
    final now = DateTime.now();

    // Auto-extract mentions from content if content is provided but mentions are not
    var effectiveMentions =
        mentions ??
        (content != null
            ? _extractMentionsFromMarkdown(content)
            : this.mentions);

    // Merge additional mentions (e.g. thread twist mentions) with deduplication
    if (addMentions != null && addMentions.isNotEmpty) {
      final merged = <ActorId>{...?effectiveMentions, ...addMentions};
      effectiveMentions = merged.toList();
    }

    // Detect publishing (draft → non-draft) and add Twisting tag for twist mentions
    NoteTagsRow? effectiveTags = tags ?? _tags;
    final isPublishing = draft == false && this.draft;
    if (isPublishing &&
        effectiveMentions != null &&
        effectiveMentions.isNotEmpty) {
      for (final mentionId in effectiveMentions) {
        if (mentionId.isTwist) {
          // Build updated tags
          Map<Tag, List<ActorId>> currentTags = effectiveTags?.tags != null
              ? Map<Tag, List<ActorId>>.from(effectiveTags!.tags!)
              : {};
          Map<String, bool> currentTagUpdates = effectiveTags?.tagsUpdated != null
              ? Map<String, bool>.from(effectiveTags!.tagsUpdated!)
              : {};

          // Add Twisting tag if not already present
          currentTags.putIfAbsent(Tag.twist, () => []);
          if (!currentTags[Tag.twist]!.contains(mentionId)) {
            currentTags[Tag.twist]!.add(mentionId);
            currentTagUpdates[Tag.twist.id.toString()] = true;
          }

          effectiveTags =
              effectiveTags?.copyWith(
                updatedAt: now,
                tags: Value(currentTags.isEmpty ? null : currentTags),
                tagsUpdated: Value(currentTagUpdates),
              ) ??
              NoteTagsRow(
                id: id,
                updatedAt: now,
                tags: currentTags.isEmpty ? null : currentTags,
                tagsUpdated: currentTagUpdates.isEmpty
                    ? null
                    : currentTagUpdates,
              );
        }
      }
    }

    return Note._fromStore(
      noteRow: NoteRow(
        id: id,
        threadId: threadId ?? this.threadId,
        authorId: authorId,
        draft: draft ?? this.draft,
        accessContacts: accessContacts.present ? accessContacts.value : this.accessContacts,
        content: content ?? this.content,
        sourceCreatedAt: isPublishing ? now : sourceCreatedAt,
        actions: actions ?? this.actions,
        mentions: effectiveMentions,
        reNoteId: clearReNoteId ? null : (reNoteId ?? this.reNoteId),
        createdAt: isPublishing ? now : createdAt,
        updatedAt: DateTime.now(),
        archivedAt: archivedAt.present ? archivedAt.value : (clearArchivedAt ? null : this.archivedAt),
        mergedFromThreadId: mergedFromThreadId.present ? mergedFromThreadId.value : this.mergedFromThreadId,
      ),
      tags: effectiveTags,
    );
  }

  @override
  List<Object?> get props => [
    id,
    threadId,
    authorId,
    draft,
    accessContacts,
    content,
    actions,
    mentions,
    reNoteId,
    createdAt,
    updatedAt,
    archivedAt,
    mergedFromThreadId,
    _tags,
  ];

  @override
  String toString() {
    String? contentPreview = content;
    if (contentPreview != null) {
      // Truncate at first newline or 50 characters, whichever comes first
      final newlineIndex = contentPreview.indexOf('\n');
      final truncateAt = newlineIndex >= 0 && newlineIndex < 50
          ? newlineIndex
          : 50;

      if (contentPreview.length > truncateAt) {
        contentPreview = '${contentPreview.substring(0, truncateAt)}...';
      }
    }
    return 'Note(id: $id, draft: $draft, content: $contentPreview, tags: ${tags.length})';
  }

  @override
  int compareTo(Note other) {
    return sourceCreatedAt.compareTo(other.sourceCreatedAt);
  }
}
