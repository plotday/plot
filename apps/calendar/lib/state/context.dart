import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/optional.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc()
      : super(ContextState(
          week: Week.current(),
        )) {
    setCurrent(null);
  }

  void dispose() {
    _contextSubscription?.cancel();
    _balanceSubscription?.cancel();
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
  }

  void setCurrent(ContextId? current) {
    if (_contextSubscription != null && current == state.current?.id) return;
    _contextSubscription?.cancel();
    if (current == null) {
      _contextSubscription = Context.watchRoot().listen((contexts) {
        emit(state.copyWith(current: Optional.of(null), children: contexts));
        _loadBalances();
        _loadNotes();
      });
    } else {
      _contextSubscription =
          Context.watchOne(current, depth: 1).listen((context) {
        emit(state.copyWith(current: Optional.of(context)));
        _loadBalances();
        _loadNotes();
      });
    }
  }

  Future<void> save(Context context) async {
    await context.save();
  }

  void setWeek(Week week) async {
    emit(state.copyWith(week: week, balances: Optional.of(null)));
    _loadBalances();
  }

  void _loadBalances() async {
    _balanceSubscription?.cancel();
    _balanceSubscription =
        Balance.watch(state.week.start, state.week.end).listen(
      (balances) {
        emit(state.copyWith(balances: Optional.of(balances)));
      },
    );
  }

  void _loadNotes() async {
    _noteSubscription?.cancel();
    _topicSubscription?.cancel();
    _noteSubscription = Note.watchContext(state.current).listen((notes) {
      emit(state.copyWith(
        notes: notes,
        moreNotes: Note.hasMoreContext(state.current?.path),
      ));
    });
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

  Future<void> addNote(Note note) async {
    print("Adding note: ${note.order}");
    emit(state.copyWith(newNote: note));
    await note.save();
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

  StreamSubscription<dynamic>? _contextSubscription;
  StreamSubscription<Map<Uuid?, Balance>>? _balanceSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Note>>? _topicSubscription;
}
