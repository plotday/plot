import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ReorderableActivitiesView extends StatelessWidget {
  const ReorderableActivitiesView(
      {required this.activities, this.selected, super.key});

  final List<Activity> activities;
  final ActivityId? selected;

  @override
  Widget build(BuildContext context) => ReorderableListView(
        list: activities,
        itemBuilder: (buildContext, item) => ActivityWidget(
          activity: item,
          selected: selected == item.id,
          onChange: (activity) =>
              context.read<PriorityBloc>().updateActivity(activity),
          onTap: () => ActivityRoute.byId(
            item.priorityId,
            item.id,
          ).go(context),
        ),
        shrinkWrap: true,
        onReorder: (int oldIndex, int newIndex) async {
          var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
          var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
          Activity activity = activities[oldIndex];
          Activity? previous;
          if (previousIndex >= 0) {
            previous = activities[previousIndex];
          }
          Activity? next;
          if (nextIndex < activities.length) {
            next = activities[nextIndex];
          }
          context.read<PriorityBloc>().updateActivity(activity.copyWith(
                order: Order.between(previous?.order, next?.order),
                // Action activities are sorted first by doAt, so we need to set this
                // to have the same doAt as one of its neighbours.
                doAt: activity.doNow
                    ? Value(previous?.doAt ?? next?.doAt ?? activity.doAt)
                    : const Value.absent(),
              ));
        },
      );
}

class PriorityHeader extends StatelessWidget {
  const PriorityHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (buildContext, state) => Header(
        title: state.current?.name ?? 'All Priorities',
        actions: [
          HeaderAction(
            icon: const PlotIcon.add(),
            label: 'New',
            showLabel: false,
            onPressed: () {
              NewActivityRoute.byId(state.current?.id).go(context);
            },
          ),
        ],
      ),
    );
  }
}

class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (buildContext, state) => BidirectionalList(
        scrollController: ScrollControllerContext.of(context),
        count: state.inactiveActivities.length,
        builder: (context, index) => ActivityWidget(
          activity: state.inactiveActivities[index],
          selected: state.activity.id == state.inactiveActivities[index].id,
          onChange: (activity) =>
              context.read<PriorityBloc>().updateActivity(activity),
          onTap: () => ActivityRoute.byId(
            state.inactiveActivities[index].priorityId,
            state.inactiveActivities[index].id,
          ).go(context),
        ),
        header: Column(
          children: [
            WeekSelector(
              week: state.week,
              onSelect: (week) => context.read<PriorityBloc>().setWeek(week),
            ),
            ReorderableListView(
              list: state.children,
              itemBuilder: (buildContext, item) => PriorityTile(
                  priority: item,
                  balances: state.balances?[item.id],
                  isNow: state.week.isNow(),
                  onTap: () {
                    if (item.id == null) return;
                    PriorityRoute.byId(item.id).go(context);
                  }),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Priority? previous;
                if (previousIndex >= 0) {
                  previous = state.children[previousIndex];
                }
                Priority? next;
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
            ReorderableActivitiesView(
              activities: state.pinnedActivities,
              selected: state.activity.id,
            ),
            ReorderableActivitiesView(
              activities: state.activeActivities,
              selected: state.activity.id,
            ),
          ],
        ),
      ),
    );
  }
}
