import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ReorderableNotesView extends StatelessWidget {
  const ReorderableNotesView({required this.notes, super.key});

  final List<Note> notes;

  @override
  Widget build(BuildContext context) => ReorderableListView(
        list: notes,
        itemBuilder: (buildContext, item) => TopicWidget(
          note: item,
          onChange: (note) => context.read<ActivityBloc>().updateNote(note),
          onTap: () => TopicRoute.byId(
            item.activityId,
            item.topicId,
          ).go(context),
        ),
        shrinkWrap: true,
        onReorder: (int oldIndex, int newIndex) async {
          var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
          var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
          Note note = notes[oldIndex];
          Note? previous;
          if (previousIndex >= 0) {
            previous = notes[previousIndex];
          }
          Note? next;
          if (nextIndex < notes.length) {
            next = notes[nextIndex];
          }
          context.read<ActivityBloc>().updateNote(note.copyWith(
                order: Order.between(previous?.order, next?.order),
                // Action notes are sorted first by doAt, so we need to set this
                // to have the same doAt as one of its neighbours.
                doAt: note.doNow
                    ? Value(previous?.doAt ?? next?.doAt ?? note.doAt)
                    : const Value.absent(),
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
              icon: const PlotIcon.add(),
              label: 'New',
              showLabel: false,
              onPressed: () {
                if (state.current == null) {
                  // TODO
                } else {
                  NewRoute.byId(state.current!.id).go(context);
                }
              },
            ),
          ],
          body: BidirectionalList(
            scrollController: ScrollControllerContext.of(context),
            count: state.notes.length,
            builder: (context, index) => TopicWidget(
              note: state.notes[index],
              onChange: (note) => context.read<ActivityBloc>().updateNote(note),
              onTap: () => TopicRoute.byId(
                state.notes[index].activityId,
                state.notes[index].topicId,
              ).go(context),
            ),
            header: Column(
              children: [
                WeekSelector(
                  week: state.week,
                  onSelect: (week) =>
                      context.read<ActivityBloc>().setWeek(week),
                ),
                ReorderableListView(
                  list: state.children,
                  itemBuilder: (buildContext, item) => ActivityWidget(
                      activity: item,
                      balances: state.balances?[item.id],
                      onTap: () {
                        ActivityRoute.byId(item.id).go(context);
                      }),
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
                    state.children[oldIndex]
                        .copyWith(
                          order: Order.between(previous?.order, next?.order),
                        )
                        .save();
                  },
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
