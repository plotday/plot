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
  }) : topPriorities = priorities.where((p) => p.topOrder != null).toList()
         ..sort(
           (a, b) => (a.topOrder?.value ?? 0).compareTo(b.topOrder?.value ?? 0),
         );

  @override
  Widget build(BuildContext context) {
    final isLeftPanel =
        PanelPositionProvider.of(context) == HeaderPosition.left;
    final headerStyle = isLeftPanel
        ? context.theme.typography.xs
        : context.theme.typography.sm;
    final itemStyle = isLeftPanel
        ? context.theme.typography.sm
        : context.theme.typography.base;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // First group: Everything root priority
          ListTile(
            title: root.title,
            command: ChangeCurrentPriority(root),
            selected: selected?.id == root.id,
            leadingIndicator: UnreadIndicator(
              color: root.displayColor,
              unread: root.unread,
            ),
            textStyle: itemStyle.copyWith(
              color: context.colour.colours.fromTheme(root.displayColor),
            ),
            trailingBuilder: (isHovered, hasFocus) => (isHovered || hasFocus)
                ? Button.icon(ShowPriorityCommands(root))
                : null,
          ),

          // Second group: Top Priorities
          if (topPriorities.isNotEmpty) ...[
            SizedBox(height: 16),
            ListTile(
              title: 'Top Priorities',
              style: ListTileStyle.header,
              textStyle: headerStyle,
              noHoverHighlight: true,
            ),
            ReorderableListView<Priority>(
              list: topPriorities,
              shrinkWrap: true,
              itemBuilder: (context, priority) => Column(
                key: ValueKey('top-${priority.id}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildPriorityItems(
                  context,
                  priority,
                  topSection: true,
                  textStyle: itemStyle.copyWith(
                    color: context.colour.colours.fromTheme(
                      priority.displayColor,
                    ),
                  ),
                ),
              ),
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

                final currentPriority = topPriorities[oldIndex];
                Priority? previous;
                if (previousIndex >= 0) {
                  previous = topPriorities[previousIndex];
                }
                Priority? next;
                if (nextIndex < topPriorities.length) {
                  next = topPriorities[nextIndex];
                }

                await currentPriority
                    .copyWith(
                      topOrder: Value(
                        Order.between(previous?.topOrder, next?.topOrder),
                      ),
                    )
                    .save();
              },
            ),
          ],

          // Third group: All Priorities
          SizedBox(height: 16),
          ListTile(
            title: 'All Priorities',
            style: ListTileStyle.header,
            textStyle: headerStyle,
            noHoverHighlight: true,
          ),
          ...root.children.expand(
            (priority) => _buildPriorityItems(
              context,
              priority,
              textStyle: itemStyle.copyWith(
                color: context.colour.colours.fromTheme(priority.displayColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPriorityItems(
    BuildContext context,
    Priority priority, {
    int indentLevel = 0,
    bool topSection = false,
    required TextStyle textStyle,
  }) {
    return [
      PriorityWidget(
        key: ValueKey('${topSection ? 'top' : 'all'}-${priority.id}'),
        priority: priority,
        selected: selected?.id == priority.id,
        selectedBorder: topSection || priority.topOrder == null,
        indentLevel: indentLevel,
        textStyle: textStyle,
        showAncestry: topSection,
        unread: topSection ? _hasDescendantUnread(priority) : null,
      ),
      ...priority.children.expand(
        (child) => _buildPriorityItems(
          context,
          child,
          indentLevel: indentLevel + 1,
          topSection: topSection,
          textStyle: textStyle.copyWith(
            color: context.colour.colours.fromTheme(child.displayColor),
          ),
        ),
      ),
    ];
  }

  /// Returns true if the priority or any of its descendants has unread activities
  bool _hasDescendantUnread(Priority priority) {
    if (priority.unread) return true;
    return priority.descendants().any((p) => p.unread);
  }
}
