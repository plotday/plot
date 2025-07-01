import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_list.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/agenda_item.dart';
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
          child: BidirectionalListSelector(
            onActivate: (index) {
              state.agendaItems[index].when(
                activity: (activity) =>
                    context.run<void>(ChangeCurrentActivity(activity)),
                event: (event) => <void>{}, // TODO: Handle event activation
                header: (header) => <void>{}, // TODO: Handle header activation
              );
            },
            builder: (context, listController) => SelectionCommandScope(
              commandBuilder: (index) =>
                  state
                      .atIndex(index)
                      ?.when(
                        activity: (activity) => [
                          StaticCommandGroup(
                            title: activity.title,
                            commands: [
                              ChangeCurrentActivity(activity),
                              ...activityCommands(activity),
                            ],
                          ),
                        ],
                        event: (event) => [],
                        header: (header) => [],
                      ) ??
                  [],
              listController: listController,
              child: Scaffold(
                translucent: true,
                header: Header(
                  title: state.activity?.title,
                  main: state.activity == null
                      ? PrioritySelector(
                          selected: state.context,
                          onSelect: (p) =>
                              context.run<void>(ChangeCurrentPriority(p)),
                        )
                      : null,
                  commands: [
                    ...currentPriorityCommands(state.context),
                    ToggleShowArchived(showArchived: state.showArchived),
                  ],
                ),
                sidebar: PrioritiesSidebar(),
                body: Column(
                  children: [
                    Flexible(
                      flex: 0,
                      fit: FlexFit.loose,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 1.0,
                              color: context.colour.border,
                            ),
                          ),
                        ),
                        child: ActivityList(
                          activities: state.pinned
                              .where(
                                (item) => item.when(
                                  activity: (_) => true,
                                  event: (_) => false,
                                  header: (_) => false,
                                ),
                              )
                              .map(
                                (item) => item.when(
                                  activity: (activity) => activity,
                                  event: (_) =>
                                      throw StateError('Not an activity'),
                                  header: (_) =>
                                      throw StateError('Not an activity'),
                                ),
                              )
                              .toList(),
                          priority: state.context,
                        ),
                      ),
                    ),
                    Flexible(
                      flex: 1,
                      fit: FlexFit.tight,
                      child: BidirectionalList(
                        controller: listController,
                        scrollController: ScrollControllerContext.of(context),
                        first: state.first,
                        count: state.agendaItems.length,
                        anchor: state.anchorIndex,
                        anchorOffset: 0.8,
                        doneStart: state.doneStart,
                        doneEnd: state.doneEnd,
                        fetcher: (first, count) => context
                            .read<PriorityBloc>()
                            .fetchMoreAgendaItems(first, count),
                        builder: (context, index, selected) {
                          final current =
                              state.agendaItems[index - state.first];
                          log.fine('Building $index: $current');
                          void onHover(bool hovered) {
                            if (hovered) {
                              listController.selected = index;
                            } else if (listController.selected == index) {
                              listController.selected = null;
                            }
                          }

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            key: ValueKey(
                              current.when(
                                activity: (a) => a.id,
                                event: (e) => e.id,
                                header: (h) => 'header_${h.hashCode}',
                              ),
                            ),
                            children: [
                              ...current.when(
                                activity: (activity) => [
                                  ActivityWidget(
                                    activity: activity,
                                    selected: selected,
                                    onHover: onHover,
                                  ),
                                ],
                                event: (event) => [
                                  if (event.name?.isNotEmpty == true)
                                    EventWidget(
                                      event: event,
                                      selected: selected,
                                      onHover: onHover,
                                    ),
                                ],
                                header: (header) => [
                                  AgendaHeader(
                                    event: header.event,
                                    date: header.date,
                                    now: header.now,
                                    priority: header.priority,
                                    context: state.context,
                                    selected: selected,
                                    onHover: onHover,
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                        onReorder: (index) {
                          final item = state.agendaItems[index - state.first];
                          if (!item.when(
                            activity: (activity) => true,
                            event: (_) => false,
                            header: (_) => false,
                          )) {
                            return null;
                          }
                          return (int newIndex) {
                            newIndex -= state.first;
                            var prevIndex = newIndex;
                            var nextIndex = newIndex - 1;
                            AgendaItem? prev;
                            if (prevIndex >= 0) {
                              prev = state.agendaItems[prevIndex];
                            }
                            AgendaItem? next;
                            if (nextIndex < state.agendaItems.length) {
                              next = state.agendaItems[nextIndex];
                            }
                            onReorderActivity(
                              (item as ActivityAgendaItem).activity,
                              prev,
                              next,
                            );
                          };
                        },
                      ),
                    ),
                    EditableArea(
                      position: EditableAreaPosition.bottom,
                      builder: (context, focusNode) => Editor(
                        hint: 'Add activity',
                        autofocus: true,
                        focusNode: focusNode,
                        onSubmitted: (body, {bool alt = false}) async {
                          log.info(
                            'Adding new priority with body: $body ($alt)',
                          );
                          final priority = state.draft.copyWith(
                            note: Value(body),
                            draft: false,
                            doAt: alt
                                ? Value(Date.today())
                                : const Value.absent(),
                          );
                          await context.read<PriorityBloc>().add(priority);
                        },
                      ),
                    ),
                  ],
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
    final prevActivity = prev?.when(
      activity: (a) => a,
      event: (_) => null,
      header: (_) => null,
    );
    final nextActivity = next?.when(
      activity: (a) => a,
      event: (_) => null,
      header: (_) => null,
    );
    final priorityId = prev?.when(
      activity: (a) => a.priorityId,
      event: (e) => e.priorityId,
      header: (h) => h.priority?.id,
    );
    final eventSeries = prev?.when(
      activity: (a) => a.eventSeries,
      event: (e) => e.series,
      header: (h) => h.event?.series,
    );
    log.info(
      'Reordering ${activity.title} between '
      '${prevActivity?.title} and ${nextActivity?.title}',
    );
    activity
        .copyWith(
          priorityId: priorityId,
          order: Order.between(prevActivity?.order, nextActivity?.order),
          doAt: Value((prevActivity ?? nextActivity)?.doAt),
          eventSeries: Value(eventSeries),
        )
        .save();
  }
}
