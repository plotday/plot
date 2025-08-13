import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/command/command.dart';
import 'loading.dart';
import 'logging.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    Priority? priority,
    PriorityId? priorityId,
    @PathParam("priorityId") String? priorityIdString,
    super.key,
  }) {
    final resolvedPriorityId =
        priority?.id ??
        priorityId ??
        (priorityIdString != null
            ? PriorityId.fromShortString(priorityIdString)
            : null);
    assert(resolvedPriorityId != null, 'A priority must be provided.');
    this.priorityId = resolvedPriorityId!;
  }

  late final PriorityId priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return FutureBuilder<Priority?>(
      future: Priority.getOne(priorityId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          log.warning(
            "Failed to load Priority",
            snapshot.error,
            snapshot.stackTrace,
          );
        }
        if (!snapshot.hasData) {
          return const LoadingPage();
        }

        final priority = snapshot.data!;

        // Set the current priority in NowBloc when entering this route
        WidgetsBinding.instance.addPostFrameCallback((_) {
          log.info('Setting current priority to ${priority.title}');
          context.read<NowBloc>().setPriority(priority);
        });

        return BlocProvider(
          create: (_) => PriorityBloc(priority: priority, activity: null),
          key: ValueKey(priority.id),
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
        return CommandScope(
          commands: [
            StaticCommandGroup(
              title: state.context.title,
              commands: priorityCommands(state.context),
            ),
          ],
          child:
              state.agendaItems.isEmpty && !(state.doneStart && state.doneEnd)
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
                          ...currentPriorityCommands(state.context),
                          PickFilterCommand(),
                        ],
                      ),
                      sidebar: PrioritiesSidebar(selected: state.context),
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
                                  scrollController: ScrollControllerContext.of(
                                    context,
                                  ),
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
                                          event: (e) => 'event_${e.id}',
                                          priority: (p) => 'priority_${p.id}',
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
                                          event: (event) => [
                                            AgendaHeader(
                                              event: event,
                                              priority: event.priority,
                                              context: state.context,
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
                                    final item =
                                        state.agendaItems[index - state.first];
                                    final activity = item.iff(
                                      activity: (activity) => activity,
                                    );
                                    if (activity == null) {
                                      return null;
                                    }
                                    return (int newIndex) {
                                      final oldListIndex = index - state.first;
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
                                          (oldListIndex < newListIndex ? 1 : 0);
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
                                      onReorderActivity(activity, prev, next);
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
  }

  static void onReorderActivity(
    Activity activity,
    AgendaItem? prev,
    AgendaItem? next,
  ) async {
    final prevActivity = prev?.when<Activity?>(
      date: (Date date) => null,
      event: (Event event) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final nextActivity = next?.when<Activity?>(
      date: (Date date) => null,
      event: (Event event) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final priorityId = prev?.when<PriorityId?>(
      date: (Date date) => null,
      event: (Event event) => event.priorityId,
      priority: (Priority priority) => priority.id,
      activity: (Activity a) => a.priorityId,
    );
    final eventSeries = prev?.when<String?>(
      date: (Date date) => null,
      event: (Event event) => event.series,
      priority: (Priority priority) => null,
      activity: (Activity a) => a.eventSeries,
    );
    log.info(
      'Reordering ${activity.displayTitle} between '
      '${prevActivity?.displayTitle} and ${nextActivity?.displayTitle} ($priorityId, $eventSeries)',
    );
    activity
        .copyWith(
          priorityId: priorityId,
          order: Order.between(prevActivity?.order, nextActivity?.order),
          doOn: Value((prevActivity ?? nextActivity)?.doOn),
          eventSeries: Value(eventSeries),
        )
        .save();
  }
}
