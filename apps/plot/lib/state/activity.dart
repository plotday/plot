// import 'dart:async';
//
// import 'package:flutter_bloc/flutter_bloc.dart';
// import 'package:equatable/equatable.dart';
//
// import 'package:plot/store/store.dart';
//
// part 'priority_state.dart';
//
// class PriorityBloc extends Cubit<PriorityState> {
//   PriorityBloc() : super(const NoPriorityState());
//
//   void _reset() {
//     _prioritySubscription?.cancel();
//     _prioritySubscription = null;
//     _noteSubscription?.cancel();
//     _noteSubscription = null;
//   }
//
//   @override
//   Future<void> close() {
//     _reset();
//     return super.close();
//   }
//
//   PrioritySelectedState get selectedState => state as PrioritySelectedState;
//
//   PriorityId? get currentId {
//     return switch (state) {
//       PrioritySelectedState state => state.current.id,
//       NoPriorityState _ => null,
//     };
//   }
//
//   void setCurrent(Priority? priority) {
//     if (switch (state) {
//       PrioritySelectedState state => state.current.id == priority?.id,
//       NoPriorityState _ => priority == null,
//     }) {
//       return;
//     }
//
//     _reset();
//
//     if (priority == null) {
//       emit(const NoPriorityState());
//       return;
//     }
//
//     emit(PrioritySelectedState(current: priority));
//     _prioritySubscription = Priority.watchOne(priority.id).listen((priority) {
//       emit(selectedState.copyWith(current: priority));
//     });
//     _loadPriorityNotes();
//   }
//
//   Future<void> setCurrentId(PriorityId? id) async {
//     if (switch (state) {
//       PrioritySelectedState state => state.current.id == id,
//       NoPriorityState _ => id == null,
//     }) {
//       return;
//     }
//     _reset();
//     if (id == null) {
//       setCurrent(null);
//     } else {
//       final priority = await Priority.get(id);
//       setCurrent(priority);
//     }
//   }
//
//   Future<void> updatePriority(Priority priority) async {
//     try {
//       // TODO debounce save
//       priority.save();
//     } catch (e) {
//       print(e);
//       rethrow;
//     }
//   }
//
//   Future<void> updateNote(Note note) async {
//     final priorityUpdate =
//         !note.draft && note.priorityId == selectedState.current.id
//             ? selectedState.current.copyWith(order: Order.first())
//             : null;
//     try {
//       // TODO debounce save
//       await Future.wait([
//         note.save(),
//         if (priorityUpdate != null) priorityUpdate.save(),
//       ]);
//     } catch (e) {
//       print(e);
//       rethrow;
//     }
//   }
//
//   void _loadPriorityNotes() {
//     _noteSubscription?.cancel();
//     final priorityId = selectedState.current.id;
//     if (priorityId != null) {
//       _noteSubscription = Note.watchPriority(priorityId).listen((notes) {
//         print('Notes: ${notes.map((n) => n.body)}');
//         emit(
//           selectedState.copyWith(
//             notes: notes,
//             moreNotes: Note.hasMorePriority(priorityId),
//           ),
//         );
//       });
//     }
//   }
//
//   StreamSubscription<Priority>? _prioritySubscription;
//   StreamSubscription<List<Note>>? _noteSubscription;
// }
