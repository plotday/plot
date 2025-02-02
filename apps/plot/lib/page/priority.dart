import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
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
    return Builder(builder: (context) {
      final prioritiesState = context.watch<PrioritiesBloc>().state;
      final priorityState = context.watch<PriorityBloc>().selectedState;
      return Header(
        main: Expanded(
          child: Row(
            children: [
              IconButton(
                icon: const PlotIcon.priorities(),
                onPressed: () {
                  const PrioritiesRoute.all().go(context);
                },
              ),
              PrioritySelector(
                priorities: prioritiesState.rootPriorities,
                selected: priorityState.current,
                onSelect: (priority) {
                  PriorityRoute.byId(priority.id).go(context);
                },
              ),
            ],
          ),
        ),
        actions: [
          if (prioritiesState.balances?[priorityState.current.id] != null)
            PriorityBalance(
              balances: prioritiesState.balances![priorityState.current.id]!,
              isNow: prioritiesState.week.isNow(),
            ),
          IconButton(
            icon: const PlotIcon.add(),
            onPressed: () {
              NewActivityRoute.byId(priorityState.current.id).go(context);
            },
          ),
        ],
      );
    });
  }
}

class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, generalState) {
      final state = generalState as PrioritySelectedState;
      return BidirectionalList(
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
      );
    });
  }
}
