import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/optional.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc()
      : super(ContextState(
          contexts: const [],
          week: Week.current(),
        )) {
    _contextSubscription = Contexts.watch().listen((contexts) {
      emit(state.copyWith(contexts: contexts));
    });
    loadBudgets();
    loadNotes();
  }

  void dispose() {
    _contextSubscription.cancel();
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
  }

  void setCurrent(Context? current) {
    if (current == state.current) return;
    emit(ContextState(
      contexts: const [],
      week: Week.current(),
      current: current,
    ));
    loadBudgets();
    loadNotes();
  }

  Future<void> save(Context context) async {
    await context.save();
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
    _noteSubscription = Notes.watchContext(state.current?.path).listen((notes) {
      emit(state.copyWith(
        notes: notes,
        moreNotes: Note.more(state.current),
      ));
    });
    final topic = state.topicId;
    if (topic != null) {
      _topicSubscription = Notes.watchTopic(topic).listen((notes) {
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

  Future<void> addNote(Note note) async {
    print("Adding note: ${note.order}");
    emit(state.copyWith(newNote: note));
    final newNote = await note.save();
    emit(
      state.copyWith(newNote: newNote),
    );
  }

  Future<void> updateNote(Note note) async {
    final currentNotes = state.notes;
    final notes = currentNotes.replace(note, (n1, n2) => n1.id == n2.id);
    emit(
      state.copyWith(notes: notes),
    );
    try {
      await note.save();
    } catch (e) {
      emit(state.copyWith(notes: currentNotes));
      rethrow;
    }
  }

  late StreamSubscription<List<Context>> _contextSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Note>>? _topicSubscription;
}
