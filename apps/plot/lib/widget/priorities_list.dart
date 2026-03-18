import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/widget.dart';

class PrioritiesList extends StatefulWidget {
  final List<Priority> topPriorities;
  final Priority root;
  final Priority? selected;
  final bool showPlotSection;

  PrioritiesList({
    super.key,
    required this.root,
    required List<Priority> priorities,
    this.selected,
    this.showPlotSection = true,
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
  final Set<String> _showAllChildren = {};

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
          _showAllChildren.remove(priorityId);
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

    // Don't expand @plot children when "Everything" (root) is selected
    if (widget.selected!.id == widget.root.id && priority.isPlot) {
      return false;
    }

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
                    : context.theme.typography.md)
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
              active: topSection
                  ? _hasDescendantActive(priority)
                  : (!priorityExpanded && _hasDescendantActive(priority)
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
            final parentId = priority.id.toString();
            final truncated = _truncatedChildren(parentId, priority.children);
            final visibleChildren = truncated ?? priority.children;

            return [
              PriorityWidget(
                key: ValueKey('all-${priority.id}'),
                priority: priority,
                selected: widget.selected?.id == priority.id,
                selectedBorder: true,
                indentLevel: indentLevel,
                textStyle: textStyle.copyWith(
                  color: priority.archivedAt != null
                      ? context.theme.colors.mutedForeground
                      : context.colour.colours.fromTheme(
                          priority.displayColor,
                          muted:
                              !(priorityExpanded
                                  ? priority.active
                                  : _hasDescendantActive(priority)) &&
                              !(priorityExpanded
                                  ? priority.unread
                                  : _hasDescendantUnread(priority)),
                        ),
                ),
                unread: !priorityExpanded && _hasDescendantUnread(priority)
                    ? true
                    : null,
                active: !priorityExpanded && _hasDescendantActive(priority)
                    ? true
                    : null,
              ),
              if (priority.children.isNotEmpty)
                _AnimatedPriorityChildren(
                  controller: _getOrCreateController(parentId),
                  children: [
                    ...buildReorderablePriorityItems(
                      context,
                      visibleChildren,
                      indentLevel: indentLevel + 1,
                      textStyle: textStyle,
                    ),
                    if (truncated != null)
                      _ShowMoreItem(
                        indentLevel: indentLevel + 1,
                        textStyle: textStyle,
                        onTap: () =>
                            setState(() => _showAllChildren.add(parentId)),
                      ),
                  ],
                ),
            ];
          }

          return [
            ReorderableListView<Priority>(
              list: priorities,
              shrinkWrap: true,
              itemBuilder: (context, priority, reorderableIndex) {
                final priorityExpanded = shouldExpand(priority);
                final parentId = priority.id.toString();
                final truncated = _truncatedChildren(
                  parentId,
                  priority.children,
                );
                final visibleChildren = truncated ?? priority.children;

                return Column(
                  key: ValueKey('all-${priority.id}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PriorityWidget(
                      priority: priority,
                      selected: widget.selected?.id == priority.id,
                      selectedBorder: true,
                      indentLevel: indentLevel,
                      textStyle: textStyle.copyWith(
                        color: priority.archivedAt != null
                            ? context.theme.colors.mutedForeground
                            : context.colour.colours.fromTheme(
                                priority.displayColor,
                                muted:
                                    !(priorityExpanded
                                        ? priority.active
                                        : _hasDescendantActive(priority)) &&
                                    !(priorityExpanded
                                        ? priority.unread
                                        : _hasDescendantUnread(priority)),
                              ),
                      ),
                      unread:
                          !priorityExpanded && _hasDescendantUnread(priority)
                          ? true
                          : null,
                      active:
                          !priorityExpanded && _hasDescendantActive(priority)
                          ? true
                          : null,
                      reorderableIndex: reorderableIndex,
                    ),
                    if (priority.children.isNotEmpty)
                      _AnimatedPriorityChildren(
                        controller: _getOrCreateController(parentId),
                        children: [
                          ...buildReorderablePriorityItems(
                            context,
                            visibleChildren,
                            indentLevel: indentLevel + 1,
                            textStyle: textStyle,
                          ),
                          if (truncated != null)
                            _ShowMoreItem(
                              indentLevel: indentLevel + 1,
                              textStyle: textStyle,
                              onTap: () => setState(
                                () => _showAllChildren.add(parentId),
                              ),
                            ),
                        ],
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
                leadingBuilder: (isHovered, hasFocus) => Padding(
                  padding: EdgeInsets.only(
                    left: isMultiPanel
                        ? context.theme.spacing.lg
                        : context.theme.spacing.sm,
                    right: context.theme.spacing.sm,
                    bottom: 2,
                  ),
                  child: PriorityNotification(
                    unread: widget.root.unread,
                    active: widget.root.active,
                    color: widget.root.displayColor,
                  ),
                ),
                textStyle: itemStyle.copyWith(
                  color: context.colour.colours.fromTheme(
                    widget.root.displayColor,
                    muted: !widget.root.active && !widget.root.unread,
                  ),
                ),
                trailingBuilder: (isHovered, hasFocus) =>
                    (isHovered || hasFocus)
                    ? Padding(
                        padding: EdgeInsets.only(
                          right: isMultiPanel
                              ? context.theme.spacing.lg
                              : context.theme.spacing.sm,
                        ),
                        child: Button.icon(ShowPriorityCommands(widget.root)),
                      )
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
                  centered: true,
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
                  SizedBox(height: 16),
                  ListTile(
                    title: 'All Priorities',
                    style: ListTileStyle.header,
                    textStyle: headerStyle,
                    noHoverHighlight: true,
                    centered: true,
                  ),
                  ...buildReorderablePriorityItems(
                    context,
                    allPriorities,
                    textStyle: itemStyle,
                  ),
                  ListTile(
                    command: CommandWrapper(
                      NewPriority(parent: widget.root),
                      icon: Value(null),
                      title: 'Add a Priority',
                    ),
                    icon: PlotIcon.add,
                    iconOnly: true,
                    textStyle: itemStyle.copyWith(
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),

                  if (allPriorities.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.contentPaddingH,
                        vertical: context.theme.spacing.xl,
                      ),
                      child: Text(
                        'Priorities put your work in context. Add your roles, goals, and projects.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.theme.plotColors.veryMuted,
                          fontSize: context.theme.typography.sm.fontSize,
                        ),
                      ),
                    ),

                  // Fourth group: Plot section (children of @plot priority)
                  if (widget.showPlotSection &&
                      plotPriority != null &&
                      plotPriority.children.isNotEmpty) ...[
                    SizedBox(height: 16),
                    ListTile(
                      title: 'Plot',
                      style: ListTileStyle.header,
                      textStyle: headerStyle,
                      noHoverHighlight: true,
                      centered: true,
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

  /// Returns true if the priority or any of its descendants is active
  bool _hasDescendantActive(Priority priority) {
    if (priority.active) return true;
    return priority.descendants().any((p) => p.active);
  }

  /// Returns the visible subset of children when truncating, or null if no truncation needed.
  List<Priority>? _truncatedChildren(String parentId, List<Priority> children) {
    if (children.length <= 5) return null;
    if (_showAllChildren.contains(parentId)) return null;

    final activeChildren = children
        .where((c) => _hasDescendantActive(c))
        .toList();
    final unreadOnlyChildren = children
        .where((c) => !_hasDescendantActive(c) && _hasDescendantUnread(c))
        .toList();
    final importantChildren = [...activeChildren, ...unreadOnlyChildren];

    // Case 1: All children are important — show top 4 by order
    if (importantChildren.length == children.length) {
      return children.take(4).toList();
    }

    // Case 2: 5+ important — show all important
    if (importantChildren.length >= 5) {
      // Return in natural (original) order
      final visible = importantChildren.toSet();
      return children.where((c) => visible.contains(c)).toList();
    }

    // Case 3: <5 important — fill 4 slots, important first then top-by-order
    final slotsForOrdered = 4 - importantChildren.length;
    final importantSet = importantChildren.toSet();
    final topByOrder = children
        .where((c) => !importantSet.contains(c))
        .take(slotsForOrdered)
        .toList();
    final visible = <Priority>{...topByOrder, ...importantChildren};
    // Return in natural (original) order
    return children.where((c) => visible.contains(c)).toList();
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

class _ShowMoreItem extends StatefulWidget {
  final int indentLevel;
  final VoidCallback onTap;
  final TextStyle? textStyle;

  const _ShowMoreItem({
    required this.indentLevel,
    required this.onTap,
    this.textStyle,
  });

  @override
  State<_ShowMoreItem> createState() => _ShowMoreItemState();
}

class _ShowMoreItemState extends State<_ShowMoreItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: _isHovered ? context.theme.plotColors.highlight : null,
          ),
          padding: EdgeInsets.only(
            left: widget.indentLevel * (16 + context.theme.spacing.sm),
          ),
          child: Row(
            children: [
              SizedBox(width: 20),
              Expanded(
                child: Padding(
                  padding: context.theme.spacing.paddingSm.copyWith(
                    left: 0,
                    right: 0,
                  ),
                  child: Text(
                    'More\u2026',
                    style: (widget.textStyle ?? context.theme.typography.sm)
                        .copyWith(color: context.theme.colors.mutedForeground),
                  ),
                ),
              ),
              SizedBox(width: 20),
            ],
          ),
        ),
      ),
    );
  }
}
