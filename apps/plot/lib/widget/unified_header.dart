import 'dart:async';
import 'package:flutter/scheduler.dart' show Ticker;
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
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/pomodoro_ring.dart';
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

    final leadingWidgets = _buildLeadingWidgets(
      context,
      layoutState,
      hasActivity,
      resolvedToolbarPadding,
    );
    final rightWidgets = _buildRightWidgets(
      context,
      layoutState,
      state,
      notifier,
      resolvedToolbarPadding,
    );

    final titleSection = _searchExpanded
        ? _buildSearchField(context, layoutState, state, notifier)
        : _buildTitle(
            context,
            layoutState,
            state,
            hasActivity,
            priorityPageHidden,
          );

    // In multi-panel mode the title is centered. Mirror each side with an
    // invisible (but space-occupying) copy of the opposite side's buttons so
    // both halves of the [Expanded] title slot have equal width — the title
    // text then truly centers on the window midpoint regardless of how many
    // buttons live on either side. The mirrors stay in the layout but skip
    // paint, hit-testing, and semantics.
    final List<Widget> titleRowChildren;
    final List<Widget> headerSuffixes;
    if (layoutState.multiPanel) {
      Widget mirror(List<Widget> children) => Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      );
      Widget group(List<Widget> children) => Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      );

      titleRowChildren = <Widget>[
        if (leadingWidgets.isNotEmpty) group(leadingWidgets),
        if (rightWidgets.isNotEmpty) mirror(rightWidgets),
        titleSection,
        if (leadingWidgets.isNotEmpty) mirror(leadingWidgets),
        if (rightWidgets.isNotEmpty) group(rightWidgets),
      ];
      headerSuffixes = const <Widget>[];
    } else {
      titleRowChildren = <Widget>[...leadingWidgets, titleSection];
      headerSuffixes = rightWidgets;
    }

    // In multi-panel mode, the header sits transparently on the priority-
    // tinted frame background painted at the page level. In single-panel
    // mode, paint the darkest panel background directly (a wrapping
    // darkenTheme would dim foreground/muted lightness too and reduce icon
    // contrast against the darkened surface).
    final BoxDecoration decoration = layoutState.multiPanel
        ? const BoxDecoration()
        : BoxDecoration(
            color: context.colour.panelDarkestBackground,
            border: Border(
              bottom: BorderSide(
                color: context.theme.colors.border,
                width: 1,
              ),
            ),
          );
    Widget header = ClipRect(
      key: _headerKey,
      child: DecoratedBox(
        decoration: decoration,
        child: FHeader(
          style: FHeaderStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.add(EdgeInsets.zero),
          ),
          title: Row(spacing: 8, children: titleRowChildren),
          suffixes: headerSuffixes,
        ),
      ),
    );

    // Wrap with DragToMoveArea on Windows
    if (Platform.instance.isWindows) {
      header = DragToMoveArea(child: header);
    }

    return header;
  }

  /// Leading widgets shown before the title (window padding + panel
  /// navigation buttons). Returned as a flat list so [_buildHeader] can mirror
  /// the group on both sides of the title for centering in multi-panel mode.
  List<Widget> _buildLeadingWidgets(
    BuildContext context,
    LayoutState layoutState,
    bool hasActivity,
    EdgeInsets resolvedToolbarPadding,
  ) {
    final muted = context.theme.plotColors.muted;
    // All header icon buttons share the footer ListTile's coloring:
    // [plotColors.muted] at rest and [theme.colors.foreground] on hover
    // (the latter is Button.icon's default hoverColor when a [color] is set).
    final Widget navigation;
    // Single-panel with thread: back button clears the thread.
    if (hasActivity && !layoutState.multiPanel) {
      navigation = Button.icon(
        CommandWrapper(ChangeCurrentThread(null), icon: Value(PlotIcon.back)),
        color: muted,
      );
    }
    // Single-panel without thread: no leading button. Priorities is its
    // own bottom-nav tab now, so the previous "back to Priorities" arrow
    // would just duplicate the tab bar and look like history navigation.
    else if (!layoutState.multiPanel) {
      navigation = const SizedBox.shrink();
    }
    // Multi-panel right-only with a thread visible: back + open priorities
    // + open threads. Back clears the thread but keeps the middle panel
    // closed, so the user can return to the priority page without the
    // thread shrinking.
    else if (layoutState.multiPanel &&
        !layoutState.leftPanelVisible &&
        !layoutState.middlePanelVisible &&
        hasActivity) {
      navigation = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(ToggleLeftSidebarCommand(isVisible: false), color: muted),
          Button.icon(
            ToggleMiddleSidebarCommand(isVisible: false),
            color: muted,
          ),
          Button.icon(
            CommandWrapper(
              ChangeCurrentThread(null),
              icon: Value(PlotIcon.back),
            ),
            color: muted,
          ),
        ],
      );
    }
    // 2-panel left+right with activity: the priority page (threads list)
    // is hidden, so add a back button alongside the cycle button to let
    // the user return to it.
    else if (layoutState.isTwoPanel &&
        layoutState.leftPanelVisible &&
        !layoutState.middlePanelVisible &&
        hasActivity &&
        context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth) {
      navigation = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            CyclePanelsCommand(layoutState: layoutState),
            color: muted,
          ),
          Button.icon(
            CommandWrapper(
              ChangeCurrentThread(null),
              icon: Value(PlotIcon.back),
            ),
            color: muted,
          ),
        ],
      );
    }
    // 2-panel browsing (960–1309px): cycle
    else if (layoutState.isTwoPanel &&
        context.read<LayoutBloc>().width < LayoutState.threePanelMinWidth) {
      navigation = Button.icon(
        CyclePanelsCommand(layoutState: layoutState),
        color: muted,
      );
    }
    // ≥ 1310px right-only: priorities icon + open threads
    else if (layoutState.multiPanel &&
        !layoutState.leftPanelVisible &&
        !layoutState.middlePanelVisible) {
      navigation = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(ToggleLeftSidebarCommand(isVisible: false), color: muted),
          Button.icon(
            ToggleMiddleSidebarCommand(isVisible: false),
            color: muted,
          ),
        ],
      );
    }
    // ≥ 1310px with sidebar(s): explicit toggle buttons
    else {
      navigation = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            ToggleLeftSidebarCommand(isVisible: layoutState.leftPanelVisible),
            color: muted,
          ),
          if (!(layoutState.leftPanelVisible &&
              layoutState.middlePanelVisible))
            Button.icon(
              ToggleMiddleSidebarCommand(
                isVisible: layoutState.middlePanelVisible,
              ),
              color: muted,
            ),
        ],
      );
    }

    return <Widget>[
      // macOS traffic light padding
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),
      navigation,
    ];
  }

  /// Right-side widgets shown after the title (thread actions, new-thread,
  /// search, menu, window padding). Used either as FHeader suffixes
  /// (single-panel) or mirrored into the title row (multi-panel).
  List<Widget> _buildRightWidgets(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
    EdgeInsets resolvedToolbarPadding,
  ) {
    final thread = state.thread;
    return <Widget>[
      // Active tag toggles (when thread is visible)
      if (thread != null) ..._buildActiveTagToggles(context, thread),

      // Todo toggle (when thread is visible)
      if (thread != null) _buildTodoToggle(context, thread),

      // Edit thread (when thread is visible). Hidden for read-only viewers.
      if (thread != null && !thread.isReadOnly)
        Button.icon(
          EditThread(thread),
          color: context.theme.plotColors.muted,
        ),

      // Share thread (when thread is visible). Hidden for read-only viewers.
      if (thread != null && !thread.isReadOnly)
        SharedCommandButton(thread: thread),

      // New Thread button (multiPanel only, since bottom nav has it otherwise)
      if (layoutState.multiPanel && !state.context.isTwistDev)
        Button.icon(NewThread(), color: context.theme.plotColors.muted),

      // Hide search in single-panel mode when viewing a thread — the header
      // is dedicated to thread actions, and search would target the
      // priority's thread list which isn't visible.
      if (layoutState.multiPanel || thread == null) _searchButton(),

      Button.icon(
        _buildMenuCommand(state, layoutState, notifier),
        color: context.theme.plotColors.muted,
      ),

      // Windows window control padding
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
    ];
  }

  Widget _searchButton() {
    // Keep the header-side button as the search icon even while search is
    // expanded — the close affordance lives inside the input as an X. The
    // command still toggles; _toggleSearch reads _searchExpanded to decide.
    return Button.icon(
      ToggleSearchCommand(searchExpanded: false, onToggle: _toggleSearch),
      color: context.theme.plotColors.muted,
    );
  }

  Widget _buildTitle(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    bool hasActivity,
    bool priorityPageHidden,
  ) {
    final alignment = layoutState.multiPanel
        ? Alignment.center
        : Alignment.centerLeft;

    // Pair a title widget with the time-tracking pill so the two read as
    // one unit. The pill sits to the right of the title with a small gap
    // and stays out of the row entirely on twist-dev priorities (which
    // don't track time). The sub-priorities scope toggle, when present,
    // lives inline with the priority leaf inside [PriorityLabel] — see
    // the priority-label branches below.
    Widget withTrackingPill(Widget title) {
      if (state.context.isTwistDev) return title;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: title),
          const SizedBox(width: 8),
          _PriorityHeaderTrackingControl(priority: state.context),
        ],
      );
    }

    // Caret + toggle wiring shared by the single- and multi-panel priority
    // titles. Mirrors the priorities-list expand caret: chevronDown while
    // sub-priority content is rolled up into this feed (the default),
    // chevronRight while it's collapsed away (direct-only feed).
    final IconData scopeCaret = state.hideSubPriorities
        ? FontAwesomeIcons.chevronDown
        : FontAwesomeIcons.chevronRight;
    void toggleScope() => context.run(
      ToggleHideSubPriorities(context: context),
    );

    // Thread open while the PriorityPage panel is hidden: show thread title
    // (or hide the title when the thread is a new draft without a title).
    if (priorityPageHidden && hasActivity) {
      final thread = state.thread;
      if (thread == null) {
        return const Expanded(child: SizedBox.shrink());
      }

      return Expanded(
        child: Align(
          alignment: alignment,
          child: withTrackingPill(
            Text(
              thread.displayTitle,
              overflow: TextOverflow.ellipsis,
              textHeightBehavior: const TextHeightBehavior(),
              style: context.theme.typography.sm.copyWith(
                fontWeight: FontWeight.w600,
                color: context.theme.colors.foreground,
              ),
            ),
          ),
        ),
      );
    }

    // Wrap the priority-driven title so the header swaps to the
    // selected event's title (and back) without manual invalidation.
    return Expanded(
      child: Align(
        alignment: alignment,
        child: BlocBuilder<NowBloc, NowState>(
          buildWhen: (prev, next) {
            final p = prev is NowLoaded ? prev.currentEvent : null;
            final n = next is NowLoaded ? next.currentEvent : null;
            return p?.id != n?.id ||
                p?.displayTitle != n?.displayTitle;
          },
          builder: (context, nowState) {
            final currentEvent =
                nowState is NowLoaded ? nowState.currentEvent : null;
            if (currentEvent != null) {
              return withTrackingPill(
                Text(
                  currentEvent.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  textHeightBehavior: const TextHeightBehavior(),
                  style: context.theme.typography.sm.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.theme.colors.foreground,
                  ),
                ),
              );
            }
            if (!layoutState.multiPanel) {
              return withTrackingPill(
                PriorityLabel(
                  priority: state.context,
                  boldLeaf: true,
                  leafTrailingIcon: scopeCaret,
                  onLeafTap: toggleScope,
                ),
              );
            }
            return withTrackingPill(
              PrioritySelector(
                selected: state.context,
                onSelect: (p) => context.run(ChangeCurrentPriority(p)),
                leafTrailingIcon: scopeCaret,
                onLeafTap: toggleScope,
              ),
            );
          },
        ),
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
        alignment: layoutState.multiPanel
            ? Alignment.center
            : Alignment.centerLeft,
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
                          color: context.theme.plotColors.muted,
                        ),
                      Button.icon(
                        ToggleSearchCommand(
                          searchExpanded: true,
                          onToggle: _closeSearch,
                        ),
                        color: context.theme.plotColors.muted,
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
      color: isScheduled ? null : context.theme.plotColors.muted,
    );

    // Icon 2: To-do state icon
    final Widget todoIcon;
    if (!isTodo) {
      todoIcon = Button.icon(
        CommandWrapper(StartThread(thread), icon: Value(PlotIcon.addTodo)),
        color: context.theme.plotColors.muted,
      );
    } else {
      todoIcon = Button.icon(
        CommandWrapper(
          FinishThread(thread),
          icon: Value(FontAwesomeIcons.circle),
          hoverIcon: Value(FontAwesomeIcons.circleCheck),
          title: 'Finish',
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
        .map(
          (tag) => Button.icon(
            ToggleThreadTag(thread, tag),
            color: context.theme.plotColors.muted,
          ),
        )
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
      Button.icon(
        _buildNoPriorityMenuCommand(),
        color: context.theme.plotColors.muted,
      ),
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
      const SizedBox.shrink(),
    ];

    // Multi-panel: transparent over the priority-tinted frame painted at
    // the page level. Single-panel: opaque darkest-panel background.
    final BoxDecoration decoration = layoutState.multiPanel
        ? const BoxDecoration()
        : BoxDecoration(
            color: context.colour.panelDarkestBackground,
            border: Border(
              bottom: BorderSide(
                color: context.theme.colors.border,
                width: 1,
              ),
            ),
          );
    Widget header = ClipRect(
      key: _headerKey,
      child: DecoratedBox(
        decoration: decoration,
        child: FHeader(
          style: FHeaderStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.add(EdgeInsets.zero),
          ),
          title: Row(spacing: 8, children: titleChildren),
          suffixes: suffixes,
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

/// Compact time-tracking pill in the priority header.
///
/// Sits beside the header title and reads as one unit with it. Two states:
///
/// Pomodoro-style countdown pill that lives next to the priority title.
///
/// Three visible states, all derived from
/// `NowLoaded.pomodoroState`:
/// * **Inactive** — outline pill with a play glyph + planned duration.
///   Tap to start a session; +/− (on hover) stage the duration.
/// * **Active** — outline pill with a clockwise progress ring tracing
///   elapsed/planned, label showing rounded-up remaining minutes. Tap
///   to pause (the remaining time is preserved so a later Start picks
///   up exactly where it left off). `+` snaps remaining UP to the next
///   [kPomodoroStep] boundary; `−` shaves the same step off, or snaps
///   remaining to [kMinPomodoro] when less than a step is left.
/// * **Grace** — pomodoro expired, session still recording for an
///   additional [kPomodoroGrace]. Label pulses "0m" against the muted
///   color. Tap to pause; + extends, − also lands through
///   [RemoveTime] (which floors at [kMinPomodoro]).
///
/// All taps run through [Command] subclasses so analytics fire and
/// keyboard shortcuts can be attached without changing the widget.
class _PriorityHeaderTrackingControl extends StatefulWidget {
  const _PriorityHeaderTrackingControl({required this.priority});

  final Priority priority;

  @override
  State<_PriorityHeaderTrackingControl> createState() =>
      _PriorityHeaderTrackingControlState();
}

class _PriorityHeaderTrackingControlState
    extends State<_PriorityHeaderTrackingControl>
    with TickerProviderStateMixin {
  bool _hovered = false;
  bool _centerHovered = false;
  late final Ticker _ticker;
  // Drives a periodic rebuild so the countdown text and progress ring
  // stay in sync with wall-clock time without depending on NowBloc to
  // emit (it doesn't refresh on its own — it only re-emits when the
  // upstream streams change).
  Duration _lastTick = Duration.zero;
  late final AnimationController _pulseController;

  // Narrow stadium pill that now only shows the countdown text. The
  // play affordance lives outside the pill as a separate header icon
  // button, freed up width that previously held the play glyph.
  static const double _pillWidth = 88;
  static const double _pillHeight = 22;
  // Ghost +/− button hit areas. Sized to abut the centered countdown
  // text on each side so every horizontal pixel of the pill is one of
  // three clear targets: −, duration/pause, +.
  static const double _buttonWidth = 22;

  @override
  void initState() {
    super.initState();
    // Tick at ~4Hz: fast enough that the rounded-up countdown flips
    // promptly at minute boundaries and the ring fill stays smooth,
    // but cheap enough to keep on a single Ticker.
    _ticker = createTicker((elapsed) {
      if (elapsed - _lastTick < const Duration(milliseconds: 250)) return;
      _lastTick = elapsed;
      if (mounted) setState(() {});
    });
    _ticker.start();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        if (nowState is! NowLoaded) return const SizedBox.shrink();
        // Show the pill against whichever priority is currently in
        // context — the BlocBuilder rebuilds on context changes, but
        // pomodoro state is per the context priority.
        final isContext = nowState.context?.id == widget.priority.id;
        if (!isContext) return const SizedBox.shrink();

        final live = _LivePomodoro.compute(nowState);
        final isInactive = live.state == PomodoroState.inactive;

        // When the pill collapses to the play button, the MouseRegions
        // inside _buildPill are unmounted without firing onExit, so
        // _hovered / _centerHovered would otherwise stay `true` from the
        // pause click. Next time the pill remounts, _PillLabel would
        // render the pause icon (centerHovered) instead of the duration.
        // Reset both flags so the MouseRegions re-fire onEnter cleanly
        // when the pill comes back.
        if (isInactive && (_hovered || _centerHovered)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (!_hovered && !_centerHovered) return;
            setState(() {
              _hovered = false;
              _centerHovered = false;
            });
          });
        }

        // Inactive: render a plain header-style "Start timer" icon
        // button. Active/grace: render the countdown pill. AnimatedSize
        // animates the trailing-widget width so the title slides
        // smoothly across the swap.
        final Widget child = isInactive
            ? Button.icon(
                StartTimer(),
                color: context.theme.plotColors.muted,
              )
            : _buildPill(context, nowState, live);

        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.centerLeft,
          child: child,
        );
      },
    );
  }

  /// Active/grace pill. Inactive state never reaches this method —
  /// [build] swaps in a header-style start button instead.
  Widget _buildPill(BuildContext context, NowLoaded state, _LivePomodoro live) {
    final accent = context.colour.colours.fromTheme(
      widget.priority.displayColor,
    );
    final muted = context.theme.plotColors.muted;
    final foreground = context.theme.colors.foreground;
    final isGrace = live.state == PomodoroState.grace;
    final progress = isGrace ? 1.0 : live.progress;

    final ringBackground = accent.withValues(alpha: 0.20);
    final ringForeground = accent.withValues(alpha: _hovered ? 1.0 : 0.85);
    final backgroundColor = _hovered
        ? accent.withValues(alpha: 0.08)
        : const Color(0x00000000);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: _pillWidth,
        height: _pillHeight,
        child: Stack(
          alignment: Alignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const SizedBox.expand(),
            ),
            CustomPaint(
              size: const Size(_pillWidth, _pillHeight),
              painter: PomodoroRingPainter(
                progress: progress,
                backgroundColor: ringBackground,
                foregroundColor: ringForeground,
              ),
            ),
            // Fallback tap layer covering the full pill — for touch
            // users, where +/− are invisible (IgnorePointer-ignored)
            // and the center band doesn't span the whole pill. Lets a
            // tap anywhere on the pill still pause the timer.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.run(StopTimer()),
              ),
            ),
            // Center band — sized exactly between the +/− hit zones so
            // hovering on +/− doesn't trigger the center swap. Owns the
            // duration text and the on-hover swap (pause icon while
            // active; stop icon + "Stop" label during grace, since the
            // pomodoro has expired and the click ends the session
            // rather than preserving remaining time).
            Positioned(
              left: _buttonWidth,
              right: _buttonWidth,
              top: 0,
              bottom: 0,
              child: MouseRegion(
                onEnter: (_) => setState(() => _centerHovered = true),
                onExit: (_) => setState(() => _centerHovered = false),
                child: FTooltip(
                  tipBuilder: (context, controller) =>
                      Text(isGrace ? 'Stop timer' : 'Pause timer'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => context.run(StopTimer()),
                    child: _PillLabel(
                      live: live,
                      accent: accent,
                      foreground: foreground,
                      pulseController: _pulseController,
                      centerHovered: _centerHovered,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _buttonWidth,
              child: live.remaining <= kMinPomodoro
                  // Below the 5-minute floor there's nothing left to
                  // shave — the minus button becomes a Stop affordance
                  // so the position still has a useful action instead
                  // of going inert.
                  ? _HoverButton(
                      visible: _hovered,
                      icon: FontAwesomeIcons.stop,
                      color: muted,
                      hoverColor: foreground,
                      tooltip: 'Stop',
                      onTap: () => context.run(EndTimer()),
                      enabled: true,
                    )
                  : _HoverButton(
                      visible: _hovered,
                      icon: FontAwesomeIcons.minus,
                      color: muted,
                      hoverColor: foreground,
                      tooltip: live.remaining > kPomodoroStep
                          ? 'Remove 15 minutes'
                          : 'Set to 5 minutes',
                      onTap: () => context.run(RemoveTime()),
                      enabled: RemoveTime().enabled(context),
                    ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _buttonWidth,
              child: _HoverButton(
                visible: _hovered,
                icon: FontAwesomeIcons.plus,
                color: muted,
                hoverColor: foreground,
                tooltip: 'Add time',
                onTap: () => context.run(AddTime()),
                enabled: AddTime().enabled(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Snapshot of the pomodoro at a specific [Time.now()] moment.
///
/// `NowLoaded.now` is frozen at the moment the bloc last emitted, so
/// `state.pomodoroProgress` / `state.pomodoroRemaining` would only
/// advance when an upstream stream pushed. The pill needs sub-minute
/// updates (smooth ring fill, prompt countdown flips at the minute
/// boundary), so the pill recomputes these values from `Time.now()` on
/// every frame tick.
class _LivePomodoro {
  const _LivePomodoro({
    required this.state,
    required this.remaining,
    required this.progress,
  });

  final PomodoroState state;
  final Duration remaining;
  final double progress;

  static _LivePomodoro compute(NowLoaded loaded) {
    final session = loaded.session;
    final ctx = loaded.context;
    if (session == null
        || ctx == null
        || session.archivedAt != null
        || session.source != 'active'
        || session.priority?.id != ctx.id
        || !session.at.isNow()
        || session.pomodoroAt == null
        || session.pomodoro == null) {
      return const _LivePomodoro(
        state: PomodoroState.inactive,
        remaining: Duration.zero,
        progress: 0,
      );
    }
    final now = Time.now();
    final pomodoroAt = session.pomodoroAt!;
    final pomodoro = session.pomodoro!;
    final end = pomodoroAt.add(pomodoro);
    final graceEnd = end.add(kPomodoroGrace);

    if (!now.isBefore(graceEnd)) {
      return const _LivePomodoro(
        state: PomodoroState.inactive,
        remaining: Duration.zero,
        progress: 0,
      );
    }
    if (!now.isBefore(end)) {
      return const _LivePomodoro(
        state: PomodoroState.grace,
        remaining: Duration.zero,
        progress: 1,
      );
    }
    final remaining = end.difference(now);
    final totalMs = pomodoro.inMilliseconds;
    final elapsedMs = now.difference(pomodoroAt).inMilliseconds;
    final ratio = totalMs <= 0 ? 1.0 : (elapsedMs / totalMs).clamp(0.0, 1.0);
    return _LivePomodoro(
      state: PomodoroState.active,
      remaining: remaining.isNegative ? Duration.zero : remaining,
      progress: ratio,
    );
  }
}

/// Centered label for the pill. Picks one of these rendering branches:
///   * Hover (grace)  → stop glyph + "Stop" label (foreground). The
///     click ends the expired session rather than preserving remaining
///     time, so the affordance differs from the active-state pause.
///   * Hover (active) → pause glyph (foreground)
///   * Grace          → pulsing `0m`
///   * Active         → `Nm` (remaining, rounded up)
class _PillLabel extends StatelessWidget {
  const _PillLabel({
    required this.live,
    required this.accent,
    required this.foreground,
    required this.pulseController,
    required this.centerHovered,
  });

  final _LivePomodoro live;
  final Color accent;
  final Color foreground;
  final AnimationController pulseController;
  final bool centerHovered;

  @override
  Widget build(BuildContext context) {
    final pomoState = live.state;
    final fontSize = context.theme.typography.sm.fontSize;

    if (centerHovered) {
      if (pomoState == PomodoroState.grace) {
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(FontAwesomeIcons.stop, size: 9, color: foreground),
              const SizedBox(width: 5),
              Text(
                'Stop',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                  height: 1,
                ),
              ),
            ],
          ),
        );
      }
      return Center(
        child: Icon(FontAwesomeIcons.pause, size: 10, color: foreground),
      );
    }

    if (pomoState == PomodoroState.grace) {
      return Center(
        child: AnimatedBuilder(
          animation: pulseController,
          builder: (context, _) {
            // Pulse between accent and a muted accent so "0m" reads as
            // urgent without strobing.
            final color = Color.lerp(
              accent.withValues(alpha: 0.30),
              accent,
              Curves.easeInOut.transform(pulseController.value),
            )!;
            return Text(
              '0m',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: color,
                height: 1,
              ),
            );
          },
        ),
      );
    }

    return Center(
      child: Text(
        _formatMinutes(live.remaining),
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: accent,
          height: 1,
        ),
      ),
    );
  }

  /// Round up to the nearest minute and format as `Nm` / `Hh Mm`.
  /// Zero clamps to `0m` so the grace pulse always has text to lerp.
  static String _formatMinutes(Duration d) {
    if (d <= Duration.zero) return '0m';
    final totalMinutes =
        (d.inSeconds + 59) ~/ 60; // ceil
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

/// Ghost +/- button. Fades in only while the pill is hovered. Sized to
/// fill its parent's height; the glyph is centered inside it.
///
/// Tracks its own hover and swaps from [color] (rest) to [hoverColor]
/// when the cursor is directly over it — matches the header-icon
/// pattern so the three pill regions (−, duration, +) read as distinct
/// clickable targets.
class _HoverButton extends StatefulWidget {
  const _HoverButton({
    required this.visible,
    required this.icon,
    required this.color,
    required this.hoverColor,
    required this.tooltip,
    required this.onTap,
    required this.enabled,
  });

  final bool visible;
  final IconData icon;
  final Color color;
  final Color hoverColor;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _selfHovered = false;

  @override
  Widget build(BuildContext context) {
    final Color resolved;
    if (!widget.enabled) {
      resolved = widget.color.withValues(alpha: 0.5);
    } else {
      resolved = _selfHovered ? widget.hoverColor : widget.color;
    }
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: widget.visible ? 1.0 : 0.0,
        child: MouseRegion(
          onEnter: (_) => setState(() => _selfHovered = true),
          onExit: (_) => setState(() => _selfHovered = false),
          child: FTooltip(
            tipBuilder: (context, controller) => Text(widget.tooltip),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? widget.onTap : null,
              child: Center(
                child: Icon(widget.icon, size: 9, color: resolved),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
