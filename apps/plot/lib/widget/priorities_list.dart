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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // First group: Everything root priority
        ListTile(
          title: root.title,
          command: ChangeCurrentPriority(root),
          selected: selected?.id == root.id,
        ),

        // Second group: Top Priorities
        if (topPriorities.isNotEmpty) ...[
          ListTile(title: 'Top Priorities', style: ListTileStyle.header),
          ...topPriorities.expand(
            (priority) =>
                _buildPriorityItems(context, priority, topSection: true),
          ),
        ],

        // Third group: All Priorities
        ListTile(title: 'All Priorities', style: ListTileStyle.header),
        ...root.children.expand(
          (priority) => _buildPriorityItems(context, priority),
        ),
      ],
    );
  }

  List<Widget> _buildPriorityItems(
    BuildContext context,
    Priority priority, {
    int indentLevel = 0,
    bool topSection = false,
  }) {
    return [
      ListTile(
        key: ValueKey('${topSection ? 'top' : 'all'}-${priority.id}'),
        title: priority.title,
        command: ChangeCurrentPriority(priority, ancestry: topSection),
        selected: selected?.id == priority.id,
        selectedBorder: topSection || priority.topOrder == null,
        indentLevel: indentLevel,
      ),
      ...priority.children.expand(
        (child) => _buildPriorityItems(
          context,
          child,
          indentLevel: indentLevel + 1,
          topSection: topSection,
        ),
      ),
    ];
  }
}
