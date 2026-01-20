import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';
import 'package:plot/page/loading.dart';
import 'logging.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc({required Activity activity})
    : _subscriptions = [],
      _tagsSubscription = null,
      super(ActivityState(activity: activity)) {
    _loadActivity();
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));
    _loadNotes();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));
    _loadNotes();
  }

  void updateSearch(String search) {
    log.info('Updating search to "$search"');
    emit(state.copyWith(search: search));
    _loadNotes();
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _tagsSubscription?.cancel();
    return super.close();
  }

  Future<void> save(Note note) async {
    await note.save();
  }

  /// Updates the draft note optimistically and saves it to the database.
  /// This provides instant UI updates while persisting changes.
  Future<void> updateDraft(Note draft) async {
    emit(state.copyWith(draft: draft));
    await draft.save();
  }

  /// Adds a note by converting the current draft to a non-draft.
  /// Creates a fresh draft note for the activity afterward.
  /// Note: Twisting tag for twist mentions is added in Note.save()
  Future<void> add(Note note) async {
    // Convert the draft to a non-draft
    note = note.copyWith(draft: false);
    await note.save();

    // Create fresh draft for the activity (in-memory only, will be saved when content is added)
    // Don't save empty draft - it will be saved when content is added via updateDraft()
    emit(state.copyWith(draft: Note.draft(activityId: state.activity.id)));
  }

  void _loadActivity() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }

    // Load draft note from database
    _loadDraftNote();

    _subscriptions.add(
      Activity.watchOne(state.activity.id).listen((watchedActivity) {
        emit(state.copyWith(activity: watchedActivity));
      }),
    );

    // Watch tags for the activity
    _tagsSubscription?.cancel();
    _tagsSubscription = Note.watchTagsForActivity(state.activity.id).listen((
      tags,
    ) {
      // Calculate tag suggestions: common tags first, then all other tags
      const actionTags = [
        Tag.now,
        Tag.done,
        Tag.later,
        Tag.someday,
        Tag.archived,
      ];

      // Common tags (excluding action tags)
      final commonTagsFiltered = tags
          .where(
            (tagData) => !actionTags.contains(tagData.$1) && tagData.$1.addable,
          )
          .map((tagData) => tagData.$1)
          .toList();

      // All tags excluding action tags and common tags
      final commonTagSet = commonTagsFiltered.toSet();
      final otherTags = Tag.getAll(onlyAddable: true)
          .where(
            (tag) => !actionTags.contains(tag) && !commonTagSet.contains(tag),
          )
          .toList();

      // Combine: common tags first, then other tags
      final tagSuggestions = [...commonTagsFiltered, ...otherTags];

      emit(state.copyWith(tags: tags, tagSuggestions: tagSuggestions));
    });

    _loadNotes();
  }

  /// Loads draft note from database for the current activity
  Future<void> _loadDraftNote() async {
    final existingDraft = await Note.getDraftByActivity(state.activity.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
    }
  }

  void _loadNotes() {
    log.info('Getting notes for activity ${state.activity.id}');

    _subscriptions.add(
      Note.watch(
        state.activity.id,
        archived: state.showArchived,
        draft: false,
        filter: state.filter.isNotEmpty ? state.filter : null,
        search: state.search.isNotEmpty ? state.search : null,
      ).listen((notes) {
        emit(state.copyWith(notes: notes));
      }),
    );
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
}

class ActivityBlocProvider extends StatefulWidget {
  const ActivityBlocProvider({
    required this.activityId,
    this.activity,
    required this.child,
    super.key,
  });

  final ActivityId activityId;
  final Activity? activity;
  final Widget child;

  @override
  ActivityBlocProviderState createState() => ActivityBlocProviderState();
}

class ActivityBlocProviderState extends State<ActivityBlocProvider> {
  late Future<ActivityBloc> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc =
        (widget.activity != null
                ? Future.value(widget.activity!)
                : Activity.getOne(widget.activityId))
            .then((activity) {
              return ActivityBloc(activity: activity);
            });
  }

  @override
  void didUpdateWidget(ActivityBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.activity != null && widget.activity != oldWidget.activity) {
      _bloc.then((bloc) async {
        final activity = widget.activity;
        if (activity == null) return;
        // Create new bloc with updated activity
        bloc.close();
        final newBloc = ActivityBloc(activity: activity);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    } else if (widget.activityId != oldWidget.activityId) {
      _bloc.then((bloc) async {
        bloc.close();
        final activity = await Activity.getOne(widget.activityId);
        final newBloc = ActivityBloc(activity: activity);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    }
  }

  @override
  void dispose() {
    _bloc.then((bloc) => bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _bloc,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoadingPage();
        }
        return BlocProvider.value(value: snapshot.data!, child: widget.child);
      },
    );
  }
}
