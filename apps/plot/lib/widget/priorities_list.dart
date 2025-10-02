import 'package:flutter/widgets.dart';
import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/widget.dart';

class PrioritiesList extends StatelessWidget {
  final List<Priority> topPriorities;
  final Priority root;
  final Priority? selected;

  PrioritiesList({
    super.key,
    required this.root,
    required List<Priority> priorities,
    this.selected,
  }) : topPriorities = priorities.where((p) => p.topOrder != null).toList();

  @override
  Widget build(BuildContext context) {
    return FSidebar(
      // ignore: unused_result
      style: context.theme.sidebarStyle.copyWith(
        decoration: BoxDecoration(),
        constraints: BoxConstraints(),
        headerPadding: EdgeInsets.zero,
        contentPadding: EdgeInsets.zero,
        footerPadding: EdgeInsets.zero,
      ),
      children: [
        // First group: Everything root priority
        FSidebarGroup(
          children: [
            FSidebarItem(
              label: Text(root.title),
              selected: selected?.id == root.id,
              onPress: () => context.run(ChangeCurrentPriority(root)),
            ),
          ],
        ),

        // Second group: Top Priorities
        if (topPriorities.isNotEmpty)
          FSidebarGroup(
            label: const Text('Top Priorities'),
            children: topPriorities
                .map((priority) => _buildPriorityItem(context, priority))
                .toList(),
          ),

        // Third group: All Priorities with + button
        FSidebarGroup(
          label: const Text('All Priorities'),
          children: root.children
              .map((priority) => _buildPriorityItem(context, priority))
              .toList(),
        ),
      ],
    );
  }

  FSidebarItem _buildPriorityItem(BuildContext context, Priority priority) {
    return FSidebarItem(
      key: ValueKey(priority.id),
      label: Text(priority.title),
      selected: selected?.id == priority.id,
      initiallyExpanded: false,
      onPress: () => context.run(ChangeCurrentPriority(priority)),
      children: priority.children
          .map((child) => _buildPriorityItem(context, child))
          .toList(),
    );
  }
}
