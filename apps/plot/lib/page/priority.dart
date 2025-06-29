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
            reverse: true,
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
                        anchorOffset: 0.0,
                        reverse: true,
                        doneStart: state.doneStart,
                        doneEnd: state.doneEnd,
                        fetcher: (first, count) => context
                            .read<PriorityBloc>()
                            .fetchMoreAgendaItems(first, count),
                        builder: (context, index, selected) {
                          final current = state.agendaItems[index];
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
                        onReorder: (index) =>
                            state.agendaItems[index - state.first].when(
                              activity: (activity) => activity.scheduled
                                  ? (int oldIndex, int newIndex) => onReorder(
                                      state.agendaItems,
                                      oldIndex,
                                      newIndex,
                                    )
                                  : null,
                              event: (_) => null,
                              header: (_) => null,
                            ),
                      ),
                    ),
                  ],
                ),
                footer: EditableArea(
                  position: EditableAreaPosition.bottom,
                  builder: (context, focusNode) => Editor(
                    hint: 'Add activity',
                    autofocus: true,
                    focusNode: focusNode,
                    onSubmitted: (body, {bool alt = false}) async {
                      log.info('Adding new priority with body: $body ($alt)');
                      final priority = state.draft.copyWith(
                        note: Value(body),
                        draft: false,
                        doAt: alt ? Value(Date.today()) : const Value.absent(),
                      );
                      await context.read<PriorityBloc>().add(priority);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static void onReorder(
    List<AgendaItem> agendaItems,
    int oldIndex,
    int newIndex,
  ) async {
    var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
    var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

    final currentItem = agendaItems[oldIndex];
    // Only reorder Activity items for now
    currentItem.when(
      activity: (activity) async {
        Activity? previous;
        if (previousIndex >= 0) {
          final prevItem = agendaItems[previousIndex];
          prevItem.when(
            activity: (a) => previous = a,
            event: (_) => previous = null,
            header: (_) => previous = null,
          );
        }
        Activity? next;
        if (nextIndex < agendaItems.length) {
          final nextItem = agendaItems[nextIndex];
          nextItem.when(
            activity: (a) => next = a,
            event: (_) => next = null,
            header: (_) => next = null,
          );
        }
        activity
            .copyWith(
              order: Order.between(
                previous?.order,
                previous?.doAt == null || next?.doAt == previous?.doAt
                    ? next?.order
                    : null,
              ),
              // Action activities are sorted first by doAt, so we need to set this
              // to have the same doAt as one of its neighbours.
              doAt: activity.doNow
                  ? Value(previous?.doAt ?? next?.doAt ?? activity.doAt)
                  : const Value.absent(),
            )
            .save();
      },
      event: (_) {
        // TODO: Handle event reordering
      },
      header: (_) {
        // Headers cannot be reordered
      },
    );
  }
}
