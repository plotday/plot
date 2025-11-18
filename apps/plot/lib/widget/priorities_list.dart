import 'package:plot/store/store.dart';
import 'package:plot/action/action.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // First group: Everything root priority
        ListTile(
          title: root.title,
          action: ChangeCurrentPriority(root),
          selected: selected?.id == root.id,
        ),

        // Second group: Top Priorities
        if (topPriorities.isNotEmpty) ...[
          ListTile(
            title: 'Top Priorities',
            style: ListTileStyle.header,
          ),
          ...topPriorities
              .expand((priority) => _buildPriorityItems(context, priority, 0)),
        ],

        // Third group: All Priorities
        ListTile(
          title: 'All Priorities',
          style: ListTileStyle.header,
        ),
        ...root.children
            .expand((priority) => _buildPriorityItems(context, priority, 0)),
      ],
    );
  }

  List<Widget> _buildPriorityItems(
    BuildContext context,
    Priority priority,
    int indentLevel,
  ) {
    return [
      ListTile(
        key: ValueKey(priority.id),
        title: priority.title,
        action: ChangeCurrentPriority(priority),
        selected: selected?.id == priority.id,
        indentLevel: indentLevel,
      ),
      ...priority.children.expand(
        (child) => _buildPriorityItems(context, child, indentLevel + 1),
      ),
    ];
  }
}
