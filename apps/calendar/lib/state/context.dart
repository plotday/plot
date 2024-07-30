import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/context.dart';
import 'package:plot/model/note.dart';
import 'package:plot/model/budget.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/optional.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc()
      : super(ContextState(
          contexts: Context.store.list(),
          week: Week.current(),
        )) {
    _contextSubscription = Context.store.stream().listen((contexts) {
      emit(state.copyWith(contexts: contexts));
    });
  }

  void dispose() {
    _contextSubscription.cancel();
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
  }

  void setCurrent(Context? current) {
    if (current == state.current) return;
    emit(ContextState(
      contexts: Context.store.list(),
      week: Week.current(),
      current: current,
    ));
    loadBudgets();
    loadNotes();
  }

  void add(Context context) async {
    emit(state.copyWith(contexts: state.all + [context]));
    await context.save();
  }

  void update(Context context) async {
    final currentContexts = state.all;
    final contexts =
        currentContexts.replace(context, (c1, c2) => c1.id == c2.id);
    emit(
      state.copyWith(contexts: contexts),
    );
    try {
      await context.save();
    } catch (e) {
      emit(state.copyWith(contexts: currentContexts));
      rethrow;
    }
  }

  void setWeek(Week week) async {
    emit(state.copyWith(week: week, budgets: Optional.of(null)));
    loadBudgets();
  }

  void loadBudgets() async {
    final budgets = await Budget.list(state.week);
    emit(state.copyWith(budgets: Optional.of(budgets)));
  }

  void loadNotes() async {
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
    _noteSubscription = Note.stream(state.current).listen((notes) {
      emit(state.copyWith(
        notes: notes,
        moreNotes: Note.more(state.current),
      ));
    });
    final topic = state.topic;
    if (topic != null) {
      _topicSubscription = Note.streamTopic(topic).listen((notes) {
        emit(state.copyWith(
          topicNotes: notes,
          moreTopicNotes: Note.moreTopic(topic),
        ));
      });
    }
  }

  void setBudget(Budget budget) async {
    if (state.week == budget.week) {
      emit(
        state.copyWith(
          budgets: Optional.of(
              state.budgets?.replace(budget, (b1, b2) => b1.id == b2.id)),
        ),
      );
    }
    await budget.save();
  }

  late StreamSubscription<List<Context>> _contextSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Note>>? _topicSubscription;
}
