import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc() : super(const NoActivityState());

  void _reset() {
    _activitySubscription?.cancel();
    _activitySubscription = null;
    _noteSubscription?.cancel();
    _noteSubscription = null;
  }

  void dispose() {
    _reset();
  }

  ActivitySelectedState get selectedState => state as ActivitySelectedState;

  ActivityId? get currentId {
    return switch (state) {
      ActivitySelectedState state => state.current.id,
      NoActivityState _ => null,
    };
  }

  void setCurrent(Activity? activity) {
    if (switch (state) {
      ActivitySelectedState state => state.current.id == activity?.id,
      NoActivityState _ => activity == null,
    }) {
      return;
    }

    _reset();

    if (activity == null) {
      emit(const NoActivityState());
      return;
    }

    emit(ActivitySelectedState(
      current: activity,
    ));
    _activitySubscription = Activity.watchOne(
      activity.id,
    ).listen((activity) {
      emit(selectedState.copyWith(current: activity));
    });
    _loadActivityNotes();
  }

  Future<void> setCurrentId(ActivityId? id) async {
    if (switch (state) {
      ActivitySelectedState state => state.current.id == id,
      NoActivityState _ => id == null,
    }) {
      return;
    }
    _reset();
    if (id == null) {
      setCurrent(null);
    } else {
      final activity = await Activity.get(id);
      setCurrent(activity);
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
        !note.draft && note.activityId == selectedState.current.id
            ? selectedState.current.copyWith(order: Order.first())
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

  void _loadActivityNotes() {
    _noteSubscription?.cancel();
    final activityId = selectedState.current.id;
    if (activityId != null) {
      _noteSubscription = Note.watchActivity(activityId).listen((notes) {
        emit(selectedState.copyWith(
          notes: notes,
          moreNotes: Note.hasMoreActivity(activityId),
        ));
      });
    }
  }

  StreamSubscription<Activity>? _activitySubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
}