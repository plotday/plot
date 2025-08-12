import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/reorderable_list_view.dart' as custom;

class PrioritiesList extends StatelessWidget {
  final List<Priority> priorities;
  final Priority? selected;
  final void Function(Priority)? onPrioritySelected;
  final ReorderCallback? onReorder;

  const PrioritiesList({
    super.key,
    required this.priorities,
    this.onPrioritySelected,
    this.onReorder,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    if (priorities.isEmpty) {
      return Center(child: Text('No priorities found'));
    }

    final everything = priorities.firstWhereOrNull(
      (p) => p.title == 'Everything',
    );
    final otherPriorities = priorities
        .where((p) => p.id != everything?.id)
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (everything != null)
          GestureDetector(
            key: ValueKey(everything.id),
            onTap: () {
              if (onPrioritySelected != null) {
                onPrioritySelected!(everything);
              } else {
                context.run(ChangeCurrentPriority(everything));
              }
            },
            child: PriorityWidget(
              priority: everything,
              selected: selected?.id == everything.id,
            ),
          ),
        Flexible(
          fit: FlexFit.loose,
          child: custom.ReorderableListView<Priority>(
            list: otherPriorities,
            itemBuilder: (context, priority) {
              final isSelected = selected?.id == priority.id;
              return GestureDetector(
                key: ValueKey(priority.id),
                onTap: () {
                  if (onPrioritySelected != null) {
                    onPrioritySelected!(priority);
                  } else {
                    context.run(ChangeCurrentPriority(priority));
                  }
                },
                child: PriorityWidget(priority: priority, selected: isSelected),
              );
            },
            onReorder:
                onReorder ??
                (oldIndex, newIndex) {
                  // ...existing reorder logic, but use otherPriorities...
                },
            shrinkWrap: true,
          ),
        ),
      ],
    );
  }
}
