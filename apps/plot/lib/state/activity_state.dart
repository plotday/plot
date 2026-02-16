part of 'activity.dart';

@immutable
class ActivityState extends Equatable {
  ActivityState({
    required this.activity,
    Note? draft,
    List<Note> notes = const [],
    this.showArchived = false,
    List<Tag> filter = const [],
    this.search = '',
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    this.replyTo,
    this.threadNoteId,
  }) : notes = notes.isNotEmpty ? List.unmodifiable(notes) : notes,
       filter = filter.isNotEmpty ? List.unmodifiable(filter) : filter,
       tags = tags.isNotEmpty ? List.unmodifiable(tags) : tags,
       tagSuggestions = tagSuggestions.isNotEmpty
           ? List.unmodifiable(tagSuggestions)
           : tagSuggestions,
       hasOtherAuthors =
           notes.firstWhereOrNull((note) => !note.authorId.isCurrentUser) !=
           null,
       draft = draft ?? Note.draft(activityId: activity.id);

  final Activity activity;
  final Note draft;
  final List<Note> notes;
  final bool showArchived;
  final List<Tag> filter;
  final String search;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final Note? replyTo;
  final NoteId? threadNoteId;
  final bool hasOtherAuthors;

  ActivityState copyWith({
    Priority? context,
    Activity? activity,
    Note? draft,
    List<Note>? notes,
    bool? showArchived,
    List<Tag>? filter,
    String? search,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    Note? replyTo,
    bool clearReplyTo = false,
    NoteId? threadNoteId,
    bool clearThreadNoteId = false,
  }) {
    return ActivityState(
      activity: activity ?? this.activity,
      draft: draft ?? this.draft,
      notes: notes != null
          ? (notes.isNotEmpty ? List.unmodifiable(notes) : notes)
          : this.notes,
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
      threadNoteId: clearThreadNoteId
          ? null
          : (threadNoteId ?? this.threadNoteId),
    );
  }

  @override
  List<Object?> get props => [
    activity,
    draft,
    notes,
    showArchived,
    filter,
    search,
    tags,
    tagSuggestions,
    replyTo,
    threadNoteId,
    hasOtherAuthors,
  ];

  @override
  String toString() {
    return 'ActivityState(activity: ${activity.title}, draft: $draft, notes: ${notes.length}, showArchived: $showArchived, filter: $filter, search: $search, tags: ${tags.length})';
  }
}

class ActivityDateGroup extends Equatable {
  ActivityDateGroup({required this.date, required List<Activity> activities})
    : activities = activities.isNotEmpty
          ? List.unmodifiable(activities)
          : activities;

  final Date date;
  final List<Activity> activities;

  @override
  List<Object?> get props => [date, activities];

  @override
  String toString() {
    return 'ActivityDateGroup(date: $date, activities: ${activities.length})';
  }
}
