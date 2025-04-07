import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/command/command.dart';
import 'loading.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    Priority? priority,
    PriorityId? priorityId,
    @PathParam("priorityId") String? priorityIdString,
    super.key,
  }) {
    priorityId =
        priority?.id ??
        priorityId ??
        (priorityIdString != null
            ? PriorityId.fromShortString(priorityIdString)
            : null);
    assert(
      priorityId != null,
      'A priority must be provided via one of the parameters: priority, priorityId, or priorityIdString.',
    );
    this.priorityId = priorityId!;
  }

  late final PriorityId priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return FutureBuilder<Priority?>(
      future: Priority.get(priorityId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoadingPage();
        }

        return BlocProvider(
          create: (_) => PriorityBloc(priority: snapshot.data!),
          child: this,
        );
      },
    );
  }
}

@RoutePage(name: "PriorityMainRoute")
class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (state.loading) {
          return LoadingPage();
        }
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, prioritiesState) {
            return Scaffold(
              translucent: true,
              header: Header(
                main: PrioritySelector(
                  selected: state.current,
                  onSelect: (p) => context.run<void>(ChangeCurrentPriority(p)),
                ),
              ),
              body: BidirectionalList(
                scrollController: ScrollControllerContext.of(context),
                count: state.inactiveActivities.length,
                builder:
                    (context, index) => ActivityWidget(
                      activity: state.inactiveActivities[index],
                    ),
                header: _PrioritiesSection(),
              ),
            );
          },
        );
      },
    );
  }
}

class _PrioritiesSection extends StatelessWidget {
  const _PrioritiesSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return Column(
          children: [
            ReorderableListView(
              list: state.current.children,
              itemBuilder:
                  (context, item) => Column(
                    children: [
                      PriorityTile(
                        priority: item,
                        balances: state.balances?[item.id],
                        maxTime: state.maxTime,
                      ),
                      _ReorderableActivitiesView(
                        activities: state.getChildActiveActivities(item.id),
                      ),
                    ],
                  ),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Priority? previous;
                if (previousIndex >= 0) {
                  previous = state.current.children[previousIndex];
                }
                Priority? next;
                if (nextIndex < state.current.children.length) {
                  next = state.current.children[nextIndex];
                }
                state.current.children[oldIndex]
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                    )
                    .save();
              },
            ),
            PriorityTile(
              priority: state.current,
              balances: state.balances?[state.current.id],
              maxTime: state.maxTime,
              title:
                  state.current.children.isNotEmpty ? "Everything Else" : null,
            ),
            _ReorderableActivitiesView(activities: state.activeActivities),
          ],
        );
      },
    );
  }
}

class _ReorderableActivitiesView extends StatelessWidget {
  const _ReorderableActivitiesView({required this.activities});

  final List<Activity> activities;

  @override
  Widget build(BuildContext context) => ReorderableListView(
    list: activities,
    itemBuilder: (buildContext, item) => ActivityWidget(activity: item),
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
      activity.copyWith(
        order: Order.between(previous?.order, next?.order),
        // Action activities are sorted first by doAt, so we need to set this
        // to have the same doAt as one of its neighbours.
        doAt:
            activity.doNow
                ? Value(previous?.doAt ?? next?.doAt ?? activity.doAt)
                : const Value.absent(),
      );
    },
  );
}
