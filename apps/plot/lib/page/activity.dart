import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/action/action.dart';

@RoutePage(name: "ActivityRoute")
class ActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  ActivityWrapper({
    @PathParam("activityId") required String activityIdString,
    super.key,
  }) : activityId = ActivityId.fromShortString(activityIdString);

  final ActivityId activityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return ActivityBlocProvider(
      activityId: activityId,
      activity: null, // Let the bloc load the activity
      child: BlocConsumer<ActivityBloc, ActivityState>(
        listener: (context, state) {
          context.read<PriorityBloc>().setActivity(state.activity);
        },
        builder: (context, state) {
          return this;
        },
      ),
    );
  }
}

@RoutePage(name: "ActivityMainRoute")
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) {
        return ActionScope(
          actions: [
            StaticActionGroup(
              title: state.activity.displayTitle,
              actions: activityActions(state.activity),
            ),
          ],
          child: BidirectionalListSelector(
            reverse: true,
            onActivate: (index) {
              final activity = _getActivityAtIndex(state, index);
              if (activity != null) {
                context.run(ChangeCurrentActivity(activity));
              }
            },
            builder: (context, listController) => SelectionActionScope(
              actionBuilder: (index) {
                final activity = _getActivityAtIndex(state, index);
                return activity != null
                    ? [
                        StaticActionGroup(
                          title: activity.displayTitle,
                          actions: [
                            ChangeCurrentActivity(activity),
                            ...activityActions(activity),
                          ],
                        ),
                      ]
                    : <StaticActionGroup>[];
              },
              listController: listController,
              child: Scaffold(
                translucent: true,
                header: Header(
                  title: state.activity.displayTitle,
                  customSuffixes: [
                    SearchWidget(
                      onSearchChanged: (search) =>
                          context.read<ActivityBloc>().updateSearch(search),
                    ),
                  ],
                  actions: [
                    PickFilterAction(),
                    ShowActivityActions(state.activity),
                  ],
                ),
                body: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxActivityEditorHeight = constraints.maxHeight * 0.4;
                    return Column(
                      children: [
                        Flexible(
                          flex: 1,
                          fit: FlexFit.tight,
                          child: _buildActivityList(
                            state,
                            listController,
                            context,
                          ),
                        ),
                        Container(
                          constraints: BoxConstraints(
                            maxHeight: maxActivityEditorHeight,
                          ),
                          child: ActivityEditor(
                            onAdd: (activity) =>
                                context.read<ActivityBloc>().add(activity),
                            draft: state.draft,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int _getTotalItemCount(ActivityState state) {
    return state.activityGroups.fold(
      0,
      (count, group) => count + 1 + group.activities.length,
    );
  }

  Activity? _getActivityAtIndex(ActivityState state, int index) {
    int currentIndex = 0;

    for (final group in state.activityGroups) {
      // Skip date header
      currentIndex++;

      // Check activities in this group
      for (final activity in group.activities) {
        if (currentIndex == index) {
          return activity;
        }
        currentIndex++;
      }
    }

    return null;
  }

  Widget _buildActivityList(
    ActivityState state,
    BidirectionalListController listController,
    BuildContext context,
  ) {
    final totalItems = _getTotalItemCount(state);

    return BidirectionalList(
      controller: listController,
      scrollController: ScrollControllerContext.of(context),
      first: 0,
      count: totalItems,
      reverse: true,
      doneStart: true,
      doneEnd: true,
      fetcher: (first, count) =>
          Future<void>.value(), // No pagination needed for ActivityPage
      builder: (context, index, selected) {
        return _buildItemAtIndex(state, index, selected);
      },
    );
  }

  Widget _buildItemAtIndex(ActivityState state, int index, bool selected) {
    int currentIndex = 0;

    for (final group in state.activityGroups) {
      // Check activities in this group
      for (final activity in group.activities) {
        if (currentIndex == index) {
          return ActivityDetailWidget(
            activity: activity,
            context: null,
            selected: selected,
            key: ValueKey(activity.id),
          );
        }
        currentIndex++;
      }

      // Check if this is the date header
      if (currentIndex == index) {
        return DayHeader(
          date: group.date,
          now: group.date == Date.today(),
          selected: selected,
          key: ValueKey('date_${group.date.hashCode}'),
        );
      }
      currentIndex++;
    }

    // Fallback - should not happen
    return const SizedBox.shrink();
  }
}
