import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/widget/reorderable_list_view.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/widget/bidirectional_list.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (buildContext, state) => Scaffold(
          body: BidirectionalList(
        scrollController: ScrollControllerContext.of(context),
        count: state.notes.length,
        builder: (context, index) => NoteWidget(note: state.notes[index]),
        header: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Activity'),
                  Row(
                    children: [
                      if (state.current != null)
                        Button(
                            onTap: () {
                              ActivityEditRoute.byId(state.current!.id)
                                  .go(context);
                            },
                            child: const Text('Edit')),
                      if (state.current != null) const SizedBox(width: 8),
                      Button(
                        onTap: () {
                          ActivityAddRoute.byId(state.current?.id).go(context);
                        },
                        child: const Text('+'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ReorderableListView(
              list: state.children,
              itemBuilder: (buildContext, item) =>
                  ActivityWidget(context: item),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Activity? previous;
                if (previousIndex >= 0) {
                  previous = state.children[previousIndex];
                }
                Activity? next;
                if (nextIndex < state.children.length) {
                  next = state.children[nextIndex];
                }
                Activity.fromStore(state.children[oldIndex].copyWith(
                  order: Order.between(previous?.order, next?.order),
                )).save();
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Notes'),
                  Button(
                      onTap: () {
                        if (state.current == null) {
                          HomeRoute().go(context);
                        } else {
                          ActivityRoute.byId(state.current!.id).go(context);
                        }
                      },
                      child: const Text('+')),
                ],
              ),
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
                final note = Note.fromStore(state.notes[oldIndex].copyWith(
                  order: Order.between(previous?.order, next?.order),
                ));
                buildContext.read<ActivityBloc>().updateNote(note);
              },
            ),
          ],
        ),
      )),
    );
  }
}
