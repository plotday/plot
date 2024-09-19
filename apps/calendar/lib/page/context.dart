import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/reorderable_list_view.dart';
import 'package:plot/state/context.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/widget/input_action.dart';

class ContextPage extends StatelessWidget {
  const ContextPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Scaffold(
        body: Column(
          children: [
            ReorderableListView(
              list: state.children,
              itemBuilder: (buildContext, item) =>
                  PriorityWidget(context: item),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Context? previous;
                if (previousIndex >= 0) {
                  previous = state.children[previousIndex];
                }
                Context? next;
                if (nextIndex < state.children.length) {
                  next = state.children[nextIndex];
                }
                final context = state.children[oldIndex].copyWith(
                  order: Order.between(previous?.order, next?.order),
                );
                buildContext.read<ContextBloc>().update(context);
              },
            ),
            InputAction(
              onAdd: (name) {
                context.read<ContextBloc>().add(Context(
                      name: name,
                      parent: state.current,
                      order:
                          Order.between(state.children.lastOrNull?.order, null),
                    ));
              },
              label: "Add a priority",
            ),
            InputAction(
              onAdd: (body) {
                context.read<ContextBloc>().addNote(Note(
                      context: state.current,
                      body: body,
                      order: Order.first(),
                    ));
              },
              label: "Add a note",
            ),
            ReorderableListView(
              list: state.pinnedNotes,
              itemBuilder: (buildContext, item) => NoteWidget(note: item),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Note? previous;
                if (previousIndex >= 0) {
                  previous = state.notes[previousIndex];
                }
                Note? next;
                if (nextIndex < state.notes.length) {
                  next = state.notes[nextIndex];
                }
                final note = state.notes[oldIndex].copyWith(
                  order: Order.between(previous?.order, next?.order),
                );
                buildContext.read<ContextBloc>().updateNote(note);
              },
            ),
            ...state.notes.map((note) => NoteWidget(note: note)),
          ],
        ),
      ),
    );
  }
}
