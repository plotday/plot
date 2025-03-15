import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/router.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, generalState) {
      if (generalState.loading) {
        return _PrioritiesSection();
      }
      final state = generalState as PrioritySelectedState;
      return BlocBuilder<PrioritiesBloc, PrioritiesState>(
        builder: (context, prioritiesState) {
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
                PriorityTile(
                    priority: state.current,
                    balances: prioritiesState.balances?[state.current.id],
                    maxTime: prioritiesState.maxTime,
                    onTap: () {}),
                ListHeader(
                  title: "Priorities",
                  action: IconButton(
                    icon: PlotIcon.add,
                    onPressed: () {},
                  ),
                ),
                _PrioritiesSection(),
                ListHeader(
                  title: "Now",
                  action: IconButton(
                    icon: PlotIcon.add,
                    onPressed: () {
                      NewActivityRoute.byId(state.current.id).go(context);
                    },
                  ),
                ),
                _ReorderableActivitiesView(
                  activities: state.activeActivities,
                  selected: state.activity.id,
                ),
                ListHeader(
                  title: "Activity",
                  action: IconButton(
                    icon: PlotIcon.add,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          );
        },
      );
    });
  }
}

class PriorityHeader extends StatelessWidget {
  const PriorityHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (context) {
      final prioritiesState = context.watch<PrioritiesBloc>().state;
      final priorityState = context.watch<PriorityBloc>().state;
      final currentPriority =
          priorityState is PrioritySelectedState ? priorityState.current : null;
      return Header(
        main: Expanded(
          child: Row(
            children: [
              IconButton(
                icon: PlotIcon.priorities,
                onPressed: () {
                  const PrioritiesRoute().go(context);
                },
              ),
              PrioritySelector(
                selected: currentPriority,
                onSelect: (priority) {
                  PriorityRoute.byId(priority.id).go(context);
                },
              ),
            ],
          ),
        ),
        actions: [
          if (currentPriority != null &&
              prioritiesState.balances?[currentPriority.id] != null)
            PriorityBalance(
              balances: prioritiesState.balances![currentPriority.id]!,
              max: prioritiesState.maxTime,
            ),
          if (currentPriority != null)
            IconButton(
              icon: PlotIcon.add,
              onPressed: () {
                NewActivityRoute.byId(currentPriority.id).go(context);
              },
            ),
        ],
      );
    });
  }
}

class _PrioritiesSection extends StatelessWidget {
  const _PrioritiesSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, state) {
        return Column(
          children: [
            ReorderableListView(
              list: state.filtered,
              itemBuilder: (context, item) => PriorityTile(
                  priority: item,
                  balances: state.balances?[item.id],
                  maxTime: state.maxTime,
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
                  previous = state.filtered[previousIndex];
                }
                Priority? next;
                if (nextIndex < state.filtered.length) {
                  next = state.filtered[nextIndex];
                }
                state.filtered[oldIndex]
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                    )
                    .save();
              },
            ),
          ],
        );
      },
    );
  }
}

class _ReorderableActivitiesView extends StatelessWidget {
  const _ReorderableActivitiesView({required this.activities, this.selected});

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
