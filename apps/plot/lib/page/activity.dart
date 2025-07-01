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

@RoutePage(name: "EventRoute")
class EventWrapper extends AutoRouter implements AutoRouteWrapper {
  EventWrapper({
    Event? event,
    EventId? eventId,
    @PathParam("eventId") String? eventIdString,
    super.key,
  }) {
    final resolvedEventId =
        event?.id ??
        eventId ??
        (eventIdString != null ? EventId.fromShortString(eventIdString) : null);
    assert(resolvedEventId != null, 'An event must be provided.');
    this.eventId = resolvedEventId!;
  }

  late final EventId eventId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return FutureBuilder<(Priority, Event)>(
      future: Event.getOne(eventId, withPriority: true).then((event) async {
        final priority =
            event.priority ?? await Priority.getOne(event.priorityId!);
        return (priority, event);
      }),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          log.warning(
            "Failed to load Priority and Event",
            snapshot.error,
            snapshot.stackTrace,
          );
        }
        if (!snapshot.hasData) {
          return const LoadingPage();
        }

        final (priority, event) = snapshot.data!;

        // Set the current priority in NowBloc when entering this route
        WidgetsBinding.instance.addPostFrameCallback((_) {
          log.info(
            'Setting current priority to ${priority.title} (from event ${event.name ?? "Untitled Event"})',
          );
          context.read<NowBloc>().setPriority(priority);
        });

        return BlocProvider(
          create: (_) => PriorityBloc(priority: priority, event: event),
          key: ValueKey(event.id),
          child: this,
        );
      },
    );
  }
}

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
    return FutureBuilder<(Priority, Activity)>(
      future: Activity.getOne(activityId).then((activity) async {
        final priority = await Priority.getOne(activity.priorityId);
        return (priority, activity);
      }),
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

        final (priority, activity) = snapshot.data!;

        // Set the current priority in NowBloc when entering this route
        WidgetsBinding.instance.addPostFrameCallback((_) {
          log.info(
            'Setting current priority to ${priority.title} (from activity ${activity.title})',
          );
          context.read<NowBloc>().setPriority(priority);
        });

        return BlocProvider(
          create: (_) => PriorityBloc(priority: priority, activity: activity),
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
                  title: state.activity?.title ?? state.event?.name,
                  main: state.activity == null && state.event == null
                      ? PrioritySelector(
                          selected: state.context,
                          onSelect: (p) =>
                              context.run<void>(ChangeCurrentPriority(p)),
                        )
                      : null,
                  commands: [
                    ...activityCommands(state.activity!),
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
                                  ActivityDetailWidget(
                                    activity: activity,
                                    context: null,
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
                      ),
                    ),
                    EditableArea(
                      position: EditableAreaPosition.bottom,
                      builder: (context, focusNode) => Editor(
                        hint: 'Add activity',
                        autofocus: true,
                        focusNode: focusNode,
                        onSubmitted: (body, {bool alt = false}) async {
                          log.info('Adding new activity with body: $body ($alt)');
                          final activity = state.draft.copyWith(
                            note: Value(body),
                            draft: false,
                            doAt: alt ? Value(Date.today()) : const Value.absent(),
                          );
                          await context.read<PriorityBloc>().add(activity);
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
}
