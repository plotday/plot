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

    // Switch desktop/mobile tab to match the focused source
    final tabNotifier = PriorityTabProvider.maybeOf(context);
    if (tabNotifier != null) {
      final targetTab = targetSource == ThreadListSource.agenda
          ? PriorityTab.agenda
          : PriorityTab.activityFeed;
      if (tabNotifier.value != targetTab) {
        tabNotifier.value = targetTab;
      }
    }
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
  final InfiniteListController _agendaListController = InfiniteListController();

  void _onTabNotifierChanged() {
    if (_tabNotifier != null && _tabNotifier!.value != _currentTab) {
      setState(() {
        _currentTab = _tabNotifier!.value;
      });
    }
  }

  @override
  void didUpdateWidget(PriorityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
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
        return BlocBuilder<LayoutBloc, LayoutState>(
                builder: (context, layoutState) {
                  final isUpNext = _currentTab == PriorityTab.agenda;
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
                        final activeController = layoutState.multiPanel && _currentTab == PriorityTab.agenda
                            ? _agendaListController
                            : listController;

                        final provider =
                            _PriorityListControllerProvider.maybeOf(context);
                        provider?.registerController(
                          layoutState.multiPanel ? _agendaListController : activeController,
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
                                      header: (_) => <StaticCommandGroup>[],
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
                                          enableReorder:
                                              !state.context.isViewer,
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

    // Strip the leading "Now" header for the agenda tab
    final allAgendaItems = state.agendaViewItems;
    final agendaItems =
        allAgendaItems.isNotEmpty &&
            allAgendaItems.first is AgendaHeaderItem &&
            (allAgendaItems.first as AgendaHeaderItem).now
        ? allAgendaItems.sublist(1)
        : allAgendaItems;

    final isNowTab = _currentTab == PriorityTab.agenda;

    return Column(
      children: [
        _DesktopTabBar(
          currentTab: _currentTab,
          onTabChanged: _onDesktopTabChanged,
          hasUnreadActivity: state.activityFeedItems.any((item) => item.when(
            activity: (a) => a.thread.unread,
            header: (_) => false,
          )),
          priority: state.context,
        ),
        Expanded(
          child: isNowTab
              ? ThreadListSourceProvider(
                  source: ThreadListSource.agenda,
                  child: _buildList(
                    context,
                    state,
                    agendaItems,
                    _agendaListController,
                    null,
                    enableReorder: !state.context.isViewer,
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
                    state.activityFeedItems,
                    activityController,
                    ScrollControllerContext.of(context),
                    scrollStorageKey: PageStorageKey(
                      'priority_feed_${widget.priorityId}',
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  void _onDesktopTabChanged(PriorityTab tab) {
    setState(() {
      _currentTab = tab;
    });
    if (_tabNotifier != null && _tabNotifier!.value != tab) {
      _tabNotifier!.value = tab;
    }
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
    final AgendaItem? next = index < listItems.length ? listItems[index] : null;

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
              listItems.first is AgendaHeaderItem &&
              (listItems.first as AgendaHeaderItem).date == null
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
                final isBeingDragged = controller.draggingIndex == index;
                return [
                  ThreadWidget(
                    key: ValueKey(
                      'activitywidget_${agendaActivity.thread.id}${agendaActivity.thread.occurrence != null ? '_${agendaActivity.thread.occurrence}' : ''}${agendaActivity.thread.isLinkScheduleInstance ? '_link' : ''}',
                    ),
                    activity: agendaActivity.thread,
                    selected:
                        !isBeingDragged &&
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

class _DesktopTabBar extends StatelessWidget {
  const _DesktopTabBar({
    required this.currentTab,
    required this.onTabChanged,
    required this.priority,
    this.hasUnreadActivity = false,
  });

  final PriorityTab currentTab;
  final ValueChanged<PriorityTab> onTabChanged;
  final Priority priority;
  final bool hasUnreadActivity;

  @override
  Widget build(BuildContext context) {
    final borderSide = BorderSide(color: context.theme.colors.border);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: borderSide),
      ),
      position: DecorationPosition.foreground,
      child: Row(
        children: [
          _DesktopTab(
            label: 'Now',
            selected: currentTab == PriorityTab.agenda,
            border: Border(right: borderSide),
            onTap: () => onTabChanged(PriorityTab.agenda),
          ),
          _DesktopTab(
            label: 'Activity',
            selected: currentTab == PriorityTab.activityFeed,
            onTap: () => onTabChanged(PriorityTab.activityFeed),
            showUnreadDot: hasUnreadActivity,
            trailing: _NotificationButton(
              onTap: () => context.run(ShowAttentionSettings(priority)),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTab extends StatefulWidget {
  const _DesktopTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.border,
    this.showUnreadDot = false,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Border? border;
  final bool showUnreadDot;
  final Widget? trailing;

  @override
  State<_DesktopTab> createState() => _DesktopTabState();
}

class _DesktopTabState extends State<_DesktopTab> {
  bool _hovered = false;

  static const _dotSize = 6.0;
  static const _dotSpacing = 4.0;

  Widget _unreadDot(Color color, {required bool visible}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _dotSpacing),
      child: SizedBox(
        width: _dotSize,
        height: _dotSize,
        child: visible
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final darkBg = darkenTheme(context, theme, context.colour, steps: 2)
        .colors
        .background;

    final Color background;
    if (widget.selected) {
      background = theme.colors.background;
    } else if (_hovered) {
      background = theme.colors.secondary;
    } else {
      background = darkBg;
    }

    final textColor = widget.selected
        ? context.colour.accent
        : theme.colors.mutedForeground;

    return Expanded(
      child: GestureDetector(
        onTap: widget.selected ? null : widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            decoration: BoxDecoration(
              color: background,
              border: widget.border,
            ),
            padding: EdgeInsets.symmetric(
              vertical: theme.spacing.xs,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _unreadDot(textColor, visible: widget.showUnreadDot),
                    Text(
                      widget.label,
                      style: theme.typography.sm.copyWith(
                        fontFamily: theme.typography.defaultFontFamily,
                        color: textColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    _unreadDot(textColor, visible: false),
                  ],
                ),
                if (widget.trailing != null)
                  Positioned(
                    right: 0,
                    child: widget.trailing!,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationButton extends StatefulWidget {
  const _NotificationButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NotificationButton> createState() => _NotificationButtonState();
}

class _NotificationButtonState extends State<_NotificationButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Icon(
            PlotIcon.notification,
            size: 14,
            color: _hovered
                ? context.theme.colors.foreground
                : context.theme.plotColors.veryMuted,
          ),
        ),
      ),
    );
  }
}
