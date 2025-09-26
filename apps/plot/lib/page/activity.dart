import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/now.dart';
import 'package:plot/command/command.dart';
import 'loading.dart';
import 'logging.dart';

@RoutePage(name: "ActivityRoute")
class ActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  ActivityWrapper({
    Activity? activity,
    ActivityId? activityId,
    @PathParam("activityId") String? activityIdString,
    super.key,
  }) {
    final resolvedActivityId =
        activity?.id ??
        activityId ??
        (activityIdString != null
            ? ActivityId.fromShortString(activityIdString)
            : null);
    assert(resolvedActivityId != null, 'An activity must be provided.');
    this.activityId = resolvedActivityId!;
  }

  late final ActivityId activityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return FutureBuilder<Activity>(
      future: Activity.getOne(activityId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          log.warning(
            "Failed to load Priority and Activity",
            snapshot.error,
            snapshot.stackTrace,
          );
        }
        if (!snapshot.hasData) {
          return const LoadingPage();
        }

        final activity = snapshot.data!;

        // Set the current priority in NowBloc when entering this route
        WidgetsBinding.instance.addPostFrameCallback((_) {
          log.info(
            'Setting current priority to ${activity.priority.title} (from activity ${activity.displayTitle})',
          );
          context.read<NowBloc>().setPriority(activity.priority);
        });

        return BlocProvider(
          create: (_) =>
              ActivityBloc(priority: activity.priority, activity: activity),
          key: ValueKey(activity.id),
          child: this,
        );
      },
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
        return CommandScope(
          commands: [
            StaticCommandGroup(
              title: state.context.title,
              commands: currentPriorityCommands(state.context),
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
            builder: (context, listController) => SelectionCommandScope(
              commandBuilder: (index) {
                final activity = _getActivityAtIndex(state, index);
                return activity != null
                    ? [
                        StaticCommandGroup(
                          title: activity.displayTitle,
                          commands: [
                            ChangeCurrentActivity(activity),
                            ...activityCommands(activity),
                          ],
                        ),
                      ]
                    : <StaticCommandGroup>[];
              },
              listController: listController,
              child: Scaffold(
                translucent: true,
                header: Header(
                  title: state.activity?.displayTitle ?? "Activity",
                  commands: [
                    if (state.activity != null)
                      ...activityCommands(state.activity!),
                    PickFilterCommand(),
                  ],
                ),
                sidebar: PrioritiesSidebar(selected: state.context),
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
