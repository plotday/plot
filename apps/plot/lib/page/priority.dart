import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/state/priorities.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/command/command.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    Priority? priority,
    PriorityId? priorityId,
    @PathParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId = priority?.id ??
            priorityId ??
            (priorityIdString != null
                ? PriorityId.fromShortString(priorityIdString)
                : null);

  final PriorityId? priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
        create: (_) => PriorityBloc(id: priorityId), child: this);
  }
}

@RoutePage(name: "PriorityMainRoute")
class PriorityPage extends StatelessWidget {
  const PriorityPage({
    super.key,
  });

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
          return Scaffold(
            body: BidirectionalList(
              scrollController: ScrollControllerContext.of(context),
              count: state.inactiveActivities.length,
              builder: (context, index) => ActivityWidget(
                activity: state.inactiveActivities[index],
              ),
              header: Column(
                children: [
                  PriorityTile(
                    priority: state.current,
                    balances: prioritiesState.balances?[state.current.id],
                    maxTime: prioritiesState.maxTime,
                  ),
                  ListTile.header(
                    title: "Priorities",
                    commands: [
                      NewPriority(),
                    ],
                  ),
                  _PrioritiesSection(),
                  ListTile.header(
                    title: "Now",
                    commands: [
                      // TODO mark started
                      NewActivity(),
                    ],
                  ),
                  _ReorderableActivitiesView(
                    activities: state.activeActivities,
                    selected: state.activity.id,
                  ),
                  ListTile.header(
                    title: "Activity",
                    commands: [
                      NewActivity(),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
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
              ),
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
