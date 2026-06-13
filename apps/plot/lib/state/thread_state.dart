part of 'thread.dart';

@immutable
class ThreadState extends Equatable {
  ThreadState({
    required this.thread,
    Note? draft,
    List<Note> notes = const [],
    List<Link> links = const [],
    this.linksLoaded = false,
    this.notesLoaded = false,
    this.showArchived = false,
    List<Tag> filter = const [],
    List<Reaction> reactionFilter = const [],
    this.search = '',
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    List<(Reaction, int)> reactions = const [],
    this.replyTo,
    this.editingNote,
    this.threadNoteId,
  }) : notes = notes.isNotEmpty ? List.unmodifiable(notes) : notes,
       links = links.isNotEmpty ? List.unmodifiable(links) : links,
       filter = filter.isNotEmpty ? List.unmodifiable(filter) : filter,
       reactionFilter = reactionFilter.isNotEmpty
           ? List.unmodifiable(reactionFilter)
           : reactionFilter,
       tags = tags.isNotEmpty ? List.unmodifiable(tags) : tags,
       tagSuggestions = tagSuggestions.isNotEmpty
           ? List.unmodifiable(tagSuggestions)
           : tagSuggestions,
       reactions = reactions.isNotEmpty
           ? List.unmodifiable(reactions)
           : reactions,
       hasOtherAuthors =
           notes.firstWhereOrNull((note) => !note.authorId.isCurrentUser) !=
           null,
       draft = draft ?? Note.draft(threadId: thread.id);

  final Thread thread;
  final Note draft;
  final List<Note> notes;
  final List<Link> links;

  /// Whether the thread's links have completed their first load from the
  /// store (the initial [Link.watchForThread] emission has landed). False
  /// for the synchronously-built initial state, before links arrive a frame
  /// later. Link-config-dependent composer chrome — the pill row, the
  /// bottom-bar Link/Attach buttons, and the send label — holds a neutral
  /// state until this is true so connector threads (e.g. Google Calendar
  /// events) don't briefly render as a plain Plot thread and then swap,
  /// which read as a visible flash.
  final bool linksLoaded;

  /// Whether this thread's notes have been loaded at least once for this bloc
  /// (i.e. the per-thread pull has completed, or a non-empty list arrived from
  /// the local store). Sticky: once true it stays true for the life of the
  /// bloc, so changing a filter never re-shows the loading spinner. Used by
  /// [ThreadPage] to show a delayed spinner only while notes are genuinely
  /// still loading on demand — never when they're already local.
  final bool notesLoaded;

  final bool showArchived;
  final List<Tag> filter;
  final List<Reaction> reactionFilter;
  final String search;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final List<(Reaction, int)> reactions;
  final Note? replyTo;
  final Note? editingNote;
  final NoteId? threadNoteId;
  final bool hasOtherAuthors;

  /// LinkTypeConfig of the thread's primary canonical link (see
  /// [Thread.primaryLink]), used to adapt composer copy. Null when the thread
  /// has no canonical link or no resolvable type.
  LinkTypeConfig? get primaryLinkTypeConfig =>
      Thread.primaryLink(links)?.getTypeConfig();

  /// Twists associated with this thread: those mentioned on any note, plus
  /// those that created a link (source connectors). Including link creators
  /// ensures connectors with `defaultMentionCreated` appear here so replies
  /// route back to their `onNoteCreated` — without this, a user's reply to
  /// a synced Google Chat / Slack / Gmail thread never reaches the source.
  List<TwistInstance> get threadTwists {
    final mentionIds = <Uuid>{};
    for (final note in notes) {
      if (note.mentions != null) {
        for (final actorId in note.mentions!) {
          mentionIds.add(actorId.toUuid());
        }
      }
    }
    for (final link in links) {
      final createdBy = link.createdBy;
      if (createdBy != null) mentionIds.add(createdBy);
    }
    if (mentionIds.isEmpty) return const [];
    final twists = <TwistInstance>[];
    for (final id in mentionIds) {
      final actorId = ActorId.fromUuid(id);
      if (actorId.isTwist) {
        final twist = TwistInstance.fromCache(id);
        if (twist != null) twists.add(twist);
      }
    }
    return twists;
  }

  ThreadState copyWith({
    Priority? context,
    Thread? thread,
    Note? draft,
    List<Note>? notes,
    List<Link>? links,
    bool? linksLoaded,
    bool? notesLoaded,
    bool? showArchived,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    String? search,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    List<(Reaction, int)>? reactions,
    Note? replyTo,
    bool clearReplyTo = false,
    Note? editingNote,
    bool clearEditingNote = false,
    NoteId? threadNoteId,
    bool clearThreadNoteId = false,
  }) {
    return ThreadState(
      thread: thread ?? this.thread,
      draft: draft ?? this.draft,
      notes: notes != null
          ? (notes.isNotEmpty ? List.unmodifiable(notes) : notes)
          : this.notes,
      links: links != null
          ? (links.isNotEmpty ? List.unmodifiable(links) : links)
          : this.links,
      linksLoaded: linksLoaded ?? this.linksLoaded,
      notesLoaded: notesLoaded ?? this.notesLoaded,
      showArchived: showArchived ?? this.showArchived,
      filter: filter != null
          ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter)
          : this.filter,
      reactionFilter: reactionFilter != null
          ? (reactionFilter.isNotEmpty
                ? List.unmodifiable(reactionFilter)
                : reactionFilter)
          : this.reactionFilter,
      search: search ?? this.search,
      tags: tags != null
          ? (tags.isNotEmpty ? List.unmodifiable(tags) : tags)
          : this.tags,
      tagSuggestions: tagSuggestions != null
          ? (tagSuggestions.isNotEmpty
                ? List.unmodifiable(tagSuggestions)
                : tagSuggestions)
          : this.tagSuggestions,
      reactions: reactions != null
          ? (reactions.isNotEmpty ? List.unmodifiable(reactions) : reactions)
          : this.reactions,
      replyTo: clearReplyTo ? null : (replyTo ?? this.replyTo),
      editingNote: clearEditingNote
          ? null
          : (editingNote ?? this.editingNote),
      threadNoteId: clearThreadNoteId
          ? null
          : (threadNoteId ?? this.threadNoteId),
    );
  }

  @override
  List<Object?> get props => [
    thread,
    draft,
    notes,
    links,
    linksLoaded,
    notesLoaded,
    showArchived,
    filter,
    reactionFilter,
    search,
    tags,
    tagSuggestions,
    reactions,
    replyTo,
    editingNote,
    threadNoteId,
    hasOtherAuthors,
  ];

  @override
  String toString() {
    return 'ThreadState(thread: ${thread.title}, draft: $draft, notes: ${notes.length}, showArchived: $showArchived, filter: $filter, search: $search, tags: ${tags.length})';
  }
}

class ThreadDateGroup extends Equatable {
  ThreadDateGroup({required this.date, required List<Thread> threads})
    : threads = threads.isNotEmpty
          ? List.unmodifiable(threads)
          : threads;

  final Date date;
  final List<Thread> threads;

  @override
  List<Object?> get props => [date, threads];

  @override
  String toString() {
    return 'ThreadDateGroup(date: $date, threads: ${threads.length})';
  }
}
