part of 'store.dart';

typedef NoteId = Uuid;

enum CtaKind { otp, confirm }

class Cta extends Equatable {
  const Cta({required this.kind, required this.service, this.code, this.url});

  final CtaKind kind;
  final String service;
  final String? code;
  final String? url;

  factory Cta.fromJson(Map<String, dynamic> json) => Cta(
        kind: json['kind'] == 'confirm' ? CtaKind.confirm : CtaKind.otp,
        service: json['service'] as String? ?? '',
        code: json['code'] as String?,
        url: json['url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind == CtaKind.confirm ? 'confirm' : 'otp',
        'service': service,
        'code': code,
        'url': url,
      };

  @override
  List<Object?> get props => [kind, service, code, url];
}

class CtaConverter extends TypeConverter<Cta?, String?>
    with JsonTypeConverter2<Cta?, String?, Map<String, dynamic>?> {
  const CtaConverter();

  @override
  Cta? fromSql(String? fromDb) =>
      fromDb == null ? null : Cta.fromJson(jsonDecode(fromDb) as Map<String, dynamic>);

  @override
  String? toSql(Cta? value) => value == null ? null : jsonEncode(value.toJson());

  @override
  Cta? fromJson(Map<String, dynamic>? json) =>
      json == null ? null : Cta.fromJson(json);

  @override
  Map<String, dynamic>? toJson(Cta? value) => value?.toJson();
}

/// Set by the runtime (never the client) when an outbound send / write-back of
/// this note failed and couldn't be recovered. Drives the "Failed to send"
/// affordance on the note. Cleared when a retry succeeds.
class DeliveryError extends Equatable {
  const DeliveryError({required this.code, this.message});

  /// Stable machine code, e.g. "rejected", "too_large", "rate_limited",
  /// "send_failed".
  final String code;

  /// User-safe reason to show beside "Failed to send", or null.
  final String? message;

  factory DeliveryError.fromJson(Map<String, dynamic> json) => DeliveryError(
        code: json['code'] as String? ?? 'send_failed',
        message: json['message'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
      };

  @override
  List<Object?> get props => [code, message];
}

class DeliveryErrorConverter extends TypeConverter<DeliveryError?, String?>
    with JsonTypeConverter2<DeliveryError?, String?, Map<String, dynamic>?> {
  const DeliveryErrorConverter();

  @override
  DeliveryError? fromSql(String? fromDb) => fromDb == null
      ? null
      : DeliveryError.fromJson(jsonDecode(fromDb) as Map<String, dynamic>);

  @override
  String? toSql(DeliveryError? value) =>
      value == null ? null : jsonEncode(value.toJson());

  @override
  DeliveryError? fromJson(Map<String, dynamic>? json) =>
      json == null ? null : DeliveryError.fromJson(json);

  @override
  Map<String, dynamic>? toJson(DeliveryError? value) => value?.toJson();
}

@DataClassName('NoteRow')
class Notes extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get threadId => blob().map(const UuidConverter())();
  BlobColumn get authorId => blob().map(const ActorIdConverter())();
  TextColumn get accessContacts => text().nullable().map(const ActorIdListConverter())();
  TextColumn get accessGroups => text().nullable().map(const ActorIdListConverter())();

  TextColumn get content => text().nullable()();
  DateTimeColumn get sourceCreatedAt =>
      dateTime().map(const LocalDateTimeConverter())();
  TextColumn get actions => text().nullable().map(const UserActionsConverter())();
  TextColumn get cta => text().nullable().map(const CtaConverter())();
  TextColumn get deliveryError =>
      text().nullable().map(const DeliveryErrorConverter())();
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
    List<ActorId>? accessGroups,
    String? content,
    List<UserAction>? actions,
    Cta? cta,
    DeliveryError? deliveryError,
    List<ActorId>? mentions,
    NoteId? reNoteId,
    required DateTime createdAt,
    required DateTime sourceCreatedAt,
    required DateTime updatedAt,
    DateTime? archivedAt,
    ThreadId? mergedFromThreadId,
    int? pending,
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
      accessGroups: accessGroups,
      content: content,
      sourceCreatedAt: sourceCreatedAt,
      actions: actions,
      cta: cta,
      deliveryError: deliveryError,
      mentions: effectiveMentions,
      reNoteId: reNoteId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt,
      mergedFromThreadId: mergedFromThreadId,
      pending: pending,
      tags: null,
    );
  }

  Note.draft({required this.threadId})
    : draft = true,
      accessContacts = null,
      accessGroups = null,
      id = NoteId.generate(),
      authorId = Base.actorId,
      content = null,
      actions = null,
      cta = null,
      deliveryError = null,
      mentions = null,
      reNoteId = null,
      createdAt = DateTime.now(),
      sourceCreatedAt = DateTime.now(),
      updatedAt = DateTime.now(),
      archivedAt = null,
      mergedFromThreadId = null,
      pending = null,
      _tags = null;

  const Note._internal({
    required this.id,
    required this.threadId,
    required this.authorId,
    required this.draft,
    this.accessContacts,
    this.accessGroups,
    this.content,
    this.actions,
    this.cta,
    this.deliveryError,
    this.mentions,
    this.reNoteId,
    required this.createdAt,
    required this.sourceCreatedAt,
    required this.updatedAt,
    this.archivedAt,
    this.mergedFromThreadId,
    this.pending,
    NoteTagsRow? tags,
    // ignore: prefer_initializing_formals
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
      accessGroups: noteRow.accessGroups,
      content: noteRow.content,
      sourceCreatedAt: noteRow.sourceCreatedAt,
      actions: noteRow.actions,
      cta: noteRow.cta,
      deliveryError: noteRow.deliveryError,
      mentions: effectiveMentions,
      reNoteId: noteRow.reNoteId,
      createdAt: noteRow.createdAt,
      updatedAt: noteRow.updatedAt,
      archivedAt: noteRow.archivedAt,
      mergedFromThreadId: noteRow.mergedFromThreadId,
      pending: noteRow.pending,
      tags: tags,
    );
  }

  final Uuid id;
  final ThreadId threadId;
  final ActorId authorId;
  final bool draft;
  final List<ActorId>? accessContacts;
  final List<ActorId>? accessGroups;
  bool get isPrivate {
    final ac = accessContacts;
    if (ac == null) return false;
    if (ac.length != 1) return false;
    if (ac.first != authorId) return false;
    final ag = accessGroups;
    return ag == null || ag.isEmpty;
  }
  bool get isAuthorOnly =>
      accessContacts != null && accessContacts!.isEmpty &&
      (accessGroups == null || accessGroups!.isEmpty);

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
  final Cta? cta;
  final DeliveryError? deliveryError;
  final List<ActorId>? mentions;
  final NoteId? reNoteId;
  final DateTime createdAt;
  final DateTime sourceCreatedAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final ThreadId? mergedFromThreadId;
  final int? pending;
  final NoteTagsRow? _tags;

  /// Pull this activity's notes, tags and reactions (lazy-loaded on first
  /// view). Tracked in SyncStates as "notes:{threadId}",
  /// "note_tags:{threadId}", "note_reactions:{threadId}".
  static Future<void> pullForActivity(ThreadId threadId) async {
    // A single combined request (GET /sync/thread-detail) fetches this thread's
    // notes, tags and reactions inside ONE server transaction — i.e. one DB
    // connection. On a cold connection the planner pays a large one-time cost
    // building the relcache for the heavily-indexed note/thread tables (~0.5–4s
    // measured on prod); folding the three pulls into one transaction pays that
    // once instead of up to three times across separate (possibly cold)
    // backends. This is the dominant cause of slow first-opens of a never-opened
    // thread. See docs/perf/thread-open-cold-planning.md.
    //
    // Each entity's envelope is then handed to its normal Store.pull as a
    // prefetched first page, so all the existing cursor/horizon/stamp/pagination
    // machinery (and the "notes:{threadId}" sync-state keys that gate re-pulls)
    // is reused unchanged.
    //
    // Fallback: if the combined endpoint is unavailable (older server) or
    // errors, the envelopes stay null and each Store.pull fetches its entity
    // over HTTP exactly as before — identical to the pre-fold behaviour. The
    // standalone /sync/notes, /sync/note-tags and /sync/note-reactions endpoints
    // remain for this fallback and for the global (non-thread) sync paths.
    Map<String, dynamic>? notesEnv;
    Map<String, dynamic>? tagsEnv;
    Map<String, dynamic>? reactionsEnv;
    try {
      final combined = await api.get<Map<String, dynamic>>(
        '/sync/thread-detail?thread_id=${Uri.encodeQueryComponent(threadId.toString())}&initial=true',
      );
      notesEnv = combined['notes'] as Map<String, dynamic>?;
      tagsEnv = combined['note_tags'] as Map<String, dynamic>?;
      reactionsEnv = combined['note_reactions'] as Map<String, dynamic>?;
    } catch (e) {
      // Older server without /sync/thread-detail, or a transient error — fall
      // back to the per-entity pulls below (prefetched stays null).
      log.fine('thread-detail combined pull unavailable; falling back', e);
    }

    await Future.wait([
      Store.get.pull(Store.get.notes, NotesBase(threadId: threadId),
          initial: true, prefetched: notesEnv),
      Store.get.pull(Store.get.noteTags, NoteTagsBase(threadId: threadId),
          initial: true, prefetched: tagsEnv),
      Store.get.pull(
        Store.get.noteReactions,
        NoteReactionsBase(threadId: threadId),
        initial: true,
        prefetched: reactionsEnv,
      ),
    ]);
  }

  /// Bounded initial pull of notes, tags and reactions. The server restricts
  /// the seq-cursor initial pull (seq=0, no thread_id) to unread/active
  /// threads — mirroring `Thread.pullInitial` — so a fresh device does NOT
  /// backfill the user's entire note history; historical threads load on
  /// demand via [pullForActivity]. The envelope's `next_horizon` seeds each
  /// cursor to "now", so subsequent [pullUpdates] are unfiltered incremental
  /// deltas. Tracked in SyncStates as "notes" / "note_tags" / "note_reactions".
  static Future<void> pullInitial() async {
    await Store.get.pull(Store.get.notes, NotesBase(), initial: true);
    await Store.get.pull(Store.get.noteTags, NoteTagsBase(), initial: true);
    await Store.get.pull(
      Store.get.noteReactions,
      NoteReactionsBase(),
      initial: true,
    );
  }

  /// Pull global updates for all notes, tags and reactions (updated since last
  /// sync). Unfiltered — fetches every visible delta with `seq >= horizon`, so
  /// a new note on a thread that just became unread/active is pulled in the
  /// same sync that surfaces the thread. Tracked in SyncStates as "notes".
  static Future<void> pullUpdates() async {
    await Store.get.pull(Store.get.notes, NotesBase());
    await Store.get.pull(Store.get.noteTags, NoteTagsBase());
    await Store.get.pull(Store.get.noteReactions, NoteReactionsBase());
  }

  /// Backfill notes (and tags/reactions) for every locally-unread or active
  /// thread that has no notes loaded yet, so opening it from Updates/Doing is
  /// instant. Complements [pullUpdates] (which catches the *new* note that
  /// surfaced a thread) by ensuring a never-before-loaded thread that becomes
  /// unread/active also has its full history ready on click.
  ///
  /// Bounded and idempotent: skips threads that already have local notes (the
  /// initial pull / a delta covered them) and threads already backfilled once
  /// (a "notes:{id}" sync state exists — so genuinely-empty threads aren't
  /// re-pulled every sync). Capped at [cap]; logs if truncated.
  static Future<void> ensureUnreadActiveThreadsLoaded({int cap = 50}) async {
    if (!Store.isAvailable) return;
    final store = Store.get;
    final t = store.threads;

    // Unread or active, non-archived threads — most recent first (by last
    // note time, the best column proxy for thread recency).
    final candidates =
        await (store.select(t)
              ..where(
                (row) =>
                    (row.unread.equals(true) | row.active.equals(true)) &
                    row.archivedAt.isNull(),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.lastNoteSourceCreatedAt),
              ]))
            .get();
    if (candidates.isEmpty) return;

    // Thread ids that already have at least one local note — skip them
    // (covered by the initial pull or an incremental delta).
    final withNotes = await (store.selectOnly(store.notes, distinct: true)
          ..addColumns([store.notes.threadId]))
        .map((row) => row.read(store.notes.threadId))
        .get();
    final withNotesSet = withNotes.whereType<ThreadId>().toSet();

    // Thread ids already backfilled once (a per-thread notes sync state
    // exists) — skip so genuinely-empty threads aren't re-pulled each sync.
    final loadedStates =
        await (store.select(store.syncStates)
              ..where((s) => s.entity.like('notes:%')))
            .get();
    final loadedSet = loadedStates
        .map((s) => s.entity.substring('notes:'.length))
        .toSet();

    final pending = <ThreadId>[];
    for (final thread in candidates) {
      if (withNotesSet.contains(thread.id)) continue;
      if (loadedSet.contains(thread.id.toString())) continue;
      pending.add(thread.id);
    }
    if (pending.isEmpty) return;

    var targets = pending;
    if (targets.length > cap) {
      log.info(
        'ensureUnreadActiveThreadsLoaded: ${targets.length} unread/active '
        'threads missing notes, capping to $cap (rest load on demand)',
      );
      targets = targets.sublist(0, cap);
    }

    // Bounded concurrency so a fresh device doesn't open dozens of requests
    // at once. Each pull is independent; swallow per-thread errors.
    const chunkSize = 5;
    for (var i = 0; i < targets.length; i += chunkSize) {
      final chunk = targets.sublist(
        i,
        (i + chunkSize).clamp(0, targets.length),
      );
      await Future.wait(
        chunk.map(
          (id) => pullForActivity(id).catchError((Object e) {
            log.warning('Failed to backfill notes for unread/active $id: $e');
          }),
        ),
      );
    }
  }

  /// Push pending changes for notes, note tags, and note reactions.
  static Future<bool> push() async {
    // Notes MUST land before their tags/reactions: the server's
    // note-tags/note-reactions RPCs reject rows whose note isn't persisted
    // yet ("Note not found"). Pushing all three in parallel raced a tag or
    // reaction on a brand-new note ahead of the note itself. Push notes
    // first, then tags + reactions in parallel (those two are independent).
    final notesOk = await Store.get.push(Store.get.notes, NotesBase());
    final childResults = await Future.wait([
      Store.get.push(Store.get.noteTags, NoteTagsBase()),
      Store.get.push(Store.get.noteReactions, NoteReactionsBase()),
    ]);
    return notesOk && childResults.every((r) => r);
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

  /// Ensure notes are loaded for an activity, pulling them on first view.
  /// Resolves once this thread's notes are guaranteed loaded: immediately if a
  /// "notes:{threadId}" sync state already exists, otherwise after
  /// [pullForActivity] completes (whether it returned notes or not). Callers
  /// that don't need to await (e.g. [watch]) can fire-and-forget with
  /// `.catchError`; the bloc awaits it to drive the loading spinner.
  static Future<void> ensureNotesLoadedForActivity(ThreadId threadId) async {
    final entity = "notes:$threadId";
    final syncState =
        await (Store.get.select(Store.get.syncStates)
              ..where((s) => s.entity.equals(entity)))
            .getSingleOrNull();
    if (syncState != null) return;
    // Never loaded notes for this activity - pull now.
    log.info('First time viewing activity $threadId, pulling notes');
    await pullForActivity(threadId);
  }

  static Stream<List<Note>> watch(
    ThreadId threadId, {
    bool? archived = false,
    bool? draft = false,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    NoteId? threadNoteId,
  }) {
    // Check if notes for this activity have been loaded, if not trigger pull
    // (fire-and-forget; the watch stream below emits local notes immediately).
    ensureNotesLoadedForActivity(threadId).catchError((Object e) {
      log.warning('Failed to pull notes for activity $threadId: $e');
    });

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
    final reactions = Store.get.alias(Store.get.noteReactions, 'reactions');
    final hasReactionFilter =
        reactionFilter != null && reactionFilter.isNotEmpty;

    // Build query with joins. JOIN noteReactions only when filtering by them
    // so the unfiltered path stays as cheap as before.
    var query = Store.get
        .select(n)
        .join([
          leftOuterJoin(tags, tags.id.equalsExp(n.id)),
          if (hasReactionFilter)
            leftOuterJoin(reactions, reactions.id.equalsExp(n.id)),
        ])
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
    // This must happen AFTER the tags table is joined.
    // OR-within-section: any selected tag matches. `tag.id` is a UUID,
    // safe to inline.
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      final orClause = mutableFilter
          .map((t) => "JSON_EXTRACT(tags.tags, '\$.${t.id}') IS NOT NULL")
          .join(' OR ');
      query.where(CustomExpression<bool>('($orClause)'));
    }

    // Reaction filter: OR-within-section, AND'd against the tag predicate
    // via Drift's separate .where call.
    if (hasReactionFilter) {
      final orClause = reactionFilter
          .map((e) =>
              "JSON_EXTRACT(reactions.reactions, ${emojiJsonPath(e)}) IS NOT NULL")
          .join(' OR ');
      query.where(CustomExpression<bool>('($orClause)'));
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

  /// Watch all reactions present on a thread's notes and the thread itself.
  /// Returns (Reaction, count) tuples sorted by occurrence descending. Used
  /// to populate the reaction-filter picker on the thread page.
  static Stream<List<(Reaction, int)>> watchReactionsForActivity(
    ThreadId threadId,
  ) {
    final tr = Store.get.threadReactions;
    final nr = Store.get.noteReactions;
    final n = Store.get.notes;

    final threadReactionsQuery = Store.get.select(tr)
      ..where((t) => t.id.equalsValue(threadId));

    final noteReactionsQuery = Store.get.select(nr).join([
      innerJoin(n, n.id.equalsExp(nr.id) & n.archivedAt.isNull()),
    ])..where(n.threadId.equalsValue(threadId));

    return Rx.combineLatest2(
      threadReactionsQuery.watch(),
      noteReactionsQuery.watch(),
      (List<ThreadReactionsRow> threadRows, List<TypedResult> noteRows) {
        final counts = <Reaction, Set<Uuid>>{};
        for (final row in threadRows) {
          final reactions = row.reactions;
          if (reactions == null) continue;
          for (final emoji in reactions.keys) {
            counts.putIfAbsent(emoji, () => <Uuid>{}).add(threadId);
          }
        }
        for (final row in noteRows) {
          final noteRow = row.readTable(nr);
          final reactions = noteRow.reactions;
          if (reactions == null) continue;
          for (final emoji in reactions.keys) {
            counts.putIfAbsent(emoji, () => <Uuid>{}).add(noteRow.id);
          }
        }
        final result = counts.entries
            .map((e) => (e.key, e.value.length))
            .toList()
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
      accessGroups: accessGroups,
      content: content,
      sourceCreatedAt: sourceCreatedAt,
      actions: actions,
      cta: cta,
      deliveryError: deliveryError,
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
      // When Tag.todo is added to a note for the current user, ensure
      // per-user state exists on the thread (makes the thread appear on
      // the user's todo list).
      if (hasTag(Tag.todo, Base.actorId)) {
        await _ensureTodoForUser(threadId);
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

  /// Ensures per-user thread-state exists on the thread for the current
  /// user — sets active=true, state_on = todoNowDate, clears read_at —
  /// then pushes via POST /sync/thread-state.
  static Future<void> _ensureTodoForUser(ThreadId threadId) async {
    final row = await (Store.get.select(Store.get.threads)
          ..where((t) => t.id.equalsValue(threadId)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.active && row.readAt == null) return;
    final now = DateTime.now();
    await (Store.get.update(Store.get.threads)
          ..where((t) => t.id.equalsValue(threadId)))
        .write(ThreadsCompanion(
          active: const Value(true),
          stateOrder: Value(row.stateOrder ?? Order.first()),
          stateOn: Value(row.stateOn ?? Thread.todoNowDate),
          readAt: const Value(null),
          updatedAt: Value(now),
        ));
    try {
      await api.post<Map<String, dynamic>>('/sync/thread-state', body: {
        'thread_id': threadId.toString(),
        'active': true,
        'on': '[${row.stateOn ?? Thread.todoNowDate},)',
        'read_at': null,
      });
    } catch (e, t) {
      log.warning('Failed to push thread state for $threadId: $e\n$t');
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

  Future<void> archive() => copyWith(archivedAt: Value(DateTime.now())).save();

  /// Retry a failed outbound send. Asks the server to re-dispatch the
  /// connector write-back (POST /sync/note-retry-send). When the server
  /// re-dispatched it (`redispatched: true`) it has cleared `delivery_error`
  /// server-side, so we clear the local marker too for instant feedback; if
  /// the retry fails again the server re-marks it and the affordance reappears
  /// via sync. When there's nothing to re-dispatch to (a failed new-message
  /// compose leaves no connector link), we leave the marker in place.
  Future<void> retrySend() async {
    if (deliveryError == null) return;
    try {
      final res = await api.post<Map<String, dynamic>>(
        '/sync/note-retry-send',
        body: {'note_id': id.toString()},
      );
      if (res['redispatched'] == true) {
        await (Store.get.update(Store.get.notes)
              ..where((t) => t.id.equals(id.toBytes())))
            .write(
              const NotesCompanion(deliveryError: Value<DeliveryError?>(null)),
            );
      }
    } catch (e, t) {
      log.warning('Failed to retry note send for $id: $e\n$t');
    }
  }

  /// Discard a note that failed to send. It never reached its recipient, so
  /// archiving it (which syncs) removes it from the thread on every device.
  Future<void> discard() => archive();

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

  /// Format the actors who added an emoji reaction for display in a tooltip
  /// subtitle, e.g. "You, Alice, Bob" or "You, Alice, Bob + 2 more".
  /// "You" is shown first for the current user.
  static Future<String> formatReactionActorNames(List<ActorId> actorIds) {
    return Note._formatActorNames(actorIds);
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
      return copyWith(
        accessContacts: Value(value ? [actorId] : null),
        accessGroups: Value(value ? <ActorId>[] : null),
      );
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
    Value<List<ActorId>?> accessGroups = const Value.absent(),
    String? content,
    List<UserAction>? actions,
    Value<Cta?> cta = const Value.absent(),
    Value<DeliveryError?> deliveryError = const Value.absent(),
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
        accessGroups: accessGroups.present ? accessGroups.value : this.accessGroups,
        content: content ?? this.content,
        sourceCreatedAt: isPublishing ? now : sourceCreatedAt,
        actions: actions ?? this.actions,
        cta: cta.present ? cta.value : this.cta,
        deliveryError: deliveryError.present ? deliveryError.value : this.deliveryError,
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
    accessGroups,
    content,
    actions,
    cta,
    deliveryError,
    mentions,
    reNoteId,
    createdAt,
    updatedAt,
    archivedAt,
    mergedFromThreadId,
    pending,
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
