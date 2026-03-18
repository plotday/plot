import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/state/layout.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/priority_selector.dart';
import 'button.dart';
import 'icon.dart';
import 'window.dart';

/// A single header spanning the full window width, placed above all panels.
class UnifiedHeader extends StatefulWidget {
  const UnifiedHeader({super.key});

  @override
  State<UnifiedHeader> createState() => _UnifiedHeaderState();
}

class _UnifiedHeaderState extends State<UnifiedHeader> {
  bool _searchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  PriorityShortcutsProviderState? _panelController;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panelController = ActivityPanelControllerProvider.maybeOf(context);
    _panelController?.registerSearchToggle(_toggleSearch);
    context.read<PriorityBloc>().headerNotifier =
        ThreadHeaderNotifierProvider.read(context);
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      final search = _searchController.text;
      // Dispatch to PriorityBloc
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateSearch(search);
      // Dispatch to PrioritiesBloc to filter sidebar
      context.read<PrioritiesBloc>().updateSearch(search);
      // Dispatch to ThreadHeaderNotifier if activity is visible
      final notifier = ThreadHeaderNotifierProvider.read(context);
      notifier?.onSearchChanged?.call(search);
    });
  }

  void _toggleSearch() {
    if (_searchExpanded) {
      _closeSearch();
    } else {
      setState(() {
        _searchExpanded = true;
        _panelController?.updateSearchExpanded(true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      });
    }
  }

  void _closeSearch() {
    setState(() {
      _searchExpanded = false;
      _panelController?.updateSearchExpanded(false);
      _searchController.clear();
    });
    // Clear PriorityBloc search and filters
    context.read<PriorityBloc>().updateSearch('');
    context.read<PriorityBloc>().updateFilter([]);
    // Clear PrioritiesBloc search
    context.read<PrioritiesBloc>().updateSearch('');
    // Clear activity search
    final notifier = ThreadHeaderNotifierProvider.read(context);
    notifier?.onSearchChanged?.call('');
    notifier?.onSearchClosed?.call();
  }

  @override
  void dispose() {
    _panelController?.unregisterSearchToggle();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            // of() registers an InheritedNotifier dependency, so this
            // builder already rebuilds when the notifier fires.
            final notifier = ThreadHeaderNotifierProvider.of(context);
            return _buildHeader(context, layoutState, state, notifier);
          },
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );

    final isThreadVisible = notifier?.isThreadVisible ?? false;
    final hasActivity = state.thread != null || isThreadVisible;

    // --- Build title children ---
    final titleChildren = <Widget>[
      // macOS traffic light padding
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),

      // Single-panel with thread: back button
      if (hasActivity && !layoutState.multiPanel)
        Button.icon(
          CommandWrapper(ChangeCurrentThread(null), icon: Value(PlotIcon.back)),
          color: context.theme.colors.foreground,
        )
      // Right-only with thread (960–1309px): back button
      else if (hasActivity &&
          layoutState.multiPanel &&
          !layoutState.leftPanelVisible &&
          !layoutState.middlePanelVisible &&
          context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth)
        Button.icon(
          CommandWrapper(ChangeCurrentThread(null), icon: Value(PlotIcon.back)),
          color: context.theme.colors.foreground,
        )
      // Single-panel without thread: back to Priorities tab
      else if (!layoutState.multiPanel && !hasActivity)
        Button.icon(
          BackToPrioritiesTabCommand(),
          color: context.theme.colors.foreground,
        )
      // 2-panel with thread (960–1309px): cycle + priorities slide
      else if (hasActivity &&
          layoutState.isTwoPanel &&
          context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button.icon(CyclePanelsCommand(layoutState: layoutState)),
            Button.icon(
              CommandWrapper(
                ChangeCurrentThread(null),
                icon: Value(PlotIcon.priorities),
                title: 'Open priorities',
              ),
            ),
          ],
        )
      // 2-panel browsing (960–1309px): cycle
      else if (layoutState.isTwoPanel &&
          context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth)
        Button.icon(CyclePanelsCommand(layoutState: layoutState))
      // ≥ 1310px right-only: priorities icon + open threads
      else if (layoutState.multiPanel &&
          !layoutState.leftPanelVisible &&
          !layoutState.middlePanelVisible)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button.icon(
              CommandWrapper(
                ToggleLeftSidebarCommand(isVisible: false),
                icon: Value(PlotIcon.priorities),
              ),
            ),
            Button.icon(ToggleMiddleSidebarCommand(isVisible: false)),
          ],
        )
      // ≥ 1310px with sidebar(s): explicit toggle buttons
      else if (layoutState.multiPanel)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button.icon(
              layoutState.leftPanelVisible
                  ? ToggleLeftSidebarCommand(isVisible: true)
                  : CommandWrapper(
                      ToggleLeftSidebarCommand(isVisible: false),
                      icon: Value(PlotIcon.priorities),
                    ),
            ),
            if (!(layoutState.leftPanelVisible &&
                layoutState.middlePanelVisible))
              Button.icon(
                ToggleMiddleSidebarCommand(
                  isVisible: layoutState.middlePanelVisible,
                ),
              ),
          ],
        ),

      // Search field or title + search button
      if (_searchExpanded) ...[
        // Invisible button-height spacer to keep the row height constant
        SizedBox(
          width: 0,
          child: Opacity(
            opacity: 0,
            child: IgnorePointer(child: _searchButton()),
          ),
        ),
        _buildSearchField(context, layoutState, state, notifier),
      ] else
        _buildTitleWithSearch(context, layoutState, state, hasActivity, notifier),
    ];

    // --- Build suffixes ---
    final thread = state.thread;
    final suffixes = <Widget>[
      // Active tag toggles (when thread is visible)
      if (thread != null) ..._buildActiveTagToggles(context, thread),

      // Todo toggle (when thread is visible)
      if (thread != null) _buildTodoToggle(context, thread),

      // New Thread button (multiPanel only, since bottom nav has it otherwise)
      if (layoutState.multiPanel) Button.icon(NewThread()),

      // Menu button (desktop only — mobile uses title tap target)
      if (layoutState.multiPanel)
        Button.icon(_buildMenuCommand(state, layoutState, notifier)),

      // Windows window control padding
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
    ];

    Widget header = FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => ClipRect(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.theme.colors.background,
              border: Border(
                bottom: BorderSide(
                  color: context.theme.colors.border,
                  width: 1,
                ),
              ),
            ),
            child: FHeader(
              style: FHeaderStyleDelta.delta(
                padding: EdgeInsetsGeometryDelta.add(
                  const EdgeInsets.symmetric(vertical: 4),
                ),
              ),
              title: Row(spacing: 8, children: titleChildren),
              suffixes: suffixes,
            ),
          ),
        ),
      ),
    );

    // Wrap with DragToMoveArea on Windows
    if (Platform.instance.isWindows) {
      header = DragToMoveArea(child: header);
    }

    return header;
  }

  Widget _searchButton() {
    return Button.icon(
      ToggleSearchCommand(
        searchExpanded: _searchExpanded,
        onToggle: _toggleSearch,
      ),
    );
  }

  Widget _buildTitleWithSearch(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    bool hasActivity,
    ThreadHeaderNotifier? notifier,
  ) {
    final search = _searchButton();

    // In single panel with a thread visible, show activity title
    if (!layoutState.multiPanel && hasActivity && state.thread != null) {
      final thread = state.thread!;
      final resolved = Thread.resolveIcon(
        thread.icon,
        prioritySharing: thread.priority.sharing,
      );
      final isSubType =
          ThreadSubType.fromIcon(thread.icon) != null || thread.icon == null;

      return Expanded(
        child: Row(
          spacing: 8,
          children: [
            Flexible(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.run(_buildMenuCommand(state, layoutState, notifier)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    if (isSubType && !thread.priority.isViewer)
                      GestureDetector(
                        onTap: () => context.run(ChangeThreadSubType(thread)),
                        child: Icon(
                          resolved.fallbackIcon,
                          size: 14,
                          color: context.theme.colors.mutedForeground,
                        ),
                      )
                    else
                      Icon(
                        resolved.fallbackIcon,
                        size: 14,
                        color: context.theme.colors.mutedForeground,
                      ),
                    Flexible(
                      child: Text(
                        thread.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: context.theme.typography.sm.copyWith(
                          fontWeight: FontWeight.w600,
                          color: context.theme.colors.foreground,
                        ),
                      ),
                    ),
                    Icon(
                      PlotIcon.menu,
                      size: context.theme.iconSizes.xs,
                      color: context.theme.colors.foreground.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
            search,
          ],
        ),
      );
    }

    // In single panel with new thread visible, hide priority and search
    if (!layoutState.multiPanel && hasActivity) {
      return const Expanded(child: SizedBox.shrink());
    }

    // Single panel: tap priority to open menu
    if (!layoutState.multiPanel) {
      return Expanded(
        child: Row(
          spacing: 8,
          children: [
            Flexible(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.run(_buildMenuCommand(state, layoutState, notifier)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Flexible(
                      child: PriorityLabel(
                        priority: state.context,
                      ),
                    ),
                    Icon(
                      PlotIcon.menu,
                      size: context.theme.iconSizes.xs,
                      color: context.theme.colors.foreground.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
            search,
          ],
        ),
      );
    }

    // Multi-panel: show PrioritySelector with dropdown
    final selector = PrioritySelector(
      selected: state.context,
      onSelect: (p) => context.run(ChangeCurrentPriority(p)),
    );

    return Expanded(
      child: Row(
        spacing: 8,
        children: [
          Flexible(child: selector),
          search,
        ],
      ),
    );
  }

  Widget _buildSearchField(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    // Build filter commands based on visibility
    final filterCommands = <Command>[
      // Icon sub-type filters
      ...state.iconCounts.map(
        (data) => ToggleIconFilter(data.$1, context: context),
      ),
      // Priority tag filters
      ...state.tags.map(
        (tagData) => ToggleActivityFilter(tagData.$1, context: context),
      ),
      // Active filter tags not in current priority
      ...state.filter
          .where((tag) => !state.tags.any((t) => t.$1 == tag))
          .map((tag) => ToggleActivityFilter(tag, context: context)),
      // Activity note filters (when activity is visible)
      if (notifier?.isThreadVisible == true)
        ...notifier!.tags.map(
          (tagData) => ToggleNoteFilter(tagData.$1, context: context),
        ),
    ];

    return Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _closeSearch();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: FTextField(
                control: .managed(controller: _searchController),
                focusNode: _searchFocusNode,
                hint: 'Search…',
                style: FTextFieldStyleDelta.delta(
                  contentPadding: EdgeInsetsGeometryDelta.value(
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  ),
                ),
                suffixBuilder: (context, style, states) {
                  final children = <Widget>[
                    ...filterCommands.asMap().entries.map((entry) {
                      final key = ValueKey(
                        Object.hash(entry.value.hashCode, entry.key),
                      );
                      return Button.icon(
                        entry.value,
                        key: key,
                        selected: entry.value.on == true,
                      );
                    }),
                    Button.icon(
                      ToggleSearchCommand(
                        searchExpanded: _searchExpanded,
                        onToggle: _closeSearch,
                      ),
                    ),
                  ];

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the calendar + todo state toggle buttons matching ThreadWidget's
  /// leading icon behavior.
  Widget _buildTodoToggle(BuildContext context, Thread thread) {
    final threadColor = context.colour.colours.fromTheme(
      thread.priority.displayColor,
    );
    final isTodo = thread.todo;
    final isScheduled = isTodo && thread.isFuture;

    // Icon 1: Calendar scheduling icon
    final calendarIcon = Button.icon(
      CommandWrapper(
        PickScheduleThread(thread),
        icon: Value(PlotIcon.schedule),
        title: 'Schedule',
      ),
      selected: isScheduled,
      selectedColor: threadColor,
      color: isScheduled ? null : context.theme.plotColors.veryMuted,
    );

    // Icon 2: To-do state icon
    final Widget todoIcon;
    if (!isTodo) {
      todoIcon = Button.icon(
        CommandWrapper(ThreadToDo(thread), icon: Value(PlotIcon.addTodo), title: 'Start'),
        color: context.theme.plotColors.muted,
      );
    } else {
      final hasPending = thread.outstandingTasks;
      todoIcon = Button.icon(
        CommandWrapper(
          ThreadDone(thread),
          icon: Value(hasPending ? FontAwesomeIcons.circle : PlotIcon.todo),
          hoverIcon: hasPending
              ? Value(FontAwesomeIcons.circleCheck)
              : const Value<IconData?>.absent(),
          title: 'Finish',
        ),
        selected: true,
        selectedColor: threadColor,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [calendarIcon, todoIcon],
    );
  }

  /// Builds active tag toggle buttons for the current thread.
  List<Widget> _buildActiveTagToggles(BuildContext context, Thread thread) {
    return thread.tags.keys
        .where((tag) {
          if (tag == Tag.todo) return false;
          if (!tag.addable) return false;
          if (tag == Tag.reply) {
            return thread.tags[tag]?.contains(Base.actorId) ?? false;
          }
          return true;
        })
        .take(3)
        .map((tag) => Button.icon(ToggleThreadTag(thread, tag)))
        .toList();
  }

  Command _buildMenuCommand(
    PriorityState state,
    LayoutState layoutState,
    ThreadHeaderNotifier? notifier,
  ) {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final thread = state.thread;
        final threadGroups = thread != null
            ? await threadCommandGroups(
                thread,
                compact: !context.isMultiPanel,
              )
            : <StaticCommandGroup>[];
        return Commands(
          groups: [
            ...threadGroups,
            ...currentPriorityCommandGroups(state.context),
          ],
        );
      },
    );
  }
}
