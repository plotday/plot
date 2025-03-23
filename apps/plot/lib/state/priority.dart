import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc() : super(const NoPriorityState());

  void _reset() {
    _prioritySubscription?.cancel();
    _prioritySubscription = null;
    _noteSubscription?.cancel();
    _noteSubscription = null;
    _activitiesSubscription?.cancel();
    _activitiesSubscription = null;
  }

  void dispose() {
    _reset();
  }

  PrioritySelectedState get selectedState => state as PrioritySelectedState;

  PriorityId? get currentId {
    return switch (state) {
      PrioritySelectedState state => state.current.id,
      NoPriorityState _ => null,
    };
  }

  void setCurrent(Priority? current) {
    if (switch (state) {
      PrioritySelectedState state => state.current.id == current?.id,
      NoPriorityState _ => current == null,
    }) {
      return;
    }

    _reset();

    if (current == null) {
      emit(const NoPriorityState());
      return;
    }

    emit(PrioritySelectedState(
      current: current,
    ));
    _prioritySubscription = Priority.watchOne(
      current.id,
    ).listen((priority) {
      emit(selectedState.copyWith(current: priority));
    });
    _loadActivites();
  }

  Future<void> setCurrentId(PriorityId? id) async {
    if (switch (state) {
      PrioritySelectedState state => state.current.id == id,
      NoPriorityState _ => id == null,
    }) {
      return;
    }
    _reset();
    if (id == null) {
      setCurrent(null);
    } else {
      final priority = await Priority.get(id);
      setCurrent(priority);
    }
  }

  void setActivityId(ActivityId? activityId) {
    if (activityId == selectedState.activity.id) return;
    if (activityId == null) {
      setActivity(null);
    } else {
      Activity.get(activityId).then(setActivity);
    }
  }

  /// Change the current activity.
  ///
  /// If [activity] is null, the current draft activity (or a new one) is set.
  void setActivity(Activity? activity) {
    if (state is NoPriorityState) return;
    activity ??= selectedState.draftActivity;
    if (activity.id == selectedState.activity.id) {
      return;
    }
    emit(selectedState.copyWith(activity: Value(activity), activityNotes: []));
    _loadActivityNotes();
  }

  Future<void> save(Priority activity) async {
    await activity.save();
  }

  void _loadActivites() {
    _activitiesSubscription?.cancel();
    _activitiesSubscription =
        Activity.watchPriority(selectedState.current).listen((activities) {
      emit(selectedState.copyWith(
        activities: activities,
        moreActivities: Activity.hasMorePriority(selectedState.current.path),
      ));
    });
    _loadActivityNotes();
  }

  void _loadActivityNotes() {
    _noteSubscription?.cancel();
    final activityId = selectedState.activity.id;
    if (activityId != null) {
      _noteSubscription = Note.watchActivity(activityId).listen((notes) {
        emit(selectedState.copyWith(
          activityNotes: notes,
          moreActivityNotes: Note.hasMoreActivity(activityId),
        ));
      });
    }
  }

  Future<void> updateActivity(Activity activity) async {
    try {
      // TODO debounce save
      activity.save();
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  Future<void> updateNote(Note note) async {
    final activityUpdate =
        !note.draft && note.activityId == selectedState.activity.id
            ? selectedState.activity.copyWith(order: Order.first())
            : null;
    try {
      // TODO debounce save
      await Future.wait([
        note.save(),
        if (activityUpdate != null) activityUpdate.save(),
      ]);
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  StreamSubscription<Priority>? _prioritySubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Activity>>? _activitiesSubscription;
}
