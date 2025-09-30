import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'priorities.dart';
import 'logging.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    this.priority,
    PriorityId? priorityId,
    @PathParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId =
           priority?.id ??
           priorityId ??
           (priorityIdString != null
               ? PriorityId.fromShortString(priorityIdString)
               : null) {
    assert(this.priorityId != null, 'A priority must be provided.');
  }

  late final PriorityId? priorityId;
  late final Priority? priority;

  @override
  Widget wrappedRoute(BuildContext context) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      priority: null, // Let the bloc load the priority
      child: BlocConsumer<PriorityBloc, PriorityState>(
        listener: (context, state) {
          context.read<NowBloc>().setPriority(state.context);
        },
        builder: (context, state) {
          return BlocBuilder<LayoutBloc, LayoutState>(
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
            return CommandScope(
              commands: [
                StaticCommandGroup(
                  title: state.context.title,
                  commands: priorityCommands(state.context),
                ),
              ],
              child:
                  (state.agendaItems.isEmpty &&
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
                      builder: (context, listController) => SelectionCommandScope(
                        commandBuilder: (index) {
                          final item =
                              index >= state.first &&
                                  index - state.first < state.agendaItems.length
                              ? state.agendaItems[index - state.first]
                              : null;
                          return item?.iff(
                                activity: (activity) => [
                                  StaticCommandGroup(
                                    title: activity.displayTitle,
                                    commands: [
                                      OpenActivity(activity),
                                      ...activityCommands(activity),
                                    ],
                                  ),
                                ],
                              ) ??
                              <StaticCommandGroup>[];
                        },
                        listController: listController,
                        child: Scaffold(
                          translucent: true,
                          header: Header(
                            title: state.activity?.displayTitle,
                            main: state.activity == null
                                ? PrioritySelector(
                                    selected: state.context,
                                    onSelect: (p) =>
                                        context.run(ChangeCurrentPriority(p)),
                                  )
                                : null,
                            commands: [
                              PickFilterCommand(),
                              ShowPriorityCommands(
                                state.context,
                                current: true,
                              ),
                            ],
                          ),
                          body: LayoutBuilder(
                            builder: (context, constraints) {
                              final maxActivityEditorHeight =
                                  constraints.maxHeight * 0.4;
                              return Column(
                                children: [
                                  Flexible(
                                    flex: 1,
                                    fit: FlexFit.tight,
                                    child: BidirectionalList(
                                      controller: listController,
                                      scrollController:
                                          ScrollControllerContext.of(context),
                                      first: state.first,
                                      count: state.agendaItems.length,
                                      doneStart: state.doneStart,
                                      doneEnd: state.doneEnd,
                                      fetcher: (first, count) => context
                                          .read<PriorityBloc>()
                                          .fetchMoreAgendaItems(first, count),
                                      builder: (context, index, selected) {
                                        final current = state
                                            .agendaItems[index - state.first];
                                        log.fine('Building $index: $current');

                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          key: ValueKey(
                                            current.when(
                                              date: (d) => 'date_${d.hashCode}',
                                              priority: (p) =>
                                                  'priority_${p.id}',
                                              activity: (a) => a.id,
                                            ),
                                          ),
                                          children: [
                                            ...current.when(
                                              date: (date) => [
                                                DayHeader(
                                                  date: date,
                                                  now: date == Date.today(),
                                                  selected: selected,
                                                ),
                                              ],
                                              priority: (priority) => [
                                                AgendaHeader(
                                                  priority: priority,
                                                  context: state.context,
                                                  selected: selected,
                                                ),
                                              ],
                                              activity: (activity) => [
                                                if (activity.type ==
                                                    ActivityType.event)
                                                  AgendaHeader(
                                                    activity: activity,
                                                    context: state.context,
                                                    selected: selected,
                                                  ),
                                                if (activity.type !=
                                                    ActivityType.event)
                                                  ActivityWidget(
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
                                        final item = state
                                            .agendaItems[index - state.first];
                                        final activity = item.iff(
                                          activity: (activity) => activity,
                                        );
                                        if (activity == null) {
                                          return null;
                                        }
                                        return (int newIndex) {
                                          final oldListIndex =
                                              index - state.first;
                                          final newListIndex =
                                              newIndex - state.first;

                                          // Update state immediately to prevent jank
                                          context
                                              .read<PriorityBloc>()
                                              .moveAgendaItem(
                                                oldListIndex,
                                                newListIndex,
                                              );

                                          // Then update the database asynchronously
                                          var prevIndex =
                                              newListIndex -
                                              1 +
                                              (oldListIndex < newListIndex
                                                  ? 1
                                                  : 0);
                                          var nextIndex = prevIndex + 1;
                                          AgendaItem? prev;
                                          if (prevIndex >= 0) {
                                            prev = state.agendaItems[prevIndex];
                                          }
                                          AgendaItem? next;
                                          if (nextIndex <
                                              state.agendaItems.length) {
                                            next = state.agendaItems[nextIndex];
                                          }
                                          onReorderActivity(
                                            activity,
                                            prev,
                                            next,
                                          );
                                        };
                                      },
                                    ),
                                  ),
                                  Container(
                                    constraints: BoxConstraints(
                                      maxHeight: maxActivityEditorHeight,
                                    ),
                                    child: ActivityEditor(
                                      onAdd: (activity) => context
                                          .read<PriorityBloc>()
                                          .add(activity),
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
