import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/event.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/agenda_item.dart';
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

        return BlocProvider(
          create:
              (_) => PriorityBloc(priority: snapshot.data!, activityId: null),
          key: ValueKey(snapshot.data!.id),
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
    return FutureBuilder<Priority?>(
      future: Activity.getOne(
        activityId,
      ).then((a) => Priority.getOne(a.priorityId)),
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

        return BlocProvider(
          create:
              (_) => PriorityBloc(
                priority: snapshot.data!,
                activityId: activityId,
              ),
          key: ValueKey(snapshot.data!.id),
          child: this,
        );
      },
    );
  }
}

class _SelectionCommandScope extends StatefulWidget {
  const _SelectionCommandScope({
    required this.state,
    required this.listController,
    required this.child,
  });

  final PriorityState state;
  final BidirectionalListController listController;
  final Widget child;

  @override
  _SelectionCommandScopeState createState() => _SelectionCommandScopeState();
}

class _SelectionCommandScopeState extends State<_SelectionCommandScope> {
  @override
  void initState() {
    super.initState();
    widget.listController.addListener(_updateCommands);
  }

  @override
  void didUpdateWidget(_SelectionCommandScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listController != widget.listController) {
      oldWidget.listController.removeListener(_updateCommands);
      widget.listController.addListener(_updateCommands);
    }
  }

  @override
  void dispose() {
    widget.listController.removeListener(_updateCommands);
    super.dispose();
  }

  void _updateCommands() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CommandScope(
      commands: [
        if (widget.listController.selected != null &&
            widget.listController.selected! < widget.state.agendaItems.length)
          widget.state.agendaItems[widget.listController.selected!].when(
            activity:
                (activity) => StaticCommandGroup(
                  title: activity.title,
                  subtitle: activity.parent?.title ?? '',
                  commands: [
                    ChangeCurrentActivity(activity),
                    ...activityCommands(activity),
                  ],
                ),
            event:
                (event) => StaticCommandGroup(
                  title: event.name ?? 'Untitled Event',
                  subtitle: 'Event',
                  commands: [],
                ),
            header:
                (header) => StaticCommandGroup(
                  title: 'Header',
                  subtitle: '',
                  commands: [],
                ),
          ),
      ],
      child: widget.child,
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
                activity:
                    (activity) =>
                        context.run<void>(ChangeCurrentActivity(activity)),
                event: (event) => <void>{}, // TODO: Handle event activation
                header: (header) => <void>{}, // TODO: Handle header activation
              );
            },
            builder:
                (context, listController) => _SelectionCommandScope(
                  state: state,
                  listController: listController,
                  child: Scaffold(
                    translucent: true,
                    header: Header(
                      main: PrioritySelector(
                        selected: state.context,
                        onSelect:
                            (p) => context.run<void>(ChangeCurrentPriority(p)),
                      ),
                      commands: priorityCommands(state.context),
                    ),
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
                            child: _PinnedSection(),
                          ),
                        ),
                        Flexible(
                          flex: 1,
                          fit: FlexFit.tight,
                          child: BidirectionalList(
                            controller: listController,
                            scrollController: ScrollControllerContext.of(
                              context,
                            ),
                            count: state.agendaItems.length,
                            reverse: true,
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
                                    activity:
                                        (activity) => [
                                          ActivityWidget(
                                            activity: activity,
                                            context: null,
                                            selected: selected,
                                            onHover: onHover,
                                          ),
                                        ],
                                    event:
                                        (event) => [
                                          if (event.name?.isNotEmpty == true)
                                            EventWidget(
                                              event: event,
                                              selected: selected,
                                              onHover: onHover,
                                            ),
                                        ],
                                    header:
                                        (header) => [
                                          AgendaHeader(
                                            event: header.event,
                                            date: header.date,
                                            priorityAncestry:
                                                header.priorityAncestry,
                                            selected: selected,
                                            onHover: onHover,
                                          ),
                                        ],
                                  ),
                                ],
                              );
                            },
                            onReorder:
                                (oldIndex, newIndex) => onReorder(
                                  state.agendaItems,
                                  oldIndex,
                                  newIndex,
                                ),
                          ),
                        ),
                      ],
                    ),
                    footer: EditableArea(
                      position: EditableAreaPosition.bottom,
                      builder:
                          (context, focusNode) => Editor(
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
                                doAt:
                                    alt
                                        ? Value(Date.today())
                                        : const Value.absent(),
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
              doAt:
                  activity.doNow
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

class _PinnedSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (state.pinned.isEmpty) {
          return const SizedBox();
        }
        return Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(width: 1.0, color: context.colour.border),
            ),
          ),
          child: Column(
            children: [
              ReorderableListView<AgendaItem>(
                list: state.pinned,
                itemBuilder:
                    (buildContext, item) => item.when(
                      activity:
                          (activity) =>
                              ActivityWidget(activity: activity, context: null),
                      event: (event) => EventWidget(event: event),
                      header:
                          (header) => AgendaHeader(
                            event: header.event,
                            date: header.date,
                            priorityAncestry: header.priorityAncestry,
                          ),
                    ),
                shrinkWrap: true,
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

                  final currentItem = state.pinned[oldIndex];
                  // Only handle activity reordering for now
                  currentItem.when(
                    activity: (activity) async {
                      Activity? previous;
                      if (previousIndex >= 0) {
                        final prevItem = state.pinned[previousIndex];
                        prevItem.when(
                          activity: (a) => previous = a,
                          event: (_) => previous = null,
                          header: (_) => previous = null,
                        );
                      }
                      Activity? next;
                      if (nextIndex < state.pinned.length) {
                        final nextItem = state.pinned[nextIndex];
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
                              previous?.doAt == null ||
                                      next?.doAt == previous?.doAt
                                  ? next?.order
                                  : null,
                            ),
                            // Action state.pinned are sorted first by doAt, so we need to set this
                            // to have the same doAt as one of its neighbours.
                            doAt:
                                activity.doNow
                                    ? Value(
                                      previous?.doAt ??
                                          next?.doAt ??
                                          activity.doAt,
                                    )
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
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
