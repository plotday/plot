import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
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
    priorityId =
        priority?.id ??
        priorityId ??
        (priorityIdString != null
            ? PriorityId.fromShortString(priorityIdString)
            : null);
    assert(
      priorityId != null,
      'A priority must be provided via one of the parameters: priority, priorityId, or priorityIdString.',
    );
    this.priorityId = priorityId!;
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
          create: (_) => PriorityBloc(priority: snapshot.data!),
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
            priority: (priority) => StaticCommandGroup(
              title: priority.title,
              subtitle: priority.ancestorsLabel(),
              commands: [
                if (priority != widget.state.context)
                  ChangeCurrentPriority(priority),
                ...priorityCommands(priority),
              ],
            ),
            event: (event) => StaticCommandGroup(
              title: event.name ?? 'Untitled Event',
              subtitle: 'Event',
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
                priority: (priority) => context.run<void>(ChangeCurrentPriority(priority)),
                event: (event) => <void>{}, // TODO: Handle event activation
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
                              final next = index < state.agendaItems.length - 1
                                  ? state.agendaItems[index + 1]
                                  : null;
                              final scheduled = index < state.scheduled.length;
                              final firstScheduled =
                                  index == state.scheduled.length - 1;
                              
                              return current.when(
                                priority: (priority) {
                                  final date = scheduled
                                      ? priority.doAt!
                                      : priority.createdAt.toDate();
                                  final nextDate = next?.when(
                                    priority: (nextPriority) => (index + 1 < state.scheduled.length
                                        ? nextPriority.doAt
                                        : nextPriority.createdAt.toDate()),
                                    event: (nextEvent) => nextEvent.start.toDate(),
                                  );
                                  final hidden = !scheduled &&
                                      priority.createdAt.toDate() == priority.doAt;
                                  
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    key: ValueKey(priority.id),
                                    children: [
                                      if (nextDate != date)
                                        Text(
                                          date.format(),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: context
                                                .theme
                                                .colors
                                                .mutedForeground,
                                            fontSize: context
                                                .theme
                                                .typography
                                                .xs
                                                .fontSize,
                                          ),
                                        ),
                                      if (firstScheduled)
                                        Text(
                                          'NOW',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: context
                                                .theme
                                                .colors
                                                .mutedForeground,
                                            fontSize: context
                                                .theme
                                                .typography
                                                .xs
                                                .fontSize,
                                          ),
                                        ),
                                      if (!hidden)
                                        PriorityWidget(
                                          priority: priority,
                                          context: state.context,
                                          selected: selected,
                                          onHover: (hovered) {
                                            if (hovered) {
                                              listController.selected = index;
                                            } else if (listController.selected ==
                                                index) {
                                              listController.selected = null;
                                            }
                                          },
                                        ),
                                    ],
                                  );
                                },
                                event: (event) {
                                  final date = event.start.toDate();
                                  final nextDate = next?.when(
                                    priority: (nextPriority) => (index + 1 < state.scheduled.length
                                        ? nextPriority.doAt
                                        : nextPriority.createdAt.toDate()),
                                    event: (nextEvent) => nextEvent.start.toDate(),
                                  );
                                  
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    key: ValueKey(event.id),
                                    children: [
                                      if (nextDate != date)
                                        Text(
                                          date.format(),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: context
                                                .theme
                                                .colors
                                                .mutedForeground,
                                            fontSize: context
                                                .theme
                                                .typography
                                                .xs
                                                .fontSize,
                                          ),
                                        ),
                                      // TODO: Add EventWidget here when it's available
                                      Text('Event: ${event.name ?? 'Untitled'}'),
                                    ],
                                  );
                                },
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
                            hint: 'Add a priority',
                            autofocus: true,
                            focusNode: focusNode,
                            onSubmitted: (body) async {
                              final priority = state.draft.copyWith(
                                note: Value(body),
                                draft: false,
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
    // Only reorder Priority items for now
    currentItem.when(
      priority: (priority) async {
        Priority? previous;
        if (previousIndex >= 0) {
          final prevItem = agendaItems[previousIndex];
          prevItem.when(
            priority: (p) => previous = p,
            event: (_) => previous = null,
          );
        }
        Priority? next;
        if (nextIndex < agendaItems.length) {
          final nextItem = agendaItems[nextIndex];
          nextItem.when(
            priority: (p) => next = p,
            event: (_) => next = null,
          );
        }
        priority
            .copyWith(
              order: Order.between(
                previous?.order,
                previous?.doAt == null || next?.doAt == previous?.doAt
                    ? next?.order
                    : null,
              ),
              // Action priorities are sorted first by doAt, so we need to set this
              // to have the same doAt as one of its neighbours.
              doAt:
                  priority.doNow
                      ? Value(previous?.doAt ?? next?.doAt ?? priority.doAt)
                      : const Value.absent(),
            )
            .save();
      },
      event: (_) {
        // TODO: Handle event reordering
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
                itemBuilder: (buildContext, item) => item.when(
                  priority: (priority) => PriorityWidget(
                    priority: priority,
                    context: state.context,
                  ),
                  event: (event) => Text('Event: ${event.name ?? 'Untitled'}'), // TODO: EventWidget
                ),
                shrinkWrap: true,
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                  
                  final currentItem = state.pinned[oldIndex];
                  // Only handle priority reordering for now
                  currentItem.when(
                    priority: (priority) async {
                      Priority? previous;
                      if (previousIndex >= 0) {
                        final prevItem = state.pinned[previousIndex];
                        prevItem.when(
                          priority: (p) => previous = p,
                          event: (_) => previous = null,
                        );
                      }
                      Priority? next;
                      if (nextIndex < state.pinned.length) {
                        final nextItem = state.pinned[nextIndex];
                        nextItem.when(
                          priority: (p) => next = p,
                          event: (_) => next = null,
                        );
                      }
                      priority
                          .copyWith(
                            order: Order.between(
                              previous?.order,
                              previous?.doAt == null || next?.doAt == previous?.doAt
                                  ? next?.order
                                  : null,
                            ),
                            // Action state.pinned are sorted first by doAt, so we need to set this
                            // to have the same doAt as one of its neighbours.
                            doAt:
                                priority.doNow
                                    ? Value(
                                      previous?.doAt ?? next?.doAt ?? priority.doAt,
                                    )
                                    : const Value.absent(),
                          )
                          .save();
                    },
                    event: (_) {
                      // TODO: Handle event reordering
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
