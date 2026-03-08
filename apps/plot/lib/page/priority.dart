import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:logging/logging.dart';
import 'priorities.dart';
import 'loading.dart';

final _log = Logger('plot.page.priority');

enum PriorityTab { agenda, activityFeed }

class PriorityTabNotifier extends ValueNotifier<PriorityTab> {
  PriorityTabNotifier() : super(PriorityTab.agenda);
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
          child: ThreadHeaderNotifierProvider(
            child: BlocBuilder<LayoutBloc, LayoutState>(
              builder: (context, layoutState) {
                Widget body = Column(
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
                );

                return body;
              },
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

/// Provides global keyboard shortcuts for PriorityPage list navigation
/// that work even when focus is in ThreadPage (e.g., ThreadEditor).
/// - Cmd+T: Focus a thread in the agenda list
/// - Cmd+Shift+T: Focus a thread in the activity list
/// - Plain Up/Down: Navigate threads once focused
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
  InfiniteListController? _priorityListController;
  InfiniteListController? _priorityActivityFeedController;
  InfiniteListController? _activityListController;
  VoidCallback? _activityEditorFocusCallback;
  VoidCallback? _searchToggleCallback;
  bool _isSearchExpanded = false;

  void updateSearchExpanded(bool expanded) {
    if (_isSearchExpanded != expanded) {
      setState(() {
        _isSearchExpanded = expanded;
      });
    }
  }

  /// Closes search if it's open. Returns true if search was closed.
  bool tryCloseSearch() {
    if (_isSearchExpanded && _searchToggleCallback != null) {
      _searchToggleCallback!();
      return true;
    }
    return false;
  }

  void registerController(
    InfiniteListController controller, {
    InfiniteListController? activityFeedController,
  }) {
    _priorityListController = controller;
    _priorityActivityFeedController = activityFeedController;
  }

  /// Returns the controller for the list matching the user's current source.
  InfiniteListController? _resolveController(BuildContext context) {
    final priorityBloc = context.read<PriorityBloc>();
    final source = priorityBloc.resolveThreadListSource();
    if (source == ThreadListSource.activityFeed &&
        _priorityActivityFeedController != null) {
      return _priorityActivityFeedController;
    }
    return _priorityListController;
  }

  void registerSearchToggle(VoidCallback callback) {
    _searchToggleCallback = callback;
  }

  void unregisterSearchToggle() {
    _searchToggleCallback = null;
  }

  /// Moves focus to the next/previous thread item, skipping headers.
  /// When nothing is focused, starts from the currently opened thread
  /// (or lastFocusedIndex), falling back to the first thread item.
  void _moveFocusOrStart(
    InfiniteListController controller,
    int offset,
    BuildContext context,
  ) {
    final priorityBloc = context.read<PriorityBloc>();
    final source = priorityBloc.resolveThreadListSource();
    var items = source == ThreadListSource.agenda
        ? priorityBloc.state.agendaViewItems
        : priorityBloc.state.activityFeedItems;

    // On desktop, the "Now" header is stripped from the rendered agenda list
    // (replaced by a fixed panel header), so strip it here too to keep
    // indices in sync with the InfiniteListController.
    final layoutState = context.read<LayoutBloc>().state;
    if (source == ThreadListSource.agenda &&
        layoutState.multiPanel &&
        items.isNotEmpty &&
        items.first is AgendaHeaderItem &&
        (items.first as AgendaHeaderItem).now) {
      items = items.sublist(1);
    }

    // Determine current position
    int? current = controller.focusedIndex ?? controller.lastFocusedIndex;

    // If no prior focus, find the currently opened thread's index
    if (current == null) {
      final currentThread = priorityBloc.state.thread;
      if (currentThread != null) {
        for (int i = 0; i < items.length; i++) {
          if (items[i] is AgendaThreadItem &&
              (items[i] as AgendaThreadItem).thread.id == currentThread.id) {
            current = i;
            break;
          }
        }
      }
    }

    // If still nothing, find the first thread item
    if (current == null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem) {
          controller.requestFocus(i);
          return;
        }
      }
      return;
    }

    // Move in the given direction, skipping headers
    final direction = offset > 0 ? 1 : -1;
    int next = current + direction;
    while (next >= 0 && next < items.length) {
      if (items[next] is AgendaThreadItem) {
        controller.requestFocus(next);
        return;
      }
      next += direction;
    }

    // Already at boundary — stay on current if it's a thread
    if (current >= 0 &&
        current < items.length &&
        items[current] is AgendaThreadItem) {
      controller.requestFocus(current);
    }
  }

  /// Focuses the thread list for the given source (agenda or activity feed),
  /// switching the active list source and requesting focus on the appropriate item.
  void _focusListSource(BuildContext context, ThreadListSource targetSource) {
    final priorityBloc = context.read<PriorityBloc>();
    final controller = targetSource == ThreadListSource.activityFeed
        ? _priorityActivityFeedController
        : _priorityListController;
    if (controller == null) return;

    var items = targetSource == ThreadListSource.agenda
        ? priorityBloc.state.agendaViewItems
        : priorityBloc.state.activityFeedItems;

    // On desktop, the "Now" header is stripped from the rendered agenda list
    final layoutState = context.read<LayoutBloc>().state;
    if (targetSource == ThreadListSource.agenda &&
        layoutState.multiPanel &&
        items.isNotEmpty &&
        items.first is AgendaHeaderItem &&
        (items.first as AgendaHeaderItem).now) {
      items = items.sublist(1);
    }

    // Try to find the currently opened thread's index
    int? targetIndex;
    final currentThread = priorityBloc.state.thread;
    if (currentThread != null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem &&
            (items[i] as AgendaThreadItem).thread.id == currentThread.id) {
          targetIndex = i;
          break;
        }
      }
    }

    // Fall back to first thread item
    if (targetIndex == null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem) {
          targetIndex = i;
          break;
        }
      }
    }

    if (targetIndex == null) return;

    controller.requestFocus(targetIndex);
    priorityBloc.threadListSource = targetSource;
  }

  void registerActivityPanel({
    InfiniteListController? listController,
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
            // On mobile, wrap with PopScope to close search on back gesture.
            // canPop is false only when search is expanded, so normal
            // back navigation is unaffected when search is closed.
            // This must live here (not in the parent) because setState on
            // _isSearchExpanded triggers a rebuild of this widget.
            Widget child = Actions(
              actions: {
                MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                  onInvoke: (_) {
                    final controller = _resolveController(context);
                    if (controller != null) {
                      _moveFocusOrStart(controller, -1, context);
                    }
                    return null;
                  },
                ),
                MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                  onInvoke: (_) {
                    final controller = _resolveController(context);
                    if (controller != null) {
                      _moveFocusOrStart(controller, 1, context);
                    }
                    return null;
                  },
                ),
                ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                  onInvoke: (_) {
                    // When ThreadPage or NewThreadPage is open, Escape should focus ThreadEditor
                    _activityEditorFocusCallback?.call();
                    return null;
                  },
                ),
                ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(
                  onInvoke: (_) {
                    _searchToggleCallback?.call();
                    return null;
                  },
                ),
                FocusAgendaIntent: CallbackAction<FocusAgendaIntent>(
                  onInvoke: (_) {
                    _focusListSource(context, ThreadListSource.agenda);
                    return null;
                  },
                ),
                FocusActivityListIntent:
                    CallbackAction<FocusActivityListIntent>(
                      onInvoke: (_) {
                        _focusListSource(
                          context,
                          ThreadListSource.activityFeed,
                        );
                        return null;
                      },
                    ),
              },
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  platformSingleActivator(LogicalKeyboardKey.keyT):
                      const FocusAgendaIntent(),
                  platformSingleActivator(LogicalKeyboardKey.keyT, shift: true):
                      const FocusActivityListIntent(),
                  platformSingleActivator(LogicalKeyboardKey.slash):
                      const ToggleSearchIntent(),
                  // Global Escape handler - focus ThreadEditor when ThreadPage is open
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

            if (!layoutState.multiPanel) {
              child = PopScope(
                canPop: !_isSearchExpanded,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) tryCloseSearch();
                },
                child: child,
              );
            }

            return child;
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

/// InheritedWidget to provide access to ThreadPage panel state for focus coordination
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
        context.router.navigate(NewThreadRoute());
      }
    });
  }

  @override
  void didUpdateWidget(PriorityOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutState = context.read<LayoutBloc>().state;
    if (layoutState.middlePanelVisible) {
      context.router.navigate(NewThreadRoute());
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
                context.router.navigate(NewThreadRoute());
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

class _PriorityPageState extends State<PriorityPage> {
  PriorityTab _currentTab = PriorityTab.agenda;
  PriorityTabNotifier? _tabNotifier;
  bool _userSelectedAgenda = false;

  /// Fraction of usable height (totalHeight - dividerHeight) for the top list.
  /// 0.0 = collapsed minimum. Values are clamped to [_minFraction, 1.0] in layout.
  double _topFraction = 0.38;
  double _minFraction = 0.0; // cached from last layout
  final InfiniteListController _agendaListController = InfiniteListController();

  bool get _isCollapsed => _topFraction <= _minFraction + 0.005;

  @override
  void initState() {
    super.initState();
    _topFraction =
        ProfilePreferences.instance.getDouble('agenda_top_fraction') ?? 0.38;
  }

  void _onDividerDragStart() {}

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
    // Snap to collapsed if near minimum
    if (_topFraction < _minFraction + 0.02) {
      _topFraction = _minFraction;
    }
    ProfilePreferences.instance.setDouble('agenda_top_fraction', _topFraction);
    setState(() {});
  }

  void _onTabNotifierChanged() {
    if (_tabNotifier != null && _tabNotifier!.value != _currentTab) {
      setState(() {
        _currentTab = _tabNotifier!.value;
        if (_currentTab == PriorityTab.agenda) {
          _userSelectedAgenda = true;
        }
      });
    }
  }

  @override
  void didUpdateWidget(PriorityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.priorityId != widget.priorityId) {
      _userSelectedAgenda = false;
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
    _agendaListController.dispose();
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
                  // Auto-switch to activity tab when agenda is empty
                  // in single panel mode, unless user explicitly tapped Agenda.
                  // Require agendaItems.isNotEmpty to avoid switching before
                  // the agenda stream has emitted real data.
                  if (!layoutState.multiPanel &&
                      !_userSelectedAgenda &&
                      _currentTab == PriorityTab.agenda &&
                      state.agendaItems.isNotEmpty &&
                      state.agendaViewItems
                          .whereType<AgendaThreadItem>()
                          .isEmpty) {
                    _currentTab = PriorityTab.activityFeed;
                    // Sync tab notifier after build so the bottom bar updates
                    final notifier = _tabNotifier;
                    if (notifier != null &&
                        notifier.value != PriorityTab.activityFeed) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          notifier.value = PriorityTab.activityFeed;
                        }
                      });
                    }
                  }

                  // On desktop, use expansion state; on mobile, use tab state
                  final isUpNext = layoutState.multiPanel
                      ? !_isCollapsed
                      : _currentTab == PriorityTab.agenda;
                  var items = isUpNext
                      ? state.agendaViewItems
                      : state.activityFeedItems;

                  // Strip the leading "Now" header so reorder indices from
                  // InfiniteList align with moveAgendaItem's nowOffset logic.
                  // On desktop the header is replaced by a fixed panel header;
                  // on mobile it's redundant with the tab label.
                  if (isUpNext &&
                      items.isNotEmpty &&
                      items.first is AgendaHeaderItem &&
                      (items.first as AgendaHeaderItem).now) {
                    items = items.sublist(1);
                  }

                  // Build shortcuts map conditionally based on panel visibility
                  final shortcuts = <ShortcutActivator, Intent>{
                    const SingleActivator(LogicalKeyboardKey.enter):
                        const OpenFocusedItemActionsIntent(),
                    const SingleActivator(LogicalKeyboardKey.escape):
                        const ClearItemFocusIntent(),
                    // Plain Up/Down to navigate threads and handle focus transfer to ThreadPage
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                  };

                  // Get activity panel provider to check if ThreadPage is open
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
                        // Transfer focus to ThreadPage list
                        activityProvider!._activityListController!.moveFocus(
                          isPlainUp ? -1 : 1,
                        );
                        return KeyEventResult.handled;
                      }

                      // Let other keys (including Cmd-Up/Down) propagate to shortcuts
                      return KeyEventResult.ignored;
                    },
                    child: InfiniteListSelector(
                      onActivate: (index) {
                        final item = index >= 0 && index < items.length
                            ? items[index]
                            : null;
                        item?.when(
                          header: (header) => null,
                          activity: (agendaActivity) => context.run(
                            ChangeCurrentThread(agendaActivity.thread),
                          ),
                        );
                      },
                      builder: (context, listController) {
                        // For desktop, use expansion-based controller;
                        // for mobile, use list selector controller
                        final activeController = layoutState.multiPanel
                            ? (_isCollapsed
                                  ? listController
                                  : _agendaListController)
                            : listController;

                        // Register active controller with the global shortcuts provider.
                        // On desktop, also register the activity feed controller
                        // so Cmd-Up/Down can navigate whichever list the user
                        // was last interacting with.
                        final provider =
                            _PriorityListControllerProvider.maybeOf(context);
                        provider?.registerController(
                          activeController,
                          activityFeedController: layoutState.multiPanel
                              ? listController
                              : null,
                        );

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
                                      final controller =
                                          provider?._resolveController(
                                            context,
                                          ) ??
                                          activeController;
                                      provider?._moveFocusOrStart(
                                        controller,
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
                                      final controller =
                                          provider?._resolveController(
                                            context,
                                          ) ??
                                          activeController;
                                      provider?._moveFocusOrStart(
                                        controller,
                                        1,
                                        context,
                                      );
                                      return null;
                                    },
                                  ),
                              OpenFocusedItemActionsIntent:
                                  CallbackAction<OpenFocusedItemActionsIntent>(
                                    onInvoke: (_) {
                                      // Resolve the controller and items for
                                      // whichever list the user is interacting
                                      // with (agenda or activity feed).
                                      final resolvedController =
                                          provider?._resolveController(
                                            context,
                                          ) ??
                                          activeController;
                                      final priorityBloc = context
                                          .read<PriorityBloc>();
                                      final source = priorityBloc
                                          .resolveThreadListSource();
                                      final resolvedItems =
                                          source == ThreadListSource.agenda
                                          ? items
                                          : state.activityFeedItems;
                                      final focusedIndex =
                                          resolvedController.focusedIndex;
                                      if (focusedIndex != null &&
                                          focusedIndex >= 0 &&
                                          focusedIndex < resolvedItems.length) {
                                        context.run(
                                          OpenFocusedItemActions(
                                            resolvedController,
                                            (index) async {
                                              final item =
                                                  index >= 0 &&
                                                      index <
                                                          resolvedItems.length
                                                  ? resolvedItems[index]
                                                  : null;
                                              if (item == null) {
                                                return <StaticCommandGroup>[];
                                              }
                                              return await item.when<
                                                Future<List<StaticCommandGroup>>
                                              >(
                                                activity: (agendaActivity) =>
                                                    threadCommandGroups(
                                                      agendaActivity.thread,
                                                    ),
                                                header: (_) async =>
                                                    <StaticCommandGroup>[],
                                              );
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
                                      // Clear the resolved controller (may differ
                                      // from activeController when navigating the
                                      // activity feed on desktop)
                                      final controller =
                                          provider?._resolveController(
                                            context,
                                          ) ??
                                          activeController;
                                      controller.clearFocus();
                                      if (controller != activeController) {
                                        activeController.clearFocus();
                                      }
                                      // When ThreadPage is open, also focus ThreadEditor
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
                                          threadCommandGroupsSync(
                                            agendaActivity.thread,
                                          ),
                                      header: (_) =>
                                          <StaticCommandGroup>[],
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
                                    : isUpNext
                                    ? ThreadListSourceProvider(
                                        source: ThreadListSource.agenda,
                                        child: _buildList(
                                          context,
                                          state,
                                          items,
                                          listController,
                                          ScrollControllerContext.of(context),
                                          enableReorder: true,
                                          doneEnd: state.doneEnd,
                                          scrollStorageKey: PageStorageKey(
                                            'priority_agenda_${widget.priorityId}',
                                          ),
                                        ),
                                      )
                                    : ThreadListSourceProvider(
                                        source: ThreadListSource.activityFeed,
                                        child: _buildActivityFeed(
                                          context,
                                          state,
                                          items,
                                          listController,
                                          ScrollControllerContext.of(context),
                                          scrollStorageKey: PageStorageKey(
                                            'priority_feed_${widget.priorityId}',
                                          ),
                                        ),
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
    InfiniteListController activityController,
  ) {
    final isSearching = state.search.isNotEmpty || state.filter.isNotEmpty;

    // When searching, show only the activity feed at full height
    if (isSearching) {
      return ThreadListSourceProvider(
        source: ThreadListSource.activityFeed,
        child: _buildActivityFeed(
          context,
          state,
          state.activityFeedItems,
          activityController,
          ScrollControllerContext.of(context),
        ),
      );
    }

    // Filter out the inline "Now" header — it's replaced by a fixed panel header.
    final allAgendaItems = state.agendaViewItems;
    final agendaItems =
        allAgendaItems.isNotEmpty &&
            allAgendaItems.first is AgendaHeaderItem &&
            (allAgendaItems.first as AgendaHeaderItem).now
        ? allAgendaItems.sublist(1)
        : allAgendaItems;
    final activityFeedItems = state.activityFeedItems;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        const dividerHeight = 22.0;
        const nowHeaderHeight = 22.0;

        // Check if the first activity has a label (sub-priority or event
        // timing), which makes the item taller.
        final firstActivity = agendaItems
            .whereType<AgendaThreadItem>()
            .firstOrNull;
        final hasSubPriorityLabel =
            firstActivity != null &&
            firstActivity.thread.priority.id != state.context.id;
        final double subPriorityExtra;
        if (hasSubPriorityLabel) {
          final xsFontSize = context.theme.typography.xs.fontSize ?? 12.0;
          final xsLineHeight = context.theme.typography.xs.height ?? 1.2;
          subPriorityExtra = xsFontSize * xsLineHeight + 2.0;
        } else {
          subPriorityExtra = 0.0;
        }
        final collapsedTopHeight = 66.0 + subPriorityExtra;

        final usableHeight = totalHeight - dividerHeight - nowHeaderHeight;

        // Cache minFraction so _isCollapsed works outside layout
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
            FAnimatedTheme(
              data: darkenTheme(
                context,
                context.theme,
                context.colour,
                steps: 2,
              ),
              child: SizedBox(
                height: nowHeaderHeight,
                child: const _PanelHeader(text: 'Now'),
              ),
            ),
            SizedBox(
              height: topHeight,
              child: ClipRect(
                child: ThreadListSourceProvider(
                  source: ThreadListSource.agenda,
                  child: isCollapsed
                      ? _buildCollapsedAgenda(context, state, agendaItems)
                      : _buildList(
                          context,
                          state,
                          agendaItems,
                          _agendaListController,
                          null,
                          enableReorder: true,
                          doneEnd: state.doneEnd,
                        ),
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
                  onDragStart: _onDividerDragStart,
                  onDragUpdate: (dy) => _onDividerDragUpdate(dy, usableHeight),
                  onDragEnd: _onDividerDragEnd,
                ),
              ),
            ),
            SizedBox(
              height: bottomHeight,
              child: ClipRect(
                child: ThreadListSourceProvider(
                  source: ThreadListSource.activityFeed,
                  child: _buildActivityFeed(
                    context,
                    state,
                    activityFeedItems,
                    activityController,
                    ScrollControllerContext.of(context),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Builds a non-scrollable preview of the Agenda list when collapsed,
  /// showing only the first header and first activity item.
  Widget _buildCollapsedAgenda(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
  ) {
    // Take up to 2 items: the header + first activity
    final previewItems = items.take(2).toList();
    final hasActivity = previewItems.any((item) => item is AgendaThreadItem);
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final item in previewItems)
          item.when(
            header: (header) => AgendaHeader(
              priorityContext: state.context,
              dateTimeRange: header.dateTimeRange,
              date: header.date,
              now: header.now,
              thread: header.thread,
              text: header.text,
              scheduleAt: header.scheduleAt,
            ),
            activity: (agendaActivity) => ThreadWidget(
              activity: agendaActivity.thread,
              selected:
                  state.thread != null &&
                  agendaActivity.thread.id == state.thread!.id,
              now: agendaActivity.now,
              context: state.context,
              showSubPriority: true,
              showEventTiming: true,
            ),
          ),
        if (!hasActivity) _buildAgendaEmpty(context),
      ],
    );
  }

  Widget _buildAgendaEmpty(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Use ',
            style: TextStyle(
              color: context.theme.colors.mutedForeground,
              fontSize: context.theme.typography.sm.fontSize,
            ),
          ),
          FaIcon(
            PlotIcon.addTodo,
            size: context.theme.typography.sm.fontSize,
            color: context.theme.colors.mutedForeground,
          ),
          Text(
            ' to add threads that require action',
            style: TextStyle(
              color: context.theme.colors.mutedForeground,
              fontSize: context.theme.typography.sm.fontSize,
            ),
          ),
        ],
      ),
    );
  }

  /// Always 1px tall for stable layout. Default renders as 0.5px border +
  /// 0.5px background (thin). Active states fill the full 1px (bolder, and
  /// immune to sub-pixel anti-aliasing that dims the top border).
  Widget _buildSeparator(
    BuildContext context,
    List<AgendaItem> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final borderColor = context.theme.colors.border;
    final bg = context.colour.background;
    final AgendaItem? prev = index > 0 ? listItems[index - 1] : null;
    final AgendaItem? next =
        index < listItems.length ? listItems[index] : null;

    final selectedId = state.thread?.id;
    final hovered = controller.hoveredIndex;
    final focused = controller.focusedIndex;

    // Selected: full 1px tinted border
    final baseBorder = Color.alphaBlend(borderColor, bg);
    if (prev is AgendaThreadItem && prev.thread.id == selectedId) {
      final accent = context.colour.colours
          .fromTheme(prev.thread.priority.displayColor)
          .withValues(alpha: 0.3);
      return Container(height: 1, color: Color.alphaBlend(accent, baseBorder));
    }
    if (next is AgendaThreadItem && next.thread.id == selectedId) {
      final accent = context.colour.colours
          .fromTheme(next.thread.priority.displayColor)
          .withValues(alpha: 0.3);
      return Container(height: 1, color: Color.alphaBlend(accent, baseBorder));
    }

    // Hover/focus (threads only): full 1px bright border
    // Skip bright style if adjacent item is being dragged
    final dragging = controller.draggingIndex;
    final prevHighlighted =
        prev is AgendaThreadItem &&
        (hovered == index - 1 || focused == index - 1) &&
        dragging != index - 1;
    final nextHighlighted =
        next is AgendaThreadItem &&
        (hovered == index || focused == index) &&
        dragging != index;
    if (prevHighlighted || nextHighlighted) {
      final bright = borderColor.withValues(
        alpha: (borderColor.a * 2).clamp(0.0, 1.0),
      );
      return Container(height: 1, color: Color.alphaBlend(bright, bg));
    }

    // Default: transparent for first item (avoids double border with header),
    // otherwise the standard border color.
    return Container(height: 1, color: prev == null ? bg : baseBorder);
  }

  Widget _buildList(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    required bool enableReorder,
    required bool doneEnd,
    PageStorageKey<String>? scrollStorageKey,
  }) {
    final listItems = items;

    final hasThreads = listItems.any((item) => item is AgendaThreadItem);
    final showEmptyHint = !hasThreads;

    final list = InfiniteList(
      controller: controller,
      scrollController: scrollController,
      scrollStorageKey: scrollStorageKey,
      count: listItems.length,
      doneEnd: doneEnd,
      itemKey: (index) {
        if (index < 0 || index >= listItems.length) return 'empty_$index';
        return listItems[index].stableKey;
      },
      nonReorderablePrefixCount:
          enableReorder &&
              listItems.isNotEmpty &&
              listItems.first is AgendaHeaderItem
          ? 1
          : 0,
      fetcher: (first, count) =>
          context.read<PriorityBloc>().fetchMoreAgendaItems(first, count),
      separatorBuilder: (context, index) =>
          _buildSeparator(context, listItems, index, state, controller),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= listItems.length) {
          return null;
        }
        final current = listItems[index];

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(current.stableKey),
          children: [
            ...current.when(
              header: (header) {
                return [
                  if (showEmptyHint && index == 0) ...[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.contentPaddingH,
                        vertical: context.theme.spacing.xl,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Threads you mark ',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                          FaIcon(
                            PlotIcon.addTodo,
                            size: context.theme.typography.sm.fontSize,
                            color: context.theme.plotColors.veryMuted,
                          ),
                          Text(
                            ' to do or ',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                          FaIcon(
                            PlotIcon.schedule,
                            size: context.theme.typography.sm.fontSize,
                            color: context.theme.plotColors.veryMuted,
                          ),
                          Text(
                            ' schedule will appear here.',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(height: 1, color: context.theme.colors.border),
                  ],
                  AgendaHeader(
                    key: ValueKey(
                      header.date != null
                          ? 'agendaheader_date_${header.date}'
                          : header.dateTimeRange != null
                          ? 'agendaheader_event_${header.dateTimeRange}'
                          : 'agendaheader_other',
                    ),
                    priorityContext: state.context,
                    dateTimeRange: header.dateTimeRange,
                    date: header.date,
                    now: header.now,
                    thread: header.thread,
                    focusNode: focusNode,
                    text: header.text,
                    scheduleAt: header.scheduleAt,
                  ),
                ];
              },
              activity: (agendaActivity) {
                return [
                  ThreadWidget(
                    key: ValueKey(
                      'activitywidget_${agendaActivity.thread.id}${agendaActivity.thread.occurrence != null ? '_${agendaActivity.thread.occurrence}' : ''}${agendaActivity.thread.isLinkScheduleInstance ? '_link' : ''}',
                    ),
                    activity: agendaActivity.thread,
                    selected:
                        state.thread != null &&
                        agendaActivity.thread.id == state.thread!.id,
                    now: agendaActivity.now,
                    focusNode: focusNode,
                    context: state.context,
                    showSubPriority: true,
                    showEventTiming: true,
                    reorderableIndex:
                        enableReorder &&
                            !agendaActivity.thread.isLinkScheduleInstance
                        ? reorderableIndex
                        : null,
                  ),
                ];
              },
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
              final activity = item.when<Thread?>(
                header: (header) => null,
                activity: (agendaActivity) => agendaActivity.thread,
              );
              if (activity?.todo != true ||
                  activity == null ||
                  activity.isLinkScheduleInstance) {
                return null;
              }
              return (int newIndex) {
                final oldListIndex = index;
                var newListIndex = newIndex;

                // Build list of todo items with their indices (excluding
                // the dragged item) so we can find the correct neighbors.
                // Stop at the first date header past both old and new
                // positions so items from later sections don't pollute
                // the order calculation.
                final dropBound = oldListIndex > newListIndex
                    ? oldListIndex
                    : newListIndex;
                final todoItems = <(int, Thread)>[];
                for (var i = 0; i < listItems.length; i++) {
                  if (i == oldListIndex) continue;
                  final li = listItems[i];
                  if (li is AgendaHeaderItem &&
                      li.date != null &&
                      i > dropBound) {
                    break;
                  }
                  final t = li.when<Thread?>(
                    header: (_) => null,
                    activity: (a) => a.thread,
                  );
                  if (t != null && t.todo) {
                    todoItems.add((i, t));
                  }
                }

                // Find the target section's date-header boundaries in the
                // original (pre-removal) list so prevTodo/nextTodo stay
                // within the same day.
                var sectionStartIdx = 0;
                var sectionEndIdx = listItems.length;
                {
                  final scanRef = oldListIndex < newListIndex
                      ? newListIndex
                      : newListIndex - 1;
                  for (var i = scanRef; i >= 0; i--) {
                    if (i == oldListIndex) continue;
                    final li = listItems[i];
                    if (li is AgendaHeaderItem && li.date != null) {
                      sectionStartIdx = i;
                      break;
                    }
                  }
                  for (var i = scanRef + 1; i < listItems.length; i++) {
                    if (i == oldListIndex) continue;
                    final li = listItems[i];
                    if (li is AgendaHeaderItem && li.date != null) {
                      sectionEndIdx = i;
                      break;
                    }
                  }
                }

                // Find the insertion point among todos. The dragged item
                // should be inserted at the position corresponding to
                // newListIndex, but only relative to other todo items
                // within the same section.
                Thread? prevTodo;
                Thread? nextTodo;
                for (var i = 0; i < todoItems.length; i++) {
                  final (todoIdx, todo) = todoItems[i];
                  if (todoIdx < sectionStartIdx || todoIdx >= sectionEndIdx) {
                    if (todoIdx >= sectionEndIdx) break;
                    continue;
                  }
                  // Adjust for the removed item when comparing positions
                  final adjustedIdx = oldListIndex < todoIdx
                      ? todoIdx - 1
                      : todoIdx;
                  if (adjustedIdx < newListIndex) {
                    prevTodo = todo;
                  } else {
                    nextTodo = todo;
                    break;
                  }
                }

                final newOrder = Order.between(
                  prevTodo?.order,
                  nextTodo?.order,
                );

                // Determine target day and event from drop position.
                // newListIndex is in post-removal coordinates, but
                // listItems is pre-removal. When dragging down,
                // indices after oldListIndex shift by 1, so adjust
                // the scan start back to original-list coordinates.
                Date? targetDate;
                Thread? targetEvent;
                final scanStart = oldListIndex < newListIndex
                    ? newListIndex // +1 for pre-removal, -1 for "before"
                    : newListIndex - 1;
                DateTime? nearestGapStart;
                var passedGap = false;
                for (var i = scanStart; i >= 0; i--) {
                  if (i == oldListIndex) continue;
                  final item = listItems[i];
                  if (item is AgendaHeaderItem) {
                    // Track gap headers to distinguish "after event"
                    // from "in gap" — they use different pin times.
                    if (item.dateTimeRange != null &&
                        item.date == null &&
                        item.text == null &&
                        targetEvent == null) {
                      passedGap = true;
                      nearestGapStart ??= item.dateTimeRange!.start;
                    }
                    if (item.date != null) {
                      targetDate = item.date;
                      break;
                    }
                  } else if (item is AgendaThreadItem) {
                    // Detect scheduled events (link schedule instances
                    // with an end time) — event headers are stripped by
                    // agendaViewItems, so we detect from threads directly.
                    if (targetEvent == null &&
                        item.thread.isLinkScheduleInstance &&
                        item.thread.at?.end != null) {
                      targetEvent = item.thread;
                    }
                  }
                }
                // If no date header found, target is "Now" (null date).

                final currentDate =
                    activity.on?.start ?? activity.at?.start?.toDate();
                final dateChanged = targetDate != currentDate;
                final wasPinned = activity.isPinnedTodo;
                // Pin time: gap start when dropped into a gap (passedGap),
                // event start when dropped right after an event.
                final DateTime? pinTime;
                if (passedGap && nearestGapStart != null) {
                  pinTime = nearestGapStart;
                } else if (!passedGap && targetEvent?.at?.start != null) {
                  pinTime = targetEvent!.at!.start!;
                } else {
                  pinTime = null;
                }
                final pinningToEvent = pinTime != null;

                // Skip if nothing changed
                if (newOrder.value == activity.order.value &&
                    !dateChanged &&
                    !pinningToEvent &&
                    !wasPinned) {
                  _log.info(
                    '[onReorder] "${activity.title}" '
                    'order unchanged (${newOrder.value}), skipping',
                  );
                  return;
                }

                _log.info(
                  '[onReorder] "${activity.title}" '
                  'old=$oldListIndex -> new=$newListIndex '
                  'prevTodo="${prevTodo?.title}" (${prevTodo?.order.value}) '
                  'nextTodo="${nextTodo?.title}" (${nextTodo?.order.value}) '
                  '-> newOrder=${newOrder.value} '
                  'todo=${activity.todo} '
                  'hasUserSched=${activity.hasUserSchedule}'
                  '${dateChanged ? ' dateChange=$currentDate->$targetDate' : ''}'
                  '${pinningToEvent ? ' pinTime=$pinTime gap=$passedGap nearestGap=$nearestGapStart event="${targetEvent?.title}"' : ''}'
                  '${wasPinned && !pinningToEvent ? ' unpinning' : ''}',
                );

                final Thread updatedActivity;
                bool needsFullSave = false;

                if (pinningToEvent) {
                  if (!passedGap && targetEvent != null) {
                    // Dropped right after a scheduled event —
                    // check priority relationship
                    final eventPriority = targetEvent.priority;
                    if (activity.priority.isParent(eventPriority)) {
                      // Ancestor → adopt event's priority, pin after event
                      updatedActivity = activity
                          .copyWith(priority: eventPriority)
                          .reorderToAfterEvent(newOrder, eventEndTime: pinTime);
                      needsFullSave = true;
                    } else if (eventPriority.id == activity.priority.id ||
                        eventPriority.isParent(activity.priority)) {
                      // Same or descendant → pin after event
                      updatedActivity = activity.reorderToAfterEvent(
                        newOrder,
                        eventEndTime: pinTime,
                      );
                    } else {
                      // Unrelated → move to gap after the event
                      updatedActivity = activity.reorderToAfterEvent(
                        newOrder,
                        eventEndTime: targetEvent.at!.end!,
                      );
                    }
                  } else {
                    // Dropped in a gap → pin to gap start
                    updatedActivity = activity.reorderToAfterEvent(
                      newOrder,
                      eventEndTime: pinTime,
                    );
                  }
                } else if (dateChanged || wasPinned) {
                  // Date changed or unpinning a previously pinned todo
                  updatedActivity = activity.reorderTo(
                    newOrder,
                    date: targetDate,
                  );
                } else {
                  updatedActivity = activity.reorder(newOrder);
                }

                // Optimistic update: cache moved agendaViewItems so the
                // UI doesn't re-derive them (which can produce different
                // item counts and cause visual jank).
                final nowFlag = item.when(
                  header: (_) => false,
                  activity: (a) => a.now,
                );
                context.read<PriorityBloc>().moveAgendaItem(
                  oldListIndex,
                  newListIndex,
                  updatedItem: AgendaThreadItem(updatedActivity, now: nowFlag),
                );

                // Persist the reordered schedule (and priority change) to database
                if (needsFullSave) {
                  updatedActivity.save();
                } else {
                  updatedActivity.saveOrder();
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _log.info(
                    '[onReorder] post-frame: reorderViewItems=${context.read<PriorityBloc>().state.reorderViewItems != null}',
                  );
                });
              };
            }
          : null,
    );

    return list;
  }

  Widget _buildActivityFeed(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    PageStorageKey<String>? scrollStorageKey,
  }) {
    if (items.isEmpty && state.activityFeedDoneEnd) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.contentPaddingH,
          vertical: context.theme.spacing.xl,
        ),
        child: Text(
          'Threads track your specific goals and activities, with tasks, notes, and linked documents in one place.\nCreate a thread or add a connection to add threads here.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.plotColors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    return InfiniteList(
      controller: controller,
      scrollController: scrollController,
      scrollStorageKey: scrollStorageKey,
      count: items.length,
      doneEnd: state.activityFeedDoneEnd,
      fetcher: (first, count) =>
          context.read<PriorityBloc>().fetchMoreActivityFeedItems(first, count),
      separatorBuilder: (context, index) =>
          _buildSeparator(context, items, index, state, controller),
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
              activity: (a) => 'feed_activity_${a.thread.id}',
            ),
          ),
          children: [
            ...current.when(
              header: (header) {
                return [
                  AgendaHeader(
                    priorityContext: state.context,
                    dateTimeRange: header.dateTimeRange,
                    date: header.date,
                    now: header.now,
                    thread: header.thread,
                    focusNode: focusNode,
                    text: header.text,
                    scheduleAt: header.scheduleAt,
                  ),
                ];
              },
              activity: (agendaActivity) {
                return [
                  ThreadWidget(
                    key: ValueKey(
                      'feed_activitywidget_${agendaActivity.thread.id}',
                    ),
                    activity: agendaActivity.thread,
                    selected:
                        state.thread != null &&
                        agendaActivity.thread.id == state.thread!.id,
                    now: agendaActivity.now,
                    focusNode: focusNode,
                    context: state.context,
                    showSubPriority: true,
                    bump: false,
                  ),
                ];
              },
            ),
          ],
        );
      },
    );
  }
}

class _SplitViewDivider extends StatefulWidget {
  const _SplitViewDivider({
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });
  final VoidCallback? onDragStart;
  final void Function(double dy)? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  State<_SplitViewDivider> createState() => _SplitViewDividerState();
}

class _SplitViewDividerState extends State<_SplitViewDivider> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragging;
    final accentColor = context.colour.accent;
    final borderColor = active ? accentColor : context.theme.colors.border;
    final textColor = active
        ? accentColor
        : context.theme.colors.foreground;

    return GestureDetector(
      onVerticalDragStart: widget.onDragStart != null
          ? (_) {
              setState(() => _dragging = true);
              widget.onDragStart!();
            }
          : null,
      onVerticalDragUpdate: widget.onDragUpdate != null
          ? (details) => widget.onDragUpdate!(details.delta.dy)
          : null,
      onVerticalDragEnd: widget.onDragEnd != null
          ? (_) {
              setState(() => _dragging = false);
              widget.onDragEnd!();
            }
          : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            color: context.theme.colors.background,
            border: Border.symmetric(
              horizontal: BorderSide(color: borderColor),
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: context.contentPaddingH,
            vertical: context.theme.spacing.xs,
          ),
          child: Row(
            children: [
              const Spacer(),
              FaIcon(
                FontAwesomeIcons.gripDots,
                size: context.theme.typography.xs.fontSize,
                color: context.theme.plotColors.veryMuted,
              ),
              const Spacer(),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeInOut,
                style: TextStyle(
                  color: textColor,
                  fontSize: context.theme.typography.xs.fontSize,
                ),
                child: const Text('Activity'),
              ),
              const Spacer(),
              FaIcon(
                FontAwesomeIcons.gripDots,
                size: context.theme.typography.xs.fontSize,
                color: context.theme.plotColors.veryMuted,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.theme.colors.background,
        border: Border(bottom: BorderSide(color: context.theme.colors.border)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.xs,
      ),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: context.theme.colors.foreground,
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
      ),
    );
  }
}
