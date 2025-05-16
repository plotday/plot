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

@RoutePage(name: "PriorityMainRoute")
class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return BidirectionalListSelector(
          builder:
              (context, listController) => CommandScope(
                commands: [
                  StaticCommandGroup(
                    title: state.context.title,
                    commands: [
                      if (state.context.root)
                        ChangeCurrentPriority(state.context),
                      if (!state.context.root) PinPriority(state.context),
                      ArchivePriority(Future.value(state.context)),
                    ],
                  ),
                ],
                child: Scaffold(
                  translucent: true,
                  header: Header(
                    main: PrioritySelector(
                      selected: state.context,
                      onSelect:
                          (p) => context.run<void>(ChangeCurrentPriority(p)),
                    ),
                    commands: [
                      if (!state.context.root)
                        ArchivePriority(Future.value(state.context)),
                    ],
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
                          scrollController: ScrollControllerContext.of(context),
                          count: state.priorities.length,
                          reverse: true,
                          builder: (context, index, selected) {
                            final previous =
                                index > 0 ? state.priorities[index - 1] : null;
                            final current = state.priorities[index];
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              key: ValueKey(state.priorities[index].id),
                              children: [
                                if (previous?.createdAt.toDate() !=
                                    current.createdAt.toDate())
                                  Text(
                                    state.priorities[index].createdAt
                                        .toDate()
                                        .format(),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color:
                                          context
                                              .theme
                                              .colorScheme
                                              .mutedForeground,
                                      fontSize:
                                          context.theme.typography.xs.fontSize,
                                    ),
                                  ),
                                PriorityWidget(
                                  priority: state.priorities[index],
                                  context: state.context,
                                  selected: selected,
                                ),
                              ],
                            );
                          },
                          onReorder:
                              (oldIndex, newIndex) => onReorder(
                                state.priorities,
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
        );
      },
    );
  }

  static void onReorder(
    List<Priority> priorities,
    int oldIndex,
    int newIndex,
  ) async {
    var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
    var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
    Priority priority = priorities[oldIndex];
    Priority? previous;
    if (previousIndex >= 0) {
      previous = priorities[previousIndex];
    }
    Priority? next;
    if (nextIndex < priorities.length) {
      next = priorities[nextIndex];
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
              ReorderableListView(
                list: state.pinned,
                itemBuilder:
                    (buildContext, item) =>
                        PriorityWidget(priority: item, context: state.context),
                shrinkWrap: true,
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                  Priority priority = state.pinned[oldIndex];
                  Priority? previous;
                  if (previousIndex >= 0) {
                    previous = state.pinned[previousIndex];
                  }
                  Priority? next;
                  if (nextIndex < state.pinned.length) {
                    next = state.pinned[nextIndex];
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
              ),
            ],
          ),
        );
      },
    );
  }
}
