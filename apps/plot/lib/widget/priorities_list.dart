import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/reorderable_list_view.dart' as custom;

class PrioritiesList extends StatelessWidget {
  final List<Priority> priorities;
  final void Function(Priority)? onPrioritySelected;
  final bool isCompact;
  final ReorderCallback? onReorder;

  const PrioritiesList({
    super.key,
    required this.priorities,
    this.onPrioritySelected,
    this.isCompact = false,
    this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (priorities.isEmpty) {
          return Center(child: Text('No priorities found'));
        }

        return custom.ReorderableListView<Priority>(
          list: priorities,
          itemBuilder: (context, priority) {
            final isSelected = state.context.id == priority.id;
            return GestureDetector(
              key: ValueKey(priority.id),
              onTap: () {
                if (onPrioritySelected != null) {
                  onPrioritySelected!(priority);
                } else {
                  context.run<void>(ChangeCurrentPriority(priority));
                }
              },
              child: PriorityWidget(priority: priority, selected: isSelected),
            );
          },
          onReorder:
              onReorder ??
              (oldIndex, newIndex) {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

                final currentPriority = priorities[oldIndex];
                Priority? previous;
                if (previousIndex >= 0) {
                  previous = priorities[previousIndex];
                }
                Priority? next;
                if (nextIndex < priorities.length) {
                  next = priorities[nextIndex];
                }
                currentPriority
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                    )
                    .save();
              },
          shrinkWrap: true,
        );
      },
    );
  }
}

