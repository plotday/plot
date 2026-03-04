part of 'thread.dart';

@immutable
class ThreadState extends Equatable {
  ThreadState({
    required this.thread,
    Note? draft,
    List<Note> notes = const [],
    List<Link> links = const [],
    this.showArchived = false,
    List<Tag> filter = const [],
    this.search = '',
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    this.replyTo,
    this.editingNote,
    this.threadNoteId,
  }) : notes = notes.isNotEmpty ? List.unmodifiable(notes) : notes,
       links = links.isNotEmpty ? List.unmodifiable(links) : links,
       filter = filter.isNotEmpty ? List.unmodifiable(filter) : filter,
       tags = tags.isNotEmpty ? List.unmodifiable(tags) : tags,
       tagSuggestions = tagSuggestions.isNotEmpty
           ? List.unmodifiable(tagSuggestions)
           : tagSuggestions,
       hasOtherAuthors =
           notes.firstWhereOrNull((note) => !note.authorId.isCurrentUser) !=
           null,
       draft = draft ?? Note.draft(threadId: thread.id);

  final Thread thread;
  final Note draft;
  final List<Note> notes;
  final List<Link> links;
  final bool showArchived;
  final List<Tag> filter;
  final String search;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final Note? replyTo;
  final Note? editingNote;
  final NoteId? threadNoteId;
  final bool hasOtherAuthors;

  /// Twists mentioned across notes in this thread.
  /// Uses the thread's aggregated mentions and filters to twist-type actors,
  /// resolving them to PriorityTwist objects via the global cache.
  List<PriorityTwist> get threadTwists {
    final mentionIds = thread.mentions;
    if (mentionIds == null || mentionIds.isEmpty) return const [];
    final twists = <PriorityTwist>[];
    for (final id in mentionIds) {
      final actorId = ActorId.fromUuid(id);
      if (actorId.isTwist) {
        final twist = PriorityTwist.fromCache(id);
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
    bool? showArchived,
    List<Tag>? filter,
    String? search,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
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
      showArchived: showArchived ?? this.showArchived,
      filter: filter != null
          ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter)
          : this.filter,
      search: search ?? this.search,
      tags: tags != null
          ? (tags.isNotEmpty ? List.unmodifiable(tags) : tags)
          : this.tags,
      tagSuggestions: tagSuggestions != null
          ? (tagSuggestions.isNotEmpty
                ? List.unmodifiable(tagSuggestions)
                : tagSuggestions)
          : this.tagSuggestions,
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
    showArchived,
    filter,
    search,
    tags,
    tagSuggestions,
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
