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
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/priority_selector.dart';
import 'button.dart';
import 'icon.dart';
import 'thread.dart';
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
  String _lastSearchText = '';
  PriorityShortcutsProviderState? _panelController;
  final GlobalKey _headerKey = GlobalKey();
  double? _lastMeasuredHeaderHeight;

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
    // No PriorityBloc when the header is used on the Priorities tab
    // (single-panel root view). That path renders the no-priority header
    // and has nothing to wire up here.
    try {
      context.read<PriorityBloc>().headerNotifier =
          ThreadHeaderNotifierProvider.read(context);
    } on ProviderNotFoundException {
      // Intentionally no-op.
    }
  }

  void _onSearchChanged() {
    final search = _searchController.text;
    // The controller fires this listener on selection changes too; ignore
    // those so cursor moves don't tear down in-flight remote search results.
    if (search == _lastSearchText) return;
    _lastSearchText = search;

    // Immediately update search text in state and cancel stale subscriptions
    // so old unfiltered results stop flowing while the user types. The
    // actual query is throttled below.
    context.read<PriorityBloc>().prepareSearch(search);

    // Clearing the box should feel instant — no point waiting 500 ms to
    // tear down filtered results when the user just wiped the field.
    if (search.isEmpty) {
      _debounceTimer?.cancel();
      _dispatchSearch();
      return;
    }

    // Throttle with trailing edge: first keystroke arms a 500 ms timer;
    // further keystrokes during that window are absorbed (no reset);
    // when it fires, _dispatchSearch reads the latest controller text. A
    // new timer is armed by the next keystroke, so continued typing yields
    // an update every ~500 ms and the final text always gets searched.
    if (_debounceTimer == null || !_debounceTimer!.isActive) {
      _debounceTimer = Timer(
        const Duration(milliseconds: 500),
        _dispatchSearch,
      );
    }
  }

  void _dispatchSearch() {
    final search = _searchController.text;
    final priorityBloc = context.read<PriorityBloc>();
    priorityBloc.executeSearch(search);
    context.read<PrioritiesBloc>().updateSearch(search);
    final notifier = ThreadHeaderNotifierProvider.read(context);
    notifier?.onSearchChanged?.call(search);
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
    final priorityBloc = context.read<PriorityBloc>();
    priorityBloc.updateSearch('');
    priorityBloc.updateFilter([]);
    // Clear icon filters one by one (toggles them off)
    for (final icon in List<String>.from(priorityBloc.state.iconFilter)) {
      priorityBloc.updateIconFilter(icon);
    }
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

  void _scheduleTrafficLightAlignment() {
    if (!Platform.instance.isMacOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box =
          _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      if (_lastMeasuredHeaderHeight != null &&
          (_lastMeasuredHeaderHeight! - height).abs() < 0.5) {
        return;
      }
      _lastMeasuredHeaderHeight = height;
      Window.alignTrafficLightsToHeader(height);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleTrafficLightAlignment();
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        // On the Priorities tab in single-panel mode there is no
        // PriorityBloc in scope. Render a minimal header with just
        // window-control padding and the menu.
        try {
          context.read<PriorityBloc>();
        } on ProviderNotFoundException {
          return _buildNoPriorityHeader(context, layoutState);
        }
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
    // PriorityPage panel is considered hidden when we're in single-panel mode
    // or when the middle panel isn't visible in multi-panel mode.
    final priorityPageHidden =
        !layoutState.multiPanel || !layoutState.middlePanelVisible;

    // --- Build title children ---
    final titleChildren = <Widget>[
      // macOS traffic light padding
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),

      // Single-panel with thread: back button clears the thread.
      if (hasActivity && !layoutState.multiPanel)
        Button.icon(
          CommandWrapper(ChangeCurrentThread(null), icon: Value(PlotIcon.back)),
          color: context.theme.colors.foreground,
        )
      // Single-panel without thread: back to Priorities tab
      else if (!layoutState.multiPanel)
        Button.icon(
          BackToPrioritiesTabCommand(),
          color: context.theme.colors.foreground,
        )
      // Multi-panel right-only with a thread visible: back + open priorities
      // + open threads. Back clears the thread but keeps the middle panel
      // closed, so the user can return to the priority page without the
      // thread shrinking.
      else if (layoutState.multiPanel &&
          !layoutState.leftPanelVisible &&
          !layoutState.middlePanelVisible &&
          hasActivity)
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
            Button.icon(
              CommandWrapper(
                ChangeCurrentThread(null),
                icon: Value(PlotIcon.back),
              ),
            ),
          ],
        )
      // 2-panel left+right with activity: the priority page (threads list)
      // is hidden, so add a back button alongside the cycle button to let
      // the user return to it.
      else if (layoutState.isTwoPanel &&
          layoutState.leftPanelVisible &&
          !layoutState.middlePanelVisible &&
          hasActivity &&
          context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button.icon(CyclePanelsCommand(layoutState: layoutState)),
            Button.icon(
              CommandWrapper(
                ChangeCurrentThread(null),
                icon: Value(PlotIcon.back),
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
        _buildTitleWithSearch(
          context,
          layoutState,
          state,
          hasActivity,
          priorityPageHidden,
          notifier,
        ),
    ];

    // --- Build suffixes ---
    final thread = state.thread;
    final suffixes = <Widget>[
      // Active tag toggles (when thread is visible)
      if (thread != null) ..._buildActiveTagToggles(context, thread),

      // Todo toggle (when thread is visible)
      if (thread != null) _buildTodoToggle(context, thread),

      // Edit thread (when thread is visible). Hidden for read-only viewers.
      if (thread != null && !thread.isReadOnly)
        Button.icon(EditThread(thread)),

      // Share thread (when thread is visible). Hidden for read-only viewers.
      if (thread != null && !thread.isReadOnly)
        SharedCommandButton(thread: thread),

      // New Thread button (multiPanel only, since bottom nav has it otherwise)
      if (layoutState.multiPanel && !state.context.isTwistDev)
        Button.icon(NewThread()),

      Button.icon(_buildMenuCommand(state, layoutState, notifier)),

      // Windows window control padding
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),

      // Keep suffixes non-empty so forui's _FRootHeader does not insert its
      // 44 px empty-case placeholder — let the title row drive header height.
      const SizedBox.shrink(),
    ];

    Widget header = FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => ClipRect(
          key: _headerKey,
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
                padding: EdgeInsetsGeometryDelta.add(EdgeInsets.zero),
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
      color: context.theme.colors.foreground.withValues(alpha: 0.7),
    );
  }

  Widget _buildTitleWithSearch(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    bool hasActivity,
    bool priorityPageHidden,
    ThreadHeaderNotifier? notifier,
  ) {
    final search = _searchButton();

    // Thread open while the PriorityPage panel is hidden: show thread title
    // (or hide the title when the thread is a new draft without a title).
    if (priorityPageHidden && hasActivity) {
      final thread = state.thread;
      if (thread == null) {
        return const Expanded(child: SizedBox.shrink());
      }

      return Expanded(
        child: Row(
          spacing: 8,
          children: [
            Flexible(
              child: Text(
                thread.displayTitle,
                overflow: TextOverflow.ellipsis,
                textHeightBehavior: const TextHeightBehavior(),
                style: context.theme.typography.sm.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.theme.colors.foreground,
                ),
              ),
            ),
            search,
          ],
        ),
      );
    }

    // Single panel: show the priority label.
    if (!layoutState.multiPanel) {
      return Expanded(
        child: Row(
          spacing: 8,
          children: [
            Flexible(child: PriorityLabel(priority: state.context)),
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
    List<Command> buildFilters(BuildContext ctx) {
      // Merge priority tags and note tags, deduplicated by Tag identity
      final allTags = <Tag, (Tag, int)>{};
      for (final tagData in state.tags) {
        allTags[tagData.$1] = tagData;
      }
      if (notifier?.isThreadVisible == true) {
        for (final tagData in notifier!.tags) {
          allTags.putIfAbsent(tagData.$1, () => tagData);
        }
      }

      return [
        ...state.iconCounts.map((d) => ToggleIconFilter(d.$1, context: ctx)),
        ...allTags.keys.map((tag) => ToggleActivityFilter(tag, context: ctx)),
        // Active filters not in current tag counts
        ...state.filter
            .where((tag) => !allTags.containsKey(tag))
            .map((tag) => ToggleActivityFilter(tag, context: ctx)),
      ];
    }

    final hasActiveFilters =
        state.filter.isNotEmpty ||
        state.iconFilter.isNotEmpty ||
        (notifier?.filter.isNotEmpty == true);

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
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (buildFilters(context).isNotEmpty)
                        Button.icon(
                          PickFilterCommand(
                            filterCommandsBuilder: buildFilters,
                          ),
                          selected: hasActiveFilters,
                        ),
                      Button.icon(
                        ToggleSearchCommand(
                          searchExpanded: _searchExpanded,
                          onToggle: _closeSearch,
                        ),
                      ),
                    ],
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
        CommandWrapper(StartThread(thread), icon: Value(PlotIcon.addTodo)),
        color: context.theme.plotColors.muted,
      );
    } else {
      final hasPending = thread.outstandingTasks;
      todoIcon = Button.icon(
        CommandWrapper(
          FinishThread(thread),
          icon: Value(hasPending ? FontAwesomeIcons.circle : PlotIcon.todo),
          hoverIcon: hasPending
              ? Value(FontAwesomeIcons.circleCheck)
              : const Value<IconData?>.absent(),
          title: 'Remove from agenda',
        ),
        selected: true,
        selectedColor: threadColor,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [todoIcon, calendarIcon],
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

  Widget _buildNoPriorityHeader(
    BuildContext context,
    LayoutState layoutState,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );

    final titleChildren = <Widget>[
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),
      const Expanded(child: SizedBox.shrink()),
    ];

    final suffixes = <Widget>[
      Button.icon(_buildNoPriorityMenuCommand()),
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
      const SizedBox.shrink(),
    ];

    Widget header = FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => ClipRect(
          key: _headerKey,
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
                padding: EdgeInsetsGeometryDelta.add(EdgeInsets.zero),
              ),
              title: Row(spacing: 8, children: titleChildren),
              suffixes: suffixes,
            ),
          ),
        ),
      ),
    );

    if (Platform.instance.isWindows) {
      header = DragToMoveArea(child: header);
    }
    return header;
  }

  Command _buildNoPriorityMenuCommand() {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final showAll = context
            .read<LocalPreferencesBloc>()
            .state
            .showAllPriorities;
        return Commands(
          groups: [
            StaticCommandGroup(
              title: 'View',
              commands: [
                ToggleArchivedPrioritiesFilter(showAllPriorities: showAll),
              ],
            ),
          ],
        );
      },
    );
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
        // Capture the bloc here — when ArchiveThread runs through the modal
        // it may dispatch with an Overlay-rooted context that can't resolve
        // the bloc, which would skip the optimistic feed update.
        final priorityBloc = context.read<PriorityBloc?>();
        // Build priority groups before any await so BuildContext is not
        // carried across an async gap.
        final priorityGroups = currentPriorityCommandGroups(
          state.thread?.priority ?? state.context,
          context: context,
        );
        final threadGroups = thread != null
            ? await threadCommandGroups(thread, priorityBloc: priorityBloc)
            : <StaticCommandGroup>[];
        return Commands(
          groups: [...threadGroups, ...priorityGroups],
        );
      },
    );
  }
}
