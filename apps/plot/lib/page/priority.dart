import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

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
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, prioritiesState) {
            return Scaffold(
              translucent: true,
              header: Header(
                main: PrioritySelector(
                  selected: state.current,
                  onSelect: (p) => context.run<void>(ChangeCurrentPriority(p)),
                ),
                commands: [
                  ArchivePriority(Future.value(state.current)),
                  ShowSchedule(),
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
                      child: _PrioritiesSection(),
                    ),
                  ),
                  Flexible(
                    flex: 1,
                    fit: FlexFit.tight,
                    child: BidirectionalList(
                      scrollController: ScrollControllerContext.of(context),
                      count: state.inactive.length,
                      reverse: true,
                      builder:
                          (context, index) =>
                              PriorityWidget(priority: state.inactive[index]),
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
            );
          },
        );
      },
    );
  }
}

class _PrioritiesSection extends StatelessWidget {
  const _PrioritiesSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (state.pinned.isEmpty && state.active.isEmpty) {
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
              _ReorderableView(priorities: state.pinned),
              _ReorderableView(priorities: state.active),
            ],
          ),
        );
      },
    );
  }
}

class _ReorderableView extends StatelessWidget {
  const _ReorderableView({required this.priorities});

  final List<Priority> priorities;

  @override
  Widget build(BuildContext context) => ReorderableListView(
    list: priorities,
    itemBuilder: (buildContext, item) => PriorityWidget(priority: item),
    shrinkWrap: true,
    onReorder: (int oldIndex, int newIndex) async {
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
    },
  );
}
