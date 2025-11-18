import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/action/action.dart';
import 'package:plot/router.dart';
import 'priorities.dart';
import 'loading.dart';
import 'logging.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required String priorityIdString})
    : priorityId = PriorityId.fromShortString(priorityIdString);

  final PriorityId priorityId;
  static final Map<PriorityId, GlobalKey> _routerKeys = {};
  static GlobalKey _getRouterKey(PriorityId priorityId) {
    return _routerKeys.putIfAbsent(
      priorityId,
      () => GlobalKey(
        debugLabel: 'PriorityWrapper_${priorityId.toShortString()}',
      ),
    );
  }

  @override
  Widget wrappedRoute(BuildContext context) {
    final routerKey = _getRouterKey(priorityId);

    return PriorityBlocProvider(
      priorityId: priorityId,
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          return ActionScope(
            actions: [
              StaticActionGroup(
                title: state.context.title,
                actions: currentPriorityActions(state.context),
              ),
            ],
            child: ResizablePanelLayout(
              left: PrioritiesPage(),
              middle: PriorityPage(priorityId: priorityId),
              child: AutoRouter(
                key: routerKey,
                placeholder: (context) => const LoadingPage(),
              ),
            ),
          );
        },
      ),
    );
  }
}

@RoutePage(name: "PriorityOnlyRoute")
class PriorityOnlyPage extends StatefulWidget implements AutoRouteWrapper {
  PriorityOnlyPage({
    @PathParam.inherit("priorityId") required String priorityIdString,
    super.key,
  }) : priorityId = PriorityId.fromShortString(priorityIdString);

  final PriorityId priorityId;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();

  @override
  Widget wrappedRoute(BuildContext context) {
    return this;
  }
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  bool _hasNavigated = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<LayoutBloc, LayoutState>(
      listener: (context, layoutState) {
        if (layoutState.middlePanelVisible && !_hasNavigated) {
          _hasNavigated = true;
          context.router.navigate(NewActivityRoute());
        }
      },
      builder: (context, layoutState) {
        if (layoutState.middlePanelVisible) {
          return const LoadingPage();
        }
        return PriorityPage(priorityId: widget.priorityId);
      },
    );
  }
}

class PriorityPage extends StatelessWidget {
  const PriorityPage({required this.priorityId, super.key});

  final PriorityId priorityId;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PriorityBloc, PriorityState>(
      listener: (context, state) {
        context.read<NowBloc>().setPriority(state.context);
      },
      listenWhen: (previous, current) =>
          previous.context.id != current.context.id,
      builder: (context, state) {
        // Find the index of the current activity in the agenda items
        int? selected;
        if (state.activity != null) {
          for (int i = 0; i < state.agendaItems.length; i++) {
            final activity = state.agendaItems[i].iff<Activity>(
              activity: (a) => a,
            );
            if (activity?.id == state.activity!.id) {
              selected = state.first + i;
              break;
            }
          }
        }

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
                          priority: (priority) {
                            // Skip if this is the context priority (already added by outer ActionScope)
                            if (priority.id == state.context.id) {
                              return <StaticActionGroup>[];
                            }
                            return [
                              StaticActionGroup(
                                title: priority.title,
                                actions: priorityActions(priority),
                              ),
                            ];
                          },
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
                        onSelect: (p) => context.run(ChangeCurrentPriority(p)),
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
                      builder: (context, index, highlighted) {
                        final current = state.agendaItems[index - state.first];
                        log.fine('Building $index: $current');

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          key: ValueKey(
                            current.when(
                              date: (d) => 'date_${d.toString()}',
                              priority: (p) => 'priority_${p.id}',
                              activity: (a) => a.id,
                            ),
                          ),
                          children: [
                            ...current.when(
                              date: (date) => [
                                DayHeader(
                                  key: ValueKey('dayheader_${date.toString()}'),
                                  date: date,
                                  now: date == Date.today(),
                                  highlighted: highlighted,
                                ),
                              ],
                              priority: (priority) => [
                                AgendaHeader(
                                  key: ValueKey(
                                    'agendaheader_priority_${priority.id}',
                                  ),
                                  priority: priority,
                                  context: state.context,
                                  highlighted: highlighted,
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
                                    highlighted: highlighted,
                                  ),
                                if (activity.type != ActivityType.event)
                                  ActivityWidget(
                                    key: ValueKey(
                                      'activitywidget_${activity.id}',
                                    ),
                                    activity: activity,
                                    highlighted: highlighted,
                                    selected: selected == index,
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
