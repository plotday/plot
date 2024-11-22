import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/widget/reorderable_list_view.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity.dart';
import 'package:plot/widget/bidirectional_list.dart';

class ReorderableNotesView extends StatelessWidget {
  const ReorderableNotesView({required this.notes, super.key});

  final List<Note> notes;

  @override
  Widget build(BuildContext context) => ReorderableListView(
        list: notes,
        itemBuilder: (buildContext, item) => TopicWidget(note: item),
        shrinkWrap: true,
        onReorder: (int oldIndex, int newIndex) async {
          var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
          var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
          Note? previous;
          if (previousIndex >= 0) {
            previous = notes[previousIndex];
          }
          Note? next;
          if (nextIndex < notes.length) {
            next = notes[nextIndex];
          }
          context.read<ActivityBloc>().updateNote(notes[oldIndex].copyWith(
                order: Order.between(previous?.order, next?.order),
              ));
        },
      );
}

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (buildContext, state) => Scaffold(
          actions: [
            ActionItem(
              icon: Icons.today,
              label: 'Schedule',
              showLabel: false,
              onPressed: () {},
            ),
          ],
          body: BidirectionalList(
            scrollController: ScrollControllerContext.of(context),
            count: state.notes.length,
            builder: (context, index) => TopicWidget(note: state.notes[index]),
            header: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
                              ActivityAddRoute.byId(state.current?.id)
                                  .go(context);
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
                  itemBuilder: (buildContext, item) => ActivityWidget(
                    activity: item,
                    balances: state.balances?[item.id],
                  ),
                  shrinkWrap: true,
                  onReorder: (int oldIndex, int newIndex) async {
                    var previousIndex =
                        newIndex + (newIndex < oldIndex ? -1 : 0);
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
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
                ReorderableNotesView(
                  notes: state.pinnedNotes,
                ),
                ReorderableNotesView(
                  notes: state.doNowNotes,
                ),
              ],
            ),
          )),
    );
  }
}
