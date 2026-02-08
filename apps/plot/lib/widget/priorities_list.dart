import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/widget.dart';

class PrioritiesList extends StatefulWidget {
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
  State<PrioritiesList> createState() => _PrioritiesListState();
}

class _PrioritiesListState extends State<PrioritiesList>
    with TickerProviderStateMixin {
  // Animation state
  final Map<String, AnimationController> _controllers = {};
  final Map<String, bool> _expansionState = {};
  bool _isFirstBuild = true;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isFirstBuild) {
      _updateExpansionState();
    }
  }

  @override
  void didUpdateWidget(PrioritiesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateExpansionState();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  void _updateExpansionState() {
    if (_isFirstBuild) {
      _isFirstBuild = false;
      _initializeExpansionState();
      return;
    }

    final currentExpansions = _computeAllExpansions();

    // Detect changes and trigger animations
    for (final entry in currentExpansions.entries) {
      final priorityId = entry.key;
      final shouldExpandNow = entry.value;
      final wasExpanded = _expansionState[priorityId];

      if (wasExpanded != shouldExpandNow) {
        final controller = _getOrCreateController(priorityId);
        if (shouldExpandNow) {
          controller.forward();
        } else {
          controller.reverse();
        }
      }
    }

    // Clean up controllers for removed priorities
    final removedIds = _expansionState.keys
        .where((id) => !currentExpansions.containsKey(id))
        .toList();
    for (final id in removedIds) {
      _controllers[id]?.dispose();
      _controllers.remove(id);
    }

    _expansionState.clear();
    _expansionState.addAll(currentExpansions);
  }

  void _initializeExpansionState() {
    final currentExpansions = _computeAllExpansions();
    _expansionState.addAll(currentExpansions);
  }

  AnimationController _getOrCreateController(String priorityId) {
    return _controllers.putIfAbsent(
      priorityId,
      () => AnimationController(
        duration: const Duration(milliseconds: 250),
        vsync: this,
      )..value = _expansionState[priorityId] == true ? 1.0 : 0.0,
    );
  }

  Map<String, bool> _computeAllExpansions() {
    final result = <String, bool>{};
    final layoutState = context.read<LayoutBloc>().state;
    final isMultiPanel = layoutState.multiPanel;

    void addPriority(Priority priority) {
      final expanded = _shouldExpand(priority, isMultiPanel);
      if (priority.children.isNotEmpty) {
        result[priority.id.toString()] = expanded;
      }
      for (final child in priority.children) {
        addPriority(child);
      }
    }

    for (final child in widget.root.children) {
      addPriority(child);
    }
    for (final topPriority in widget.topPriorities) {
      addPriority(topPriority);
    }

    return result;
  }

  bool _shouldExpand(Priority priority, bool isMultiPanel) {
    if (!isMultiPanel) return true;
    if (widget.selected == null) return true;

    final selectedAncestors = widget.selected!.ancestors(includeSelf: false);
    if (selectedAncestors.any((a) => a.id == priority.id)) {
      return true;
    }

    if (widget.selected!.id == priority.id) {
      return true;
    }

    if (widget.selected!.isParent(priority)) {
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final isMultiPanel = layoutState.multiPanel;
        final isLeftPanel =
            PanelPositionProvider.of(context) == HeaderPosition.left;
        final headerStyle = isLeftPanel
            ? context.theme.typography.xs
            : context.theme.typography.sm;
        final itemStyle =
            (isLeftPanel
                    ? context.theme.typography.sm
                    : context.theme.typography.base)
                .copyWith(fontWeight: FontWeight.w500);

        // Automatic expansion logic
        bool shouldExpand(Priority priority) {
          return _shouldExpand(priority, isMultiPanel);
        }

        // Build priority items recursively
        List<Widget> buildPriorityItems(
          BuildContext context,
          Priority priority, {
          int indentLevel = 0,
          bool topSection = false,
          required TextStyle textStyle,
          int? reorderableIndex,
        }) {
          final priorityExpanded = shouldExpand(priority);

          return [
            PriorityWidget(
              key: ValueKey('${topSection ? 'top' : 'all'}-${priority.id}'),
              priority: priority,
              selected: widget.selected?.id == priority.id,
              selectedBorder: topSection || priority.topOrder == null,
              indentLevel: indentLevel,
              textStyle: textStyle.copyWith(
                color: priority.archivedAt != null
                    ? context.theme.colors.mutedForeground
                    : textStyle.color,
              ),
              showAncestry: topSection,
              unread: topSection
                  ? _hasDescendantUnread(priority)
                  : (!priorityExpanded && _hasDescendantUnread(priority)
                        ? true
                        : null),
              reorderableIndex: reorderableIndex,
            ),
            if (priority.children.isNotEmpty)
              _AnimatedPriorityChildren(
                controller: _getOrCreateController(priority.id.toString()),
                children: priority.children
                    .expand(
                      (child) => buildPriorityItems(
                        context,
                        child,
                        indentLevel: indentLevel + 1,
                        topSection: topSection,
                        textStyle: textStyle.copyWith(
                          color: child.archivedAt != null
                              ? context.theme.colors.mutedForeground
                              : context.colour.colours.fromTheme(
                                  child.displayColor,
                                ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ];
        }

        // Build reorderable priority items
        List<Widget> buildReorderablePriorityItems(
          BuildContext context,
          List<Priority> priorities, {
          int indentLevel = 0,
          required TextStyle textStyle,
        }) {
          if (priorities.isEmpty) return [];

          if (priorities.length == 1) {
            final priority = priorities.first;
            final priorityExpanded = shouldExpand(priority);

            return [
              PriorityWidget(
                key: ValueKey('all-${priority.id}'),
                priority: priority,
                selected: widget.selected?.id == priority.id,
                selectedBorder: priority.topOrder == null,
                indentLevel: indentLevel,
                textStyle: textStyle.copyWith(
                  color: priority.archivedAt != null
                      ? context.theme.colors.mutedForeground
                      : context.colour.colours.fromTheme(priority.displayColor),
                ),
                unread: !priorityExpanded && _hasDescendantUnread(priority)
                    ? true
                    : null,
              ),
              if (priority.children.isNotEmpty)
                _AnimatedPriorityChildren(
                  controller: _getOrCreateController(priority.id.toString()),
                  children: buildReorderablePriorityItems(
                    context,
                    priority.children,
                    indentLevel: indentLevel + 1,
                    textStyle: textStyle,
                  ),
                ),
            ];
          }

          return [
            ReorderableListView<Priority>(
              list: priorities,
              shrinkWrap: true,
              itemBuilder: (context, priority, reorderableIndex) {
                final priorityExpanded = shouldExpand(priority);

                return Column(
                  key: ValueKey('all-${priority.id}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PriorityWidget(
                      priority: priority,
                      selected: widget.selected?.id == priority.id,
                      selectedBorder: priority.topOrder == null,
                      indentLevel: indentLevel,
                      textStyle: textStyle.copyWith(
                        color: priority.archivedAt != null
                            ? context.theme.colors.mutedForeground
                            : context.colour.colours.fromTheme(
                                priority.displayColor,
                              ),
                      ),
                      unread:
                          !priorityExpanded && _hasDescendantUnread(priority)
                          ? true
                          : null,
                      reorderableIndex: reorderableIndex,
                    ),
                    if (priority.children.isNotEmpty)
                      _AnimatedPriorityChildren(
                        controller: _getOrCreateController(
                          priority.id.toString(),
                        ),
                        children: buildReorderablePriorityItems(
                          context,
                          priority.children,
                          indentLevel: indentLevel + 1,
                          textStyle: textStyle,
                        ),
                      ),
                  ],
                );
              },
              onReorder: (int oldIndex, int newIndex) =>
                  _onReorderPriority(priorities, oldIndex, newIndex),
            ),
          ];
        }

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // First group: Everything root priority
              ListTile(
                title: widget.root.title,
                command: ChangeCurrentPriority(widget.root),
                selected: widget.selected?.id == widget.root.id,
                leadingBuilder: (isHovered, hasFocus) => SizedBox(
                  width: 20,
                  child: UnreadIndicator(
                    color: widget.root.displayColor,
                    unread: widget.root.unread,
                  ),
                ),
                textStyle: itemStyle.copyWith(
                  color: context.colour.colours.fromTheme(
                    widget.root.displayColor,
                  ),
                ),
                trailingBuilder: (isHovered, hasFocus) =>
                    (isHovered || hasFocus)
                    ? Button.icon(ShowPriorityCommands(widget.root))
                    : null,
              ),

              // Second group: Top Priorities
              if (widget.topPriorities.isNotEmpty) ...[
                SizedBox(height: 16),
                ListTile(
                  title: 'Top Priorities',
                  style: ListTileStyle.header,
                  textStyle: headerStyle,
                  noHoverHighlight: true,
                ),
                ReorderableListView<Priority>(
                  list: widget.topPriorities,
                  shrinkWrap: true,
                  itemBuilder: (context, priority, reorderableIndex) => Column(
                    key: ValueKey('top-${priority.id}'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: buildPriorityItems(
                      context,
                      priority,
                      topSection: true,
                      textStyle: itemStyle.copyWith(
                        color: context.colour.colours.fromTheme(
                          priority.displayColor,
                        ),
                      ),
                      reorderableIndex: reorderableIndex,
                    ),
                  ),
                  onReorder: (int oldIndex, int newIndex) async {
                    var previousIndex =
                        newIndex + (newIndex < oldIndex ? -1 : 0);
                    var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

                    final currentPriority = widget.topPriorities[oldIndex];
                    Priority? previous;
                    if (previousIndex >= 0) {
                      previous = widget.topPriorities[previousIndex];
                    }
                    Priority? next;
                    if (nextIndex < widget.topPriorities.length) {
                      next = widget.topPriorities[nextIndex];
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

              // Third group: All Priorities (excluding @plot)
              // Filter out the @plot priority
              ...() {
                final plotPriority = widget.root.children.firstWhereOrNull(
                  (p) => p.key == '@plot',
                );

                final allPriorities = widget.root.children
                    .where((p) => p.key != '@plot')
                    .toList();

                return [
                  // Only show header if there are priorities to display
                  if (allPriorities.isNotEmpty) ...[
                    SizedBox(height: 16),
                    ListTile(
                      title: 'All Priorities',
                      style: ListTileStyle.header,
                      textStyle: headerStyle,
                      noHoverHighlight: true,
                    ),
                    ...buildReorderablePriorityItems(
                      context,
                      allPriorities,
                      textStyle: itemStyle,
                    ),
                  ],

                  // Fourth group: Plot section (children of @plot priority)
                  if (plotPriority != null &&
                      plotPriority.children.isNotEmpty) ...[
                    SizedBox(height: 16),
                    ListTile(
                      title: 'Plot',
                      style: ListTileStyle.header,
                      textStyle: headerStyle,
                      noHoverHighlight: true,
                    ),
                    ...buildReorderablePriorityItems(
                      context,
                      plotPriority.children,
                      textStyle: itemStyle,
                    ),
                  ],
                ];
              }(),
            ],
          ),
        );
      },
    );
  }

  /// Returns true if the priority or any of its descendants has unread activities
  bool _hasDescendantUnread(Priority priority) {
    if (priority.unread) return true;
    return priority.descendants().any((p) => p.unread);
  }

  Future<void> _onReorderPriority(
    List<Priority> peers,
    int oldIndex,
    int newIndex,
  ) async {
    // Calculate adjacent items before removal
    var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
    var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

    final currentPriority = peers[oldIndex];
    Priority? previous;
    if (previousIndex >= 0) {
      previous = peers[previousIndex];
    }
    Priority? next;
    if (nextIndex < peers.length) {
      next = peers[nextIndex];
    }

    // Update order to position between previous and next
    await currentPriority
        .copyWith(
          order: Order.between(previous?.order, next?.order),
          pending: const Value(2),
        )
        .save();
  }
}

class _AnimatedPriorityChildren extends StatelessWidget {
  final AnimationController controller;
  final List<Widget> children;

  const _AnimatedPriorityChildren({
    required this.controller,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: controller, curve: Curves.easeInOut),
      axisAlignment: -1.0,
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
