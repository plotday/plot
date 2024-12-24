import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'dart:collection';

import 'package:plot/store/store.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc()
      : super(ActivityState(
          week: Week.current(),
        )) {
    setCurrent(null);
    _activitySubscription = Activity.watchRoot().listen((activities) {
      emit(state.copyWith(
        activities: activities,
      ));
    });
  }

  void dispose() {
    _activitySubscription.cancel();
    _balanceSubscription?.cancel();
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
  }

  void setCurrent(Activity? current) {
    if (current?.id == state.current?.id) {
      return;
    }

    emit(state.copyWith(
      current: Value(current),
      topicId: const Value(null),
      topicNotes: [],
    ));
    _loadBalances();
    _loadNotes();
  }

  void setCurrentId(ActivityId? id) async {
    if (id == state.current?.id) return;
    if (id == null) {
      setCurrent(null);
    } else {
      final activity = state.activities[id];
      setCurrent(activity);
    }
  }

  void setTopic(TopicId? topicId) {
    if (_topicSubscription != null &&
        (topicId == state.topicId ||
            (topicId == null && state.topic.draft == true))) {
      return;
    }
    emit(state.copyWith(topicId: Value(topicId), topicNotes: []));
    _loadTopicNotes();
  }

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  void setWeek(Week week) async {
    if (state.week == week) return;
    emit(state.copyWith(week: week, balances: const Value(null)));
    _loadBalances();
  }

  void _loadBalances() async {
    _balanceSubscription?.cancel();
    _balanceSubscription = Balance.watch(state.week).listen(
      (balances) {
        emit(state.copyWith(balances: Value(balances)));
      },
    );
  }

  void _loadNotes() {
    _noteSubscription?.cancel();
    _noteSubscription = Note.watchActivity(state.current).listen((notes) {
      emit(state.copyWith(
        notes: notes,
        moreNotes: Note.hasMoreActivity(state.current?.path),
      ));
    });
    _loadTopicNotes();
  }

  void _loadTopicNotes() {
    _topicSubscription?.cancel();
    final topic = state.topicId;
    if (topic != null) {
      _topicSubscription = Note.watchTopic(topic).listen((notes) {
        emit(state.copyWith(
          topicNotes: notes,
          moreTopicNotes: Note.hasMoreTopic(topic),
        ));
      });
    }
  }

  Future<void> updateNote(Note note) async {
    final topicUpdate =
        !note.draft && !note.root && note.topicId == state.topicId
            ? state.topic.copyWith(order: Order.first())
            : null;
    try {
      // TODO debounce save
      await Future.wait([
        note.save(),
        if (topicUpdate != null) topicUpdate.save(),
      ]);
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  late final StreamSubscription<dynamic> _activitySubscription;
  StreamSubscription<BalanceByActivityType>? _balanceSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Note>>? _topicSubscription;
}
