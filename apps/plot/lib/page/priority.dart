import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/widget/activity_header_notifier.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/style/spacing.dart';
import 'priorities.dart';
import 'loading.dart';

enum PriorityTab { upNext, activity }

class PriorityTabNotifier extends ValueNotifier<PriorityTab> {
  PriorityTabNotifier() : super(PriorityTab.upNext);
}

class PriorityTabProvider extends InheritedWidget {
  const PriorityTabProvider({
    required this.notifier,
    required super.child,
    super.key,
  });

  final PriorityTabNotifier notifier;

  static PriorityTabNotifier of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PriorityTabProvider>()!
        .notifier;
  }

  static PriorityTabNotifier? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PriorityTabProvider>()
        ?.notifier;
  }

  @override
  bool updateShouldNotify(PriorityTabProvider old) => notifier != old.notifier;
}

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required String priorityIdString})
    : priorityId = PriorityId.fromShortString(priorityIdString),
      _routerKey = GlobalKey(
        debugLabel:
            'PriorityWrapper_${PriorityId.fromShortString(priorityIdString).toShortString()}',
      );

  final PriorityId priorityId;
  final GlobalKey _routerKey;

  @override
  Widget wrappedRoute(BuildContext context) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      child: _PriorityCommandScope(
        child: _PriorityShortcutsProvider(
          priorityId: priorityId,
          child: ActivityHeaderNotifierProvider(
            child: Column(
              children: [
                const UnifiedHeader(),
                Expanded(
                  child: ResizablePanelLayout(
                    left: PrioritiesPage(),
                    middle: PriorityPage(priorityId: priorityId),
                    child: AutoRouter(
                      key: _routerKey,
                      placeholder: (context) => const LoadingPage(),
                      clipBehavior: Clip.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PriorityCommandScope extends StatelessWidget {
  const _PriorityCommandScope({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bloc = context.watch<PriorityBloc>();
    return CommandScope(
      commands: currentPriorityCommandGroups(bloc.state.context),
      child: child,
    );
  }
}

/// Provides global keyboard shortcuts (Cmd-Up/Down) for PriorityPage list navigation
/// that work even when focus is in ActivityPage (e.g., ActivityEditor).
class _PriorityShortcutsProvider extends StatefulWidget {
  const _PriorityShortcutsProvider({
    required this.priorityId,
    required this.child,
  });

  final PriorityId priorityId;
  final Widget child;

  @override
  State<_PriorityShortcutsProvider> createState() =>
      PriorityShortcutsProviderState();
}

class PriorityShortcutsProviderState extends State<_PriorityShortcutsProvider> {
  BidirectionalListController? _priorityListController;
  BidirectionalListController? _activityListController;
  VoidCallback? _activityEditorFocusCallback;

  void registerController(BidirectionalListController controller) {
    _priorityListController = controller;
  }

  /// When nothing is focused, focus the top of the list (index 0),
  /// since both tabs start at the top.
  void _moveFocusOrStart(
    BidirectionalListController controller,
    int offset,
    BuildContext context,
  ) {
    if (controller.focusedIndex != null) {
      controller.moveFocus(offset);
      return;
    }
    controller.requestFocus(0);
  }

  void registerActivityPanel({
    BidirectionalListController? listController,
    VoidCallback? editorFocusCallback,
  }) {
    setState(() {
      _activityListController = listController;
      _activityEditorFocusCallback = editorFocusCallback;
    });
  }

  void unregisterActivityPanel() {
    // Just update the variables directly without setState
    // No need to rebuild when unregistering during disposal
    _activityListController = null;
    _activityEditorFocusCallback = null;
  }

  @override
  Widget build(BuildContext context) {
    return _PriorityListControllerProvider(
      state: this,
      child: ActivityPanelControllerProvider(
        state: this,
        child: BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            // Always register Cmd-Up/Down for Priority list navigation
            // These should take priority over ActivityPage shortcuts
            return Actions(
              actions: {
                MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                  onInvoke: (_) {
                    // Only handle if we have a controller (meaning PriorityPage is visible)
                    if (_priorityListController != null) {
                      _moveFocusOrStart(_priorityListController!, -1, context);
                    }
                    return null;
                  },
                ),
                MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                  onInvoke: (_) {
                    if (_priorityListController != null) {
                      _moveFocusOrStart(_priorityListController!, 1, context);
                    }
                    return null;
                  },
                ),
                ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                  onInvoke: (_) {
                    // When ActivityPage or NewActivityPage is open, Escape should focus ActivityEditor
                    _activityEditorFocusCallback?.call();
                    return null;
                  },
                ),
              },
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  platformSingleActivator(LogicalKeyboardKey.arrowUp):
                      const MoveFocusUpIntent(),
                  platformSingleActivator(LogicalKeyboardKey.arrowDown):
                      const MoveFocusDownIntent(),
                  // Global Escape handler - focus ActivityEditor when ActivityPage is open
                  if (_activityEditorFocusCallback != null)
                    const SingleActivator(LogicalKeyboardKey.escape):
                        const ClearItemFocusIntent(),
                  // When middle panel is hidden, also handle plain Up/Down at global level
                  if (!layoutState
                      .middlePanelVisible) ...<ShortcutActivator, Intent>{
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                  },
                },
                child: widget.child,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// InheritedWidget to provide access to the shortcuts provider state
class _PriorityListControllerProvider extends InheritedWidget {
  const _PriorityListControllerProvider({
    required this.state,
    required super.child,
  });

  final PriorityShortcutsProviderState state;

  static PriorityShortcutsProviderState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_PriorityListControllerProvider>()
        ?.state;
  }

  @override
  bool updateShouldNotify(_PriorityListControllerProvider oldWidget) => false;
}

/// InheritedWidget to provide access to ActivityPage panel state for focus coordination
class ActivityPanelControllerProvider extends InheritedWidget {
  const ActivityPanelControllerProvider({
    required this.state,
    required super.child,
    super.key,
  });

  final PriorityShortcutsProviderState state;

  static PriorityShortcutsProviderState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ActivityPanelControllerProvider>()
        ?.state;
  }

  @override
  bool updateShouldNotify(ActivityPanelControllerProvider oldWidget) => false;
}

@RoutePage(name: "PriorityOnlyRoute")
class PriorityOnlyPage extends StatefulWidget {
  PriorityOnlyPage({
    @PathParam.inherit("priorityId") required String priorityIdString,
    super.key,
  }) : priorityId = PriorityId.fromShortString(priorityIdString);

  final PriorityId priorityId;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final layoutState = context.read<LayoutBloc>().state;
      if (layoutState.middlePanelVisible) {
        context.router.navigate(NewActivityRoute());
      }
    });
  }

  @override
  void didUpdateWidget(PriorityOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutState = context.read<LayoutBloc>().state;
    if (layoutState.middlePanelVisible) {
      context.router.navigate(NewActivityRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (layoutState.middlePanelVisible) {
          // Trigger navigation after build completes if we're not already on the new route
          if (!context.router.currentPath.endsWith('/new')) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && layoutState.middlePanelVisible) {
                context.router.navigate(NewActivityRoute());
              }
            });
          }
          return const LoadingPage();
        }
        return PriorityPage(priorityId: widget.priorityId);
      },
    );
  }
}

class PriorityPage extends StatefulWidget {
  const PriorityPage({required this.priorityId, super.key});

  final PriorityId priorityId;

  @override
  State<PriorityPage> createState() => _PriorityPageState();
}

class _PriorityPageState extends State<PriorityPage>
    with SingleTickerProviderStateMixin {
  PriorityTab _currentTab = PriorityTab.upNext;
  PriorityTabNotifier? _tabNotifier;

  /// Fraction of usable height (totalHeight - dividerHeight) for the top list.
  /// 0.0 = collapsed minimum. Values are clamped to [_minFraction, 1.0] in layout.
  double _topFraction = 0.0;
  double _minFraction = 0.0; // cached from last layout
  double _animFrom = 0.0;
  double _animTo = 0.0;
  bool _isDragging = false;

  late final AnimationController _expandController;
  final BidirectionalListController _upNextListController =
      BidirectionalListController();

  bool get _isCollapsed => _topFraction <= _minFraction + 0.005;

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _expandController.addListener(_onExpandTick);
  }

  void _onExpandTick() {
    final t = Curves.easeInOut.transform(_expandController.value);
    setState(() {
      _topFraction = lerpDouble(_animFrom, _animTo, t)!;
    });
  }

  void _onDividerTap() {
    if (_isDragging) return;
    _animFrom = _topFraction;
    _animTo = _isCollapsed ? 0.5 : _minFraction;
    _expandController.forward(from: 0.0);
  }

  void _onDividerDragStart() {
    _isDragging = true;
    _expandController.stop();
  }

  void _onDividerDragUpdate(double dy, double usableHeight) {
    if (usableHeight <= 0) return;
    setState(() {
      _topFraction = (_topFraction + dy / usableHeight).clamp(
        _minFraction,
        1.0,
      );
    });
  }

  void _onDividerDragEnd() {
    _isDragging = false;
    // Snap to collapsed if near minimum
    if (_topFraction < _minFraction + 0.02) {
      _topFraction = _minFraction;
    }
    setState(() {});
  }

  void _onTabNotifierChanged() {
    if (_tabNotifier != null && _tabNotifier!.value != _currentTab) {
      setState(() {
        _currentTab = _tabNotifier!.value;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = PriorityTabProvider.maybeOf(context);
    if (notifier != _tabNotifier) {
      _tabNotifier?.removeListener(_onTabNotifierChanged);
      _tabNotifier = notifier;
      _tabNotifier?.addListener(_onTabNotifierChanged);
      if (_tabNotifier != null) {
        _currentTab = _tabNotifier!.value;
      }
    }
  }

  @override
  void dispose() {
    _expandController.dispose();
    _upNextListController.dispose();
    _tabNotifier?.removeListener(_onTabNotifierChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PriorityBloc, PriorityState>(
      listener: (context, state) {
        final nowBloc = context.read<NowBloc>();
        nowBloc.setFocus(state.context);
        // Update theme when priority switch loading completes
        if (state.targetPriority == null) {
          nowBloc.setContext(state.context);
        }
      },
      listenWhen: (previous, current) =>
          previous.context.id != current.context.id ||
          (previous.targetPriority != null && current.targetPriority == null),
      builder: (context, state) {
        return (state.agendaItems.isEmpty &&
                !(state.doneStart && state.doneEnd))
            ? const Center(child: Spinner())
            : BlocBuilder<LayoutBloc, LayoutState>(
                builder: (context, layoutState) {
                  // On desktop, use expansion state; on mobile, use tab state
                  final isUpNext = layoutState.multiPanel
                      ? !_isCollapsed
                      : _currentTab == PriorityTab.upNext;
                  final items = isUpNext
                      ? state.upNextItems
                      : state.activityFeedItems;

                  // Build shortcuts map conditionally based on panel visibility
                  final shortcuts = <ShortcutActivator, Intent>{
                    platformSingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    platformSingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                    const SingleActivator(LogicalKeyboardKey.enter):
                        const OpenFocusedItemActionsIntent(),
                    const SingleActivator(LogicalKeyboardKey.escape):
                        const ClearItemFocusIntent(),
                    // Always register plain Up/Down to handle focus transfer to ActivityPage
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                  };

                  // Get activity panel provider to check if ActivityPage is open
                  final activityProvider =
                      ActivityPanelControllerProvider.maybeOf(context);

                  return Focus(
                    onKeyEvent: (node, event) {
                      // Only handle key down events for plain Up/Down (no modifiers)
                      if (event is! KeyDownEvent) {
                        return KeyEventResult.ignored;
                      }

                      // Check if this is plain Up/Down with no modifiers
                      final hasModifiers =
                          HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed ||
                          HardwareKeyboard.instance.isShiftPressed ||
                          HardwareKeyboard.instance.isAltPressed;
                      final isPlainUp =
                          event.logicalKey == LogicalKeyboardKey.arrowUp &&
                          !hasModifiers;
                      final isPlainDown =
                          event.logicalKey == LogicalKeyboardKey.arrowDown &&
                          !hasModifiers;

                      if ((isPlainUp || isPlainDown) &&
                          activityProvider?._activityListController != null) {
                        // Transfer focus to ActivityPage list
                        activityProvider!._activityListController!.moveFocus(
                          isPlainUp ? -1 : 1,
                        );
                        return KeyEventResult.handled;
                      }

                      // Let other keys (including Cmd-Up/Down) propagate to shortcuts
                      return KeyEventResult.ignored;
                    },
                    child: BidirectionalListSelector(
                      onActivate: (index) {
                        final item = index >= 0 && index < items.length
                            ? items[index]
                            : null;
                        item?.when(
                          header: (header) => null,
                          activity: (agendaActivity) => context.run(
                            ChangeCurrentActivity(agendaActivity.activity),
                          ),
                        );
                      },
                      builder: (context, listController) {
                        // For desktop, use expansion-based controller;
                        // for mobile, use list selector controller
                        final activeController = layoutState.multiPanel
                            ? (_isCollapsed
                                  ? listController
                                  : _upNextListController)
                            : listController;

                        // Register active controller with the global shortcuts provider
                        final provider =
                            _PriorityListControllerProvider.maybeOf(context);
                        provider?.registerController(activeController);

                        return Shortcuts(
                          shortcuts: shortcuts,
                          child: Actions(
                            actions: {
                              MoveFocusUpIntent:
                                  CallbackAction<MoveFocusUpIntent>(
                                    onInvoke: (intent) {
                                      final provider =
                                          _PriorityListControllerProvider.maybeOf(
                                            context,
                                          );
                                      provider?._moveFocusOrStart(
                                        activeController,
                                        -1,
                                        context,
                                      );
                                      return null;
                                    },
                                  ),
                              MoveFocusDownIntent:
                                  CallbackAction<MoveFocusDownIntent>(
                                    onInvoke: (intent) {
                                      final provider =
                                          _PriorityListControllerProvider.maybeOf(
                                            context,
                                          );
                                      provider?._moveFocusOrStart(
                                        activeController,
                                        1,
                                        context,
                                      );
                                      return null;
                                    },
                                  ),
                              OpenFocusedItemActionsIntent:
                                  CallbackAction<OpenFocusedItemActionsIntent>(
                                    onInvoke: (_) {
                                      final focusedIndex =
                                          activeController.focusedIndex;
                                      if (focusedIndex != null &&
                                          focusedIndex >= 0 &&
                                          focusedIndex < items.length) {
                                        context.run(
                                          OpenFocusedItemActions(
                                            activeController,
                                            (index) {
                                              final item =
                                                  index >= 0 &&
                                                      index < items.length
                                                  ? items[index]
                                                  : null;
                                              return item?.when<
                                                    List<StaticCommandGroup>
                                                  >(
                                                    activity: (agendaActivity) =>
                                                        activityCommandGroups(
                                                          agendaActivity
                                                              .activity,
                                                        ),
                                                    header: (header) {
                                                      if (header.priority ==
                                                              null ||
                                                          header.priority!.id ==
                                                              state
                                                                  .context
                                                                  .id) {
                                                        return <
                                                          StaticCommandGroup
                                                        >[];
                                                      }
                                                      return priorityCommandGroups(
                                                        header.priority!,
                                                      );
                                                    },
                                                  ) ??
                                                  <StaticCommandGroup>[];
                                            },
                                          ),
                                        );
                                      }
                                      return null;
                                    },
                                  ),
                              ClearItemFocusIntent:
                                  CallbackAction<ClearItemFocusIntent>(
                                    onInvoke: (_) {
                                      activeController.clearFocus();
                                      // When ActivityPage is open, also focus ActivityEditor
                                      activityProvider
                                          ?._activityEditorFocusCallback
                                          ?.call();
                                      return null;
                                    },
                                  ),
                            },
                            child: CommandScope(
                              commandsBuilder: () {
                                final index = activeController.lastFocusedIndex;
                                if (index == null) {
                                  return <StaticCommandGroup>[];
                                }
                                final item = index >= 0 && index < items.length
                                    ? items[index]
                                    : null;
                                return item?.when<List<StaticCommandGroup>>(
                                      activity: (agendaActivity) =>
                                          activityCommandGroups(
                                            agendaActivity.activity,
                                          ),
                                      header: (header) {
                                        // Skip if priority is null or this is the context priority (already added by outer CommandScope)
                                        if (header.priority == null ||
                                            header.priority!.id ==
                                                state.context.id) {
                                          return <StaticCommandGroup>[];
                                        }
                                        return priorityCommandGroups(
                                          header.priority!,
                                        );
                                      },
                                    ) ??
                                    <StaticCommandGroup>[];
                              },
                              listenable: activeController,
                              child: Scaffold(
                                scrollable: false,
                                translucent: true,
                                childPad: false,
                                body: layoutState.multiPanel
                                    ? _buildDesktopBody(
                                        context,
                                        state,
                                        listController,
                                      )
                                    : _buildList(
                                        context,
                                        state,
                                        items,
                                        listController,
                                        ScrollControllerContext.of(context),
                                        enableReorder: isUpNext,
                                        doneEnd: isUpNext
                                            ? state.doneEnd
                                            : state.doneStart,
                                      ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
      },
    );
  }

  Widget _buildDesktopBody(
    BuildContext context,
    PriorityState state,
    BidirectionalListController activityController,
  ) {
    final isSearching =
        state.search.isNotEmpty || state.filter.isNotEmpty;

    // When searching, show only the activity feed at full height
    if (isSearching) {
      return _buildActivityFeed(
        context,
        state,
        state.activityFeedItems,
        activityController,
        ScrollControllerContext.of(context),
      );
    }

    final upNextItems = state.upNextItems;
    final activityFeedItems = state.activityFeedItems;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        const dividerHeight = 30.0;

        // Check if the first activity has a label (sub-priority or event
        // timing), which makes the item taller.
        final firstActivity =
            upNextItems.whereType<AgendaActivityItem>().firstOrNull;
        final hasSubPriorityLabel = firstActivity != null &&
            firstActivity.activity.priority.id != state.context.id;
        final isTimedEvent = firstActivity != null &&
            firstActivity.activity.type == ActivityType.event &&
            firstActivity.activity.at?.start != null &&
            firstActivity.activity.at!.start!.toTimeOfDay().isMidnight != true;
        final hasLabel = hasSubPriorityLabel || isTimedEvent;
        final double subPriorityExtra;
        if (hasLabel) {
          final xsFontSize =
              context.theme.typography.xs.fontSize ?? 12.0;
          final xsLineHeight =
              context.theme.typography.xs.height ?? 1.2;
          subPriorityExtra = xsFontSize * xsLineHeight + 2.0;
        } else {
          subPriorityExtra = 0.0;
        }
        final collapsedTopHeight = 70.0 + subPriorityExtra;

        final usableHeight = totalHeight - dividerHeight;

        // Cache minFraction so _isCollapsed / _onDividerTap work outside layout
        _minFraction = usableHeight > 0
            ? collapsedTopHeight / usableHeight
            : 0.0;

        final fraction = _topFraction.clamp(_minFraction, 1.0);
        final topHeight = fraction * usableHeight;
        final bottomHeight = (usableHeight - topHeight).clamp(
          0.0,
          usableHeight,
        );
        final isCollapsed = fraction <= _minFraction + 0.005;

        return Column(
          children: [
            SizedBox(
              height: topHeight,
              child: ClipRect(
                child: isCollapsed
                    ? _buildCollapsedUpNext(context, state, upNextItems)
                    : _buildList(
                        context,
                        state,
                        upNextItems,
                        _upNextListController,
                        null,
                        enableReorder: true,
                        doneEnd: state.doneEnd,
                      ),
              ),
            ),
            FAnimatedTheme(
              data: darkenTheme(
                context,
                context.theme,
                context.colour,
                steps: 2,
              ),
              child: SizedBox(
                height: dividerHeight,
                child: _SplitViewDivider(
                  expanded: !isCollapsed,
                  onTap: _onDividerTap,
                  onDragStart: _onDividerDragStart,
                  onDragUpdate: (dy) => _onDividerDragUpdate(dy, usableHeight),
                  onDragEnd: _onDividerDragEnd,
                ),
              ),
            ),
            SizedBox(
              height: bottomHeight,
              child: ClipRect(
                child: _buildActivityFeed(
                  context,
                  state,
                  activityFeedItems,
                  activityController,
                  ScrollControllerContext.of(context),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Builds a non-scrollable preview of the Now + Next list when collapsed,
  /// showing only the first header and first activity item.
  Widget _buildCollapsedUpNext(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
  ) {
    // Take up to 2 items: the header + first activity
    final previewItems = items.take(2).toList();
    final hasActivity = previewItems.any((item) => item is AgendaActivityItem);
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final item in previewItems)
          item.when(
            header: (header) => AgendaHeader(
              priority: header.priority,
              priorityContext: state.context,
              dateTimeRange: header.dateTimeRange,
              date: header.date,
              now: header.now,
              activity: header.activity,
              text: header.text,
              scheduleAt: header.scheduleAt,
            ),
            activity: (agendaActivity) => ActivityWidget(
              activity: agendaActivity.activity,
              selected:
                  state.activity != null &&
                  agendaActivity.activity.id == state.activity!.id,
              now: agendaActivity.now,
              context: state.context,
              showSubPriority: true,
            ),
          ),
        if (!hasActivity) _buildUpNextEmpty(context),
      ],
    );
  }

  Widget _buildUpNextEmpty(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Mark an action ',
            style: TextStyle(
              color: context.theme.colors.mutedForeground,
              fontSize: context.theme.typography.sm.fontSize,
            ),
          ),
          FaIcon(
            PlotIcon.now,
            size: context.theme.typography.sm.fontSize,
            color: context.theme.colors.mutedForeground,
          ),
          Text(
            ' Do Now to add it here',
            style: TextStyle(
              color: context.theme.colors.mutedForeground,
              fontSize: context.theme.typography.sm.fontSize,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    BidirectionalListController controller,
    ScrollController? scrollController, {
    required bool enableReorder,
    required bool doneEnd,
  }) {
    // Extract "Now" header when reordering is enabled so it stays static
    // during drag operations and items can't be placed before it.
    final hasNowHeader =
        enableReorder &&
        items.isNotEmpty &&
        items.first is AgendaHeaderItem &&
        (items.first as AgendaHeaderItem).now;
    final nowHeader = hasNowHeader ? items.first as AgendaHeaderItem : null;
    final listItems = hasNowHeader ? items.sublist(1) : items;

    final list = BidirectionalList(
      anchorOffset: 0.0,
      controller: controller,
      scrollController: scrollController,
      first: 0,
      count: listItems.length,
      doneStart: true,
      doneEnd: doneEnd,
      fetcher: (first, count) =>
          context.read<PriorityBloc>().fetchMoreAgendaItems(first, count),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= listItems.length) {
          return null;
        }
        final current = listItems[index];

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            current.when(
              header: (h) => h.date != null
                  ? 'header_date_${h.date}'
                  : h.dateTimeRange != null
                  ? 'header_event_${h.priority?.id ?? 'null'}_${h.dateTimeRange}'
                  : 'header_priority_${h.priority?.id ?? 'null'}',
              activity: (a) => 'activity_${a.activity.id}',
            ),
          ),
          children: [
            ...current.when(
              header: (header) => [
                AgendaHeader(
                  key: ValueKey(
                    header.date != null
                        ? 'agendaheader_date_${header.date}'
                        : header.dateTimeRange != null
                        ? 'agendaheader_event_${header.priority?.id ?? 'null'}_${header.dateTimeRange}'
                        : 'agendaheader_priority_${header.priority?.id ?? 'null'}',
                  ),
                  priority: header.priority,
                  priorityContext: state.context,
                  dateTimeRange: header.dateTimeRange,
                  date: header.date,
                  now: header.now,
                  activity: header.activity,
                  focusNode: focusNode,
                  text: header.text,
                  scheduleAt: header.scheduleAt,
                ),
              ],
              activity: (agendaActivity) => [
                ActivityWidget(
                  key: ValueKey('activitywidget_${agendaActivity.activity.id}'),
                  activity: agendaActivity.activity,
                  selected:
                      state.activity != null &&
                      agendaActivity.activity.id == state.activity!.id,
                  now: agendaActivity.now,
                  focusNode: focusNode,
                  context: state.context,
                  showSubPriority: true,
                  reorderableIndex: enableReorder ? reorderableIndex : null,
                ),
              ],
            ),
          ],
        );
      },
      onReorder: enableReorder
          ? (index) {
              if (index < 0 || index >= listItems.length) {
                return null;
              }
              final item = listItems[index];
              final activity = item.when<Activity?>(
                header: (header) => null,
                activity: (agendaActivity) => agendaActivity.activity,
              );
              if (activity?.todo != true || activity == null) {
                return null;
              }
              return (int newIndex) {
                final oldListIndex = index;
                final newListIndex = newIndex;

                // Map back to agendaItems indices for reorder.
                // Add 1 when header was extracted to account for it.
                final nowOffset =
                    state.agendaItems.length -
                    state.upNextItems.length +
                    (hasNowHeader ? 1 : 0);

                // Calculate prev/next from the filtered items list
                var prevIndex = newListIndex - 1;
                var nextIndex = newListIndex;
                if (oldListIndex < newListIndex) {
                  prevIndex++;
                  nextIndex++;
                }
                AgendaItem? prev;
                if (prevIndex >= 0 && prevIndex < listItems.length) {
                  prev = listItems[prevIndex];
                } else if (prevIndex < 0 && nowHeader != null) {
                  // Dragged to position 0: use the extracted header so
                  // priority context is preserved.
                  prev = nowHeader;
                }
                AgendaItem? next;
                if (nextIndex < listItems.length) {
                  next = listItems[nextIndex];
                }

                // Compute updated activity properties so the optimistic
                // state matches what _makeAgenda will produce after save.
                final prevActivity = prev?.when<Activity?>(
                  header: (_) => null,
                  activity: (a) => a.activity,
                );
                final nextActivity = next?.when<Activity?>(
                  header: (_) => null,
                  activity: (a) => a.activity,
                );
                final updatedActivity = activity.copyWith(
                  order: Order.between(
                    prevActivity?.order,
                    nextActivity?.order,
                  ),
                  on: Value(prevActivity?.on ?? nextActivity?.on),
                );

                // Update state with updated sort keys to prevent jank
                // when the schedule re-emits and _makeAgenda rebuilds.
                final nowFlag = item.when(
                  header: (_) => false,
                  activity: (a) => a.now,
                );
                context.read<PriorityBloc>().moveAgendaItem(
                  oldListIndex + nowOffset,
                  newListIndex + nowOffset,
                  updatedItem: AgendaActivityItem(
                    updatedActivity,
                    now: nowFlag,
                  ),
                );

                // Persist to database
                updatedActivity.save();
              };
            }
          : null,
    );

    if (nowHeader == null) return list;

    return Column(
      children: [
        AgendaHeader(
          priority: nowHeader.priority,
          priorityContext: state.context,
          dateTimeRange: nowHeader.dateTimeRange,
          date: nowHeader.date,
          now: nowHeader.now,
          activity: nowHeader.activity,
          text: nowHeader.text,
          scheduleAt: nowHeader.scheduleAt,
        ),
        if (listItems.isEmpty) _buildUpNextEmpty(context)
        else
          Expanded(child: list),
      ],
    );
  }

  Widget _buildActivityFeed(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    BidirectionalListController controller,
    ScrollController? scrollController,
  ) {
    return BidirectionalList(
      anchorOffset: 0.0,
      controller: controller,
      scrollController: scrollController,
      first: 0,
      count: items.length,
      doneStart: true,
      doneEnd: state.doneStart,
      fetcher: (first, count) =>
          context.read<PriorityBloc>().fetchMoreAgendaItems(first, count),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= items.length) {
          return null;
        }
        final current = items[index];

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            current.when(
              header: (h) => h.date != null
                  ? 'feed_header_date_${h.date}'
                  : 'feed_header_${h.text}',
              activity: (a) => 'feed_activity_${a.activity.id}',
            ),
          ),
          children: [
            ...current.when(
              header: (header) => [
                AgendaHeader(
                  priority: header.priority,
                  priorityContext: state.context,
                  dateTimeRange: header.dateTimeRange,
                  date: header.date,
                  now: header.now,
                  activity: header.activity,
                  focusNode: focusNode,
                  text: header.text,
                  scheduleAt: header.scheduleAt,
                ),
              ],
              activity: (agendaActivity) => [
                ActivityWidget(
                  key: ValueKey(
                    'feed_activitywidget_${agendaActivity.activity.id}',
                  ),
                  activity: agendaActivity.activity,
                  selected:
                      state.activity != null &&
                      agendaActivity.activity.id == state.activity!.id,
                  now: agendaActivity.now,
                  focusNode: focusNode,
                  context: state.context,
                  showSubPriority: true,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SplitViewDivider extends StatefulWidget {
  const _SplitViewDivider({
    required this.expanded,
    required this.onTap,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback? onDragStart;
  final void Function(double dy)? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  State<_SplitViewDivider> createState() => _SplitViewDividerState();
}

class _SplitViewDividerState extends State<_SplitViewDivider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _hovered
        ? context.theme.colors.primary
        : context.theme.colors.mutedForeground;

    return GestureDetector(
      onTap: widget.onTap,
      onVerticalDragStart: widget.onDragStart != null
          ? (_) => widget.onDragStart!()
          : null,
      onVerticalDragUpdate: widget.onDragUpdate != null
          ? (details) => widget.onDragUpdate!(details.delta.dy)
          : null,
      onVerticalDragEnd: widget.onDragEnd != null
          ? (_) => widget.onDragEnd!()
          : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          decoration: BoxDecoration(
            color: context.theme.colors.background,
            border: Border.symmetric(
              horizontal: BorderSide(
                color: context.theme.colors.border,
                width: 0.5,
              ),
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: context.theme.spacing.xl,
            vertical: context.theme.spacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Center(
                  child: FaIcon(
                    widget.expanded ? PlotIcon.up : PlotIcon.down,
                    size: context.theme.typography.sm.fontSize,
                    color: color,
                  ),
                ),
              ),
              Text(
                'Activity',
                style: TextStyle(
                  color: color,
                  fontSize: context.theme.typography.sm.fontSize,
                ),
              ),
              Expanded(
                child: Center(
                  child: FaIcon(
                    widget.expanded ? PlotIcon.up : PlotIcon.down,
                    size: context.theme.typography.sm.fontSize,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
