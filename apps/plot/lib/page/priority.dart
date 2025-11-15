import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/action/action.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/router.dart' show PriorityMainRoute, NewActivityRoute;
import 'priorities.dart';
import 'logging.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    @PathParam("priorityId") required String priorityIdString,
    super.key,
  }) : priorityId = PriorityId.fromShortString(priorityIdString);

  late final PriorityId priorityId;

  void _handleRouteNavigation(BuildContext context, bool isMultiPanel) {
    final router = context.router;
    final hasActivityRoute = router.stack.any(
      (route) => route.name == 'ActivityRoute',
    );
    final hasNewActivityRoute = router.stack.any(
      (route) => route.name == 'NewActivityRoute',
    );

    if (isMultiPanel) {
      // When in multi-panel mode, ensure there's always a child route
      // If no ActivityRoute or NewActivityRoute is active, navigate to NewActivityRoute
      if (!hasActivityRoute && !hasNewActivityRoute) {
        router.navigate(const NewActivityRoute());
      }
    } else {
      // When transitioning from multi-panel to single-panel,
      // ensure we're on PriorityMainRoute (not showing NewActivityPage)
      // If we're showing NewActivityPage in right pane or on NewActivityRoute,
      // navigate back to PriorityMainRoute
      if (!hasActivityRoute && hasNewActivityRoute) {
        router.replace(const PriorityMainRoute());
      }
    }
  }

  @override
  Widget wrappedRoute(BuildContext context) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      child: BlocConsumer<PriorityBloc, PriorityState>(
        listenWhen: (previous, current) =>
            previous.context.id != current.context.id,
        listener: (context, state) {
          context.read<NowBloc>().setPriority(state.context);
        },
        builder: (context, state) {
          return ActionScope(
            actions: [
              StaticActionGroup(
                title: state.context.title,
                actions: currentPriorityActions(state.context),
              ),
            ],
            child: BlocBuilder<PriorityBloc, PriorityState>(
              builder: (context, priorityState) {
                return BlocConsumer<LayoutBloc, LayoutState>(
                  listenWhen: (previous, current) =>
                      previous.multiPanel != current.multiPanel,
                  listener: (context, layoutState) {
                    _handleRouteNavigation(context, layoutState.multiPanel);
                  },
                  builder: (context, layoutState) {
                    if (layoutState.multiPanel) {
                      return ResizablePanelLayout(
                        left: const PrioritiesPage(),
                        middle: const PriorityPage(),
                        child: AutoRouter(key: ValueKey("TheOne")),
                      );
                    } else {
                      return AutoRouter(key: ValueKey("TheOne"));
                    }
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

@RoutePage(name: "PriorityMainRoute")
class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (_, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            // Extract the actual priority state
            return (state.agendaItems.isEmpty &&
                    !(state.doneStart && state.doneEnd))
                ? const Center(child: Spinner())
                : BidirectionalListSelector(
                    onActivate: (index) {
                      final item =
                          index >= state.first &&
                              index - state.first < state.agendaItems.length
                          ? state.agendaItems[index - state.first]
                          : null;
                      item?.iff(
                        activity: (activity) =>
                            context.run(ChangeCurrentActivity(activity)),
                      );
                    },
                    builder: (context, listController) => SelectionActionScope(
                      actionBuilder: (index) {
                        final item =
                            index >= state.first &&
                                index - state.first < state.agendaItems.length
                            ? state.agendaItems[index - state.first]
                            : null;
                        return item?.iff(
                              activity: (activity) => [
                                StaticActionGroup(
                                  title: activity.displayTitle,
                                  actions: [
                                    OpenActivity(activity),
                                    ...activityActions(activity),
                                  ],
                                ),
                              ],
                            ) ??
                            <StaticActionGroup>[];
                      },
                      listController: listController,
                      child: Scaffold(
                        scrollable: false,
                        translucent: true,
                        header: Header(
                          title: state.context.title,
                          main: PrioritySelector(
                            selected: state.context,
                            onSelect: (p) =>
                                context.run(ChangeCurrentPriority(p)),
                          ),
                          onSearchChanged: (search) =>
                              context.read<PriorityBloc>().updateSearch(search),
                          actions: [
                            PickFilterAction(),
                            NewActivity(),
                            ShowPriorityActions(state.context, current: true),
                          ],
                        ),
                        body: BidirectionalList(
                          controller: listController,
                          scrollController: ScrollControllerContext.of(context),
                          first: state.first,
                          count: state.agendaItems.length,
                          doneStart: state.doneStart,
                          doneEnd: state.doneEnd,
                          fetcher: (first, count) => context
                              .read<PriorityBloc>()
                              .fetchMoreAgendaItems(first, count),
                          builder: (context, index, selected) {
                            final current =
                                state.agendaItems[index - state.first];
                            log.fine('Building $index: $current');

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              key: ValueKey(
                                current.when(
                                  date: (d) => 'date_${d.hashCode}',
                                  priority: (p) => 'priority_${p.id}',
                                  activity: (a) => a.id,
                                ),
                              ),
                              children: [
                                ...current.when(
                                  date: (date) => [
                                    DayHeader(
                                      key: ValueKey(
                                        'dayheader_${date.hashCode}',
                                      ),
                                      date: date,
                                      now: date == Date.today(),
                                      selected: selected,
                                    ),
                                  ],
                                  priority: (priority) => [
                                    AgendaHeader(
                                      key: ValueKey(
                                        'agendaheader_priority_${priority.id}',
                                      ),
                                      priority: priority,
                                      context: state.context,
                                      selected: selected,
                                    ),
                                  ],
                                  activity: (activity) => [
                                    if (activity.type == ActivityType.event)
                                      AgendaHeader(
                                        key: ValueKey(
                                          'agendaheader_activity_${activity.id}',
                                        ),
                                        activity: activity,
                                        context: state.context,
                                        selected: selected,
                                      ),
                                    if (activity.type != ActivityType.event)
                                      ActivityWidget(
                                        key: ValueKey(
                                          'activitywidget_${activity.id}',
                                        ),
                                        activity: activity,
                                        selected: selected,
                                        context: state.context,
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                          onReorder: (index) {
                            final item = state.agendaItems[index - state.first];
                            final activity = item.iff(
                              activity: (activity) => activity,
                            );
                            if (activity == null) {
                              return null;
                            }
                            return (int newIndex) {
                              final oldListIndex = index - state.first;
                              final newListIndex = newIndex - state.first;

                              // Update state immediately to prevent jank
                              context.read<PriorityBloc>().moveAgendaItem(
                                oldListIndex,
                                newListIndex,
                              );

                              // Then update the database asynchronously
                              var prevIndex =
                                  newListIndex -
                                  1 +
                                  (oldListIndex < newListIndex ? 1 : 0);
                              var nextIndex = prevIndex + 1;
                              AgendaItem? prev;
                              if (prevIndex >= 0) {
                                prev = state.agendaItems[prevIndex];
                              }
                              AgendaItem? next;
                              if (nextIndex < state.agendaItems.length) {
                                next = state.agendaItems[nextIndex];
                              }
                              onReorderActivity(activity, prev, next);
                            };
                          },
                        ),
                      ),
                    ),
                  );
          },
        );
      },
    );
  }

  static void onReorderActivity(
    Activity activity,
    AgendaItem? prev,
    AgendaItem? next,
  ) async {
    final prevActivity = prev?.when<Activity?>(
      date: (Date date) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final nextActivity = next?.when<Activity?>(
      date: (Date date) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final priority = prev?.when<Priority?>(
      date: (Date date) => null,
      priority: (Priority priority) => priority,
      activity: (Activity a) => a.priority,
    );
    log.info(
      'Reordering ${activity.displayTitle} between '
      '${prevActivity?.displayTitle} and ${nextActivity?.displayTitle} (${priority?.title})',
    );
    activity
        .copyWith(
          priority: priority,
          order: Order.between(prevActivity?.order, nextActivity?.order),
          on: Value(prevActivity?.on ?? nextActivity?.on),
        )
        .save();
  }
}
