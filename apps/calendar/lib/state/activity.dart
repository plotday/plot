import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'dart:collection';

import 'package:plot/store/store.dart';
import 'package:plot/util/list.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc()
      : super(ActivityState(
          week: Week.current(),
        )) {
    setCurrent(null);
  }

  void dispose() {
    _activitySubscription?.cancel();
    _balanceSubscription?.cancel();
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
  }

  void setCurrent(ActivityId? current) {
    if (_activitySubscription != null && current == state.current?.id) return;
    _activitySubscription?.cancel();
    if (current == null) {
      _activitySubscription = Activity.watchRoot().listen((activities) {
        emit(state.copyWith(
            current: const Value(null),
            children: activities,
            topicId: const Value(null),
            topicNotes: []));
        _loadBalances();
        _loadNotes();
      });
    } else {
      _activitySubscription =
          Activity.watchOne(current, depth: 1).listen((activity) {
        emit(state.copyWith(
            current: Value(activity),
            topicId: const Value(null),
            topicNotes: []));
        _loadBalances();
        _loadNotes();
      });
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
    emit(
      state.copyWith(newNotes: [
        note,
        if (topicUpdate != null) topicUpdate,
      ]),
    );
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

  StreamSubscription<dynamic>? _activitySubscription;
  StreamSubscription<BalanceByActivityType>? _balanceSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Note>>? _topicSubscription;
}
