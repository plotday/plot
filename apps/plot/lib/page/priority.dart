import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_feed_drag.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/block_list_separator.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/agenda.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';

import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'priorities.dart';
import 'loading.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required this.priorityIdString})
    : priorityId = PriorityId.tryFromShortString(priorityIdString);

  final String priorityIdString;
  final PriorityId? priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    final priorityId = this.priorityId;
    if (priorityId == null) {
      // Invalid base58 priority id (e.g. /p/login from a stale or
      // malformed link). Redirect to the user's default landing instead
      // of crashing in the parser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replaceAll([const RootRoute()]);
      });
      return const SizedBox.shrink();
    }
    // Wrap the subtree in a StatefulWidget so the inner AutoRouter's
    // GlobalKey lives on State and survives `wrappedRoute` rebuilds. That
    // way switching priorities flips this widget's `priorityId` prop
    // through `didUpdateWidget` instead of remounting the whole tree.
    return _PriorityWrapperHost(
      priorityIdString: priorityIdString,
      priorityId: priorityId,
    );
  }
}

class _PriorityWrapperHost extends StatefulWidget {
  const _PriorityWrapperHost({
    required this.priorityIdString,
    required this.priorityId,
  });

  final String priorityIdString;
  final PriorityId priorityId;

  @override
  State<_PriorityWrapperHost> createState() => _PriorityWrapperHostState();
}

class _PriorityWrapperHostState extends State<_PriorityWrapperHost> {
  // Stable across priority switches — the whole point of this host. Reusing
  // the same key means the inner AutoRouter's Element survives, which
  // means its Navigator stack, NewThreadPage/ThreadPage State, and (one
  // level up) ResizablePanelLayout's FResizableController all persist.
  final GlobalKey _routerKey = GlobalKey(
    debugLabel: 'PriorityWrapper_innerRouter',
  );

  @override
  void didUpdateWidget(_PriorityWrapperHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.priorityIdString == oldWidget.priorityIdString) return;

    // The wrapper's priority just changed (e.g. user clicked B in the
    // sidebar). Force the inner stack to the canonical landing for B
    // (NewThreadRoute in multi-panel, PriorityOnlyRoute in single-panel).
    //
    // This is needed for TWO reasons:
    //
    //  1. The inner navigator may still hold a ThreadRoute from the
    //     previous priority — that thread doesn't belong to the new
    //     priority's feed and showing it would be incoherent.
    //  2. auto_route's in-place params update on PriorityRoute (A → B)
    //     disposes the existing inner route widget (PriorityOnlyRoute(A)
    //     or NewThreadRoute(A)) but fails to mount a new one, leaving
    //     the inner AutoRouter with an empty stack. The AutoRouter then
    //     falls back to its `LoadingPage` placeholder — a forever
    //     spinner where the new priority's feed should be. Explicitly
    //     replacing the inner stack here forces a fresh mount.
    //
    // Skip the reset when the URL explicitly wants a thread (deep links
    // like /t/:id or /p/B/:threadId resolve with ThreadRoute in the
    // segment tree; AutoRoute will route the inner stack there
    // automatically and we must not stomp on it).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final innerRouter = _findInnerRouter();
      if (innerRouter == null) return;

      final segments = context.router.root.urlState.segments;
      if (_segmentsContainThread(segments)) return;

      final multi = context.read<LayoutBloc>().state.multiPanel;
      innerRouter.replaceAll([
        multi ? NewThreadRoute() : PriorityOnlyRoute(),
      ]);
    });
  }

  StackRouter? _findInnerRouter() {
    StackRouter? walk(RoutingController controller) {
      final direct = controller.innerRouterOf<StackRouter>(
        PriorityRoute.name,
      );
      if (direct != null) return direct;
      for (final child in controller.childControllers) {
        final hit = walk(child);
        if (hit != null) return hit;
      }
      return null;
    }
    return walk(context.router.root);
  }

  static bool _segmentsContainThread(List<RouteMatch<dynamic>> segments) {
    for (final segment in segments) {
      if (segment.name == ThreadRoute.name) return true;
      if (segment.hasChildren &&
          _segmentsContainThread(segment.children!)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => _build(context, widget.priorityId);

  Widget _build(BuildContext context, PriorityId priorityId) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      child: _PriorityCommandScope(
        child: _PriorityShortcutsProvider(
          priorityId: priorityId,
          child: ThreadHeaderNotifierProvider(
            child: BlocBuilder<LayoutBloc, LayoutState>(
              builder: (context, layoutState) {
                // In single-panel mode UnifiedHeader sits above the panel
                // layout. In multi-panel mode the panel layout splits the
                // window into A (sidebar header + agenda + priorities) and
                // B (main header + shared squircle containing middle +
                // right). The outer A|B divider runs top-to-bottom; the
                // inner middle|right divider stays inside the squircle.
                final panelLayout = ResizablePanelLayout(
                  leftTop: const LeftPanelAgendaView(),
                  left: PrioritiesPanelContent(),
                  middle: PriorityPage(priorityId: priorityId),
                  child: BlocSelector<PriorityBloc, PriorityState, int>(
                    selector: (state) =>
                        (state.thread?.priority.displayColor ??
                                state.draft.priority.displayColor)
                            .index,
                    builder: (context, threadColorIndex) {
                      final threadColor = ThemeColor(threadColorIndex);
                      final brightness = context.colour.brightness;
                      return ProxyProvider0<ColourSchemeData>(
                        update: (_, _) => ColourSchemeData(
                          themeColor: threadColor,
                          brightness: brightness,
                        ),
                        child: AutoRouter(
                          key: _routerKey,
                          placeholder: (context) => const LoadingPage(),
                          clipBehavior: Clip.none,
                        ),
                      );
                    },
                  ),
                );

                Widget body = layoutState.multiPanel
                    ? panelLayout
                    // Single-panel (mobile): paint the OS status-bar slot
                    // with the header's background color so the two read
                    // as one continuous strip on iOS/Android. The
                    // SafeArea pushes the actual UnifiedHeader below the
                    // status bar; the ColoredBox extends *behind* that
                    // inset so the area showing through the system clock
                    // / dynamic island matches the header.
                    : ColoredBox(
                        color: context.colour.panelDarkestBackground,
                        child: SafeArea(
                          top: true,
                          bottom: false,
                          left: false,
                          right: false,
                          child: Column(
                            children: [
                              const UnifiedHeader(),
                              Expanded(child: panelLayout),
                            ],
                          ),
                        ),
                      );

                if (layoutState.multiPanel) {
                  body = DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: context.colour.frameBackgroundGradient,
                    ),
                    child: body,
                  );
                }
                // PriorityPage doesn't use the Plot Scaffold (it owns its
                // own Column/UnifiedHeader/ResizablePanelLayout), so the
                // route-level DefaultTextStyle override in app.dart is
                // the only thing standing between this content and
                // MaterialApp's `_errorTextStyle` (yellow double-underline).
                // On mobile, descendants here can end up resolving to a
                // Material-injected DefaultTextStyle whose decoration
                // leaks through. Force forui defaults with an explicit
                // `decoration: TextDecoration.none` so headers and any
                // other Text in this subtree paint cleanly.
                return DefaultTextStyle(
                  style: context.theme.typography.md.copyWith(
                    color: context.theme.colors.foreground,
                    decoration: TextDecoration.none,
                  ),
                  child: body,
                );
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
    // Watch NowBloc so the Cmd+Shift+Space binding swaps between
    // StartTimer/StopTimer as the pomodoro state transitions — both
    // share the same shortcut, so the scope must register only the
    // currently-enabled one.
    final nowState = context.watch<NowBloc>().state;
    return CommandScope(
      commands: currentPriorityCommandGroups(
        bloc.state.thread?.priority ?? bloc.state.context,
        nowState: nowState,
      ),
      child: child,
    );
  }
}

/// Provides global keyboard shortcuts for PriorityPage list navigation
/// that work even when focus is in ThreadPage (e.g., ThreadEditor).
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

  void registerController(InfiniteListController controller) {
    _priorityListController = controller;
  }

  /// Returns the controller for the priority page's activity feed list.
  InfiniteListController? _resolveController(BuildContext context) {
    return _priorityListController;
  }

  void registerSearchToggle(VoidCallback callback) {
    _searchToggleCallback = callback;
  }

  void unregisterSearchToggle() {
    _searchToggleCallback = null;
  }

  /// Returns the thread at the currently focused list index, or falls back
  /// to the currently opened thread (`priorityBloc.state.thread`).
  Thread? _resolveFocusedOrCurrentThread(BuildContext context) {
    final priorityBloc = context.read<PriorityBloc>();
    final controller = _resolveController(context);
    if (controller != null && controller.focusedIndex != null) {
      final items = priorityBloc.state.activityFeedItems;
      final idx = controller.focusedIndex!;
      if (idx >= 0 && idx < items.length && items[idx] is AgendaThreadItem) {
        return (items[idx] as AgendaThreadItem).thread;
      }
    }
    return priorityBloc.state.thread;
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
    final items = priorityBloc.state.activityFeedItems;

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

  /// Focuses the priority page's activity feed list, requesting focus on
  /// the currently opened thread or the first thread item.
  void _focusList(BuildContext context) {
    final controller = _priorityListController;
    if (controller == null) return;

    final priorityBloc = context.read<PriorityBloc>();
    final items = priorityBloc.state.activityFeedItems;

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

    priorityBloc.threadListSource = ThreadListSource.activityFeed;
    controller.requestFocus(targetIndex);
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
                ToggleStartFinishCurrentThreadIntent:
                    CallbackAction<ToggleStartFinishCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          if (thread.todo) {
                            FinishThread(thread).run(context);
                          } else {
                            StartThread(thread).run(context);
                          }
                        }
                        return null;
                      },
                    ),
                ArchiveCurrentThreadIntent:
                    CallbackAction<ArchiveCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          ArchiveThread(thread).run(context);
                        }
                        return null;
                      },
                    ),
                FocusOrToggleAgendaActivityIntent:
                    CallbackAction<FocusOrToggleAgendaActivityIntent>(
                      onInvoke: (_) {
                        // PriorityPage now renders only the activity feed,
                        // so this shortcut just focuses that list.
                        _focusList(context);
                        return null;
                      },
                    ),
                ScheduleCurrentThreadIntent:
                    CallbackAction<ScheduleCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          PickScheduleThread(thread).run(context);
                        }
                        return null;
                      },
                    ),
              },
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  platformSingleActivator(LogicalKeyboardKey.keyA, shift: true):
                      const FocusOrToggleAgendaActivityIntent(),
                  platformSingleActivator(LogicalKeyboardKey.slash):
                      const ToggleSearchIntent(),
                  platformSingleActivator(LogicalKeyboardKey.keyD):
                      const ToggleStartFinishCurrentThreadIntent(),
                  platformSingleActivator(LogicalKeyboardKey.keyD, shift: true):
                      const ScheduleCurrentThreadIntent(),
                  platformSingleActivator(LogicalKeyboardKey.backspace):
                      const ArchiveCurrentThreadIntent(),
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

            // Back-handling for single-panel mode happens inside
            // [PriorityOnlyPage] so the PopScope sits in the inner
            // AutoRouter's top-route widget tree — that's where
            // Android's predictive-back dispatcher looks. A PopScope
            // here, at PriorityRoute level, would be outside the
            // inner navigator and would not register as the
            // back-handler for the active /p/X route on Android.
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
  }) : priorityId = PriorityId.tryFromShortString(priorityIdString);

  final PriorityId? priorityId;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // This route means no thread is selected — clear any stale thread state.
      // Handles browser back / gesture back which bypass PopScope.
      context.read<PriorityBloc>().setThread(null);
      final layoutState = context.read<LayoutBloc>().state;
      if (layoutState.middlePanelVisible &&
          !context.router.currentPath.endsWith('/new')) {
        context.router.navigate(NewThreadRoute());
      }
    });
  }

  @override
  void didUpdateWidget(PriorityOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutState = context.read<LayoutBloc>().state;
    if (layoutState.middlePanelVisible &&
        !context.router.currentPath.endsWith('/new')) {
      context.router.navigate(NewThreadRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    final priorityId = widget.priorityId;
    if (priorityId == null) {
      // Parent PriorityWrapper handles redirect for invalid ids.
      return const SizedBox.shrink();
    }
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (!layoutState.multiPanel) {
          // Wrap PriorityPage with a PopScope so Android's predictive
          // back (and any router.maybePop) is intercepted at the inner-
          // navigator's TOP ROUTE level. A PopScope sitting outside the
          // inner AutoRouter (in PriorityWrapper's tree) doesn't register
          // with Android's OnBackInvokedDispatcher for the inner route, so
          // the back gesture closes the activity instead of returning to
          // the source tab. Search closing falls through via
          // [ActivityPanelControllerProvider].
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              final shortcuts =
                  ActivityPanelControllerProvider.maybeOf(context);
              if (shortcuts != null && shortcuts.tryCloseSearch()) return;
              // Return to whichever bottom-nav tab the user came from
              // when they tapped the priority chip. Cleared by the
              // bottom-nav handler when the user taps Priorities/Agenda
              // (so back from a tab-arrival exits the app cleanly).
              // Falls back to Agenda for deep-link arrivals.
              final source = PrioritiesShell.sourceTab ?? 1;
              PrioritiesShell.sourceTab = null;
              AutoTabsRouter.of(context).setActiveIndex(source);
            },
            child: PriorityPage(priorityId: priorityId),
          );
        }
        if (layoutState.middlePanelVisible) {
          // In multi-panel mode, always redirect to /new — NewThreadPage
          // handles special cases (twist dev, viewer) itself. Most
          // command-driven priority switches already pass
          // `children: [NewThreadRoute()]` so this branch is only hit on
          // cold deep-links / post-signin / notification fallbacks where
          // LayoutBloc isn't reachable at navigation time.
          if (!context.router.currentPath.endsWith('/new')) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && layoutState.middlePanelVisible) {
                context.router.navigate(NewThreadRoute());
              }
            });
          }
          // Empty rather than a LoadingPage so the one-frame gap before
          // NewThreadPage mounts doesn't flash a spinner. The middle panel
          // (PriorityPage) is already rendered by the wrapper, so the user
          // sees that immediately and the right panel just appears.
          return const SizedBox.shrink();
        }
        return PriorityPage(priorityId: priorityId);
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
    with TickerProviderStateMixin {
  late final BlockDragController _activityFeedDragController =
      BlockDragController(vsync: this);

  /// Memoized drop-boundary computation. Recomputing on every parent
  /// rebuild would re-walk the entire feed and re-parse every section
  /// marker. Cache by `displayItems` identity — `_rebuildActivityFeedSections`
  /// produces a fresh `List.unmodifiable` on each emit, so reference
  /// equality is the right key.
  List<AgendaItem>? _cachedDropBoundaryItems;
  ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList})?
  _cachedDropBoundaries;

  @override
  void initState() {
    super.initState();
    // One-shot: when the user lands on this priority from a
    // multi-thread notification tap, [NotificationLandingPage] leaves
    // `PendingActivityFeedView.openUnreadFilter` set. Consume and
    // clear the flag in a post-frame callback so `PriorityBloc` is
    // already available via context.read.
    if (PendingActivityFeedView.openUnreadFilter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!PendingActivityFeedView.openUnreadFilter) return;
        PendingActivityFeedView.openUnreadFilter = false;
        context
            .read<PriorityBloc>()
            .activateUnreadFilterFromNotification();
      });
    }
  }

  @override
  void dispose() {
    _activityFeedDragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<PriorityBloc, PriorityState>(
          listenWhen: (previous, current) =>
              previous.context.id != current.context.id,
          listener: (context, state) {
            final nowBloc = context.read<NowBloc>();
            nowBloc.setFocus(state.context);
            nowBloc.setContext(state.context);
            // Reset scroll to top on priority switch
            final scrollController = ScrollControllerContext.of(context);
            if (scrollController != null && scrollController.hasClients) {
              scrollController.jumpTo(0);
            }
          },
        ),
        // Mirror NowBloc.currentEvent into PriorityBloc so the activity
        // feed can render the "Event Agenda" section.
        BlocListener<NowBloc, NowState>(
          listenWhen: (previous, current) {
            final p = previous is NowLoaded ? previous.currentEvent : null;
            final n = current is NowLoaded ? current.currentEvent : null;
            return p?.id != n?.id || p?.occurrence != n?.occurrence;
          },
          listener: (context, nowState) {
            final event = nowState is NowLoaded ? nowState.currentEvent : null;
            context.read<PriorityBloc>().setCurrentEventForFeed(event);
          },
        ),
      ],
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          return _buildBody(context, state);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, PriorityState state) {
    return Builder(
      builder: (context) {
        final items = state.activityFeedViewItems;

        // Build shortcuts map for plain Up/Down navigation
        final shortcuts = <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.enter):
              const OpenFocusedItemActionsIntent(),
          const SingleActivator(LogicalKeyboardKey.escape):
              const ClearItemFocusIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const MoveFocusUpIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const MoveFocusDownIntent(),
        };

        // Get activity panel provider to check if ThreadPage is open
        final activityProvider = ActivityPanelControllerProvider.maybeOf(
          context,
        );

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
                event.logicalKey == LogicalKeyboardKey.arrowUp && !hasModifiers;
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
                activity: (agendaActivity) =>
                    context.run(ChangeCurrentThread(agendaActivity.thread)),
              );
            },
            builder: (context, listController) {
              final provider = _PriorityListControllerProvider.maybeOf(context);
              provider?.registerController(listController);

              return Shortcuts(
                shortcuts: shortcuts,
                child: Actions(
                  actions: {
                    MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                      onInvoke: (intent) {
                        provider?._moveFocusOrStart(
                          listController,
                          -1,
                          context,
                        );
                        return null;
                      },
                    ),
                    MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                      onInvoke: (intent) {
                        provider?._moveFocusOrStart(listController, 1, context);
                        return null;
                      },
                    ),
                    OpenFocusedItemActionsIntent:
                        CallbackAction<OpenFocusedItemActionsIntent>(
                          onInvoke: (_) {
                            final priorityBloc = context.read<PriorityBloc>();
                            final focusedIndex = listController.focusedIndex;
                            if (focusedIndex != null &&
                                focusedIndex >= 0 &&
                                focusedIndex < items.length) {
                              // Capture bloc here so dispatched commands
                              // (e.g. Archive) keep their optimistic path
                              // alive when the modal context can't resolve
                              // PriorityBloc.
                              final capturedBloc = priorityBloc;
                              context.run(
                                OpenFocusedItemActions(listController, (
                                  index,
                                ) async {
                                  final item =
                                      index >= 0 && index < items.length
                                      ? items[index]
                                      : null;
                                  if (item == null) {
                                    return <StaticCommandGroup>[];
                                  }
                                  return await item
                                      .when<Future<List<StaticCommandGroup>>>(
                                        activity: (agendaActivity) =>
                                            threadCommandGroups(
                                              agendaActivity.thread,
                                              priorityBloc: capturedBloc,
                                            ),
                                        header: (_) async =>
                                            <StaticCommandGroup>[],
                                      );
                                }),
                              );
                            }
                            return null;
                          },
                        ),
                    ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                      onInvoke: (_) {
                        listController.clearFocus();
                        // When ThreadPage is open, also focus ThreadEditor
                        activityProvider?._activityEditorFocusCallback?.call();
                        return null;
                      },
                    ),
                  },
                  child: CommandScope(
                    commandsBuilder: () {
                      final index = listController.lastFocusedIndex;
                      if (index == null) {
                        return <StaticCommandGroup>[];
                      }
                      final item = index >= 0 && index < items.length
                          ? items[index]
                          : null;
                      return item?.when<List<StaticCommandGroup>>(
                            activity: (agendaActivity) =>
                                threadCommandGroupsSync(agendaActivity.thread),
                            header: (_) => <StaticCommandGroup>[],
                          ) ??
                          <StaticCommandGroup>[];
                    },
                    listenable: listController,
                    child: Scaffold(
                      scrollable: false,
                      translucent: true,
                      childPad: false,
                      body: ThreadListSourceProvider(
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
  }

  Widget _buildSeparator(
    BuildContext context,
    List<AgendaItem> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final selectedId = state.thread?.id;
    return BlockListSeparator(
      prev: index > 0 && index - 1 < listItems.length
          ? listItems[index - 1]
          : null,
      next: index < listItems.length ? listItems[index] : null,
      controller: controller,
      dragController: _activityFeedDragController,
      index: index,
      selectedAccent: (item) {
        if (item is AgendaThreadItem && item.thread.id == selectedId) {
          return context.colour.colours.fromTheme(
            item.thread.priority.displayColor,
          );
        }
        return null;
      },
      canHighlight: (item) => item is AgendaThreadItem,
      // Activity-feed threads carry their thread id as the drag block id
      // (each row is its own one-row "block"), so match next thread ids
      // directly against the controller's draggingBlockId.
      dragSourceId: (item) =>
          item is AgendaThreadItem ? item.thread.id.toString() : null,
    );
  }

  Widget _buildActivityFeed(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    PageStorageKey<String>? scrollStorageKey,
  }) {
    // Append remote search extras (threads surfaced by the server that
    // aren't visible locally) with a section header. Only when searching.
    //
    // Reuse the incoming `items` reference unchanged in the common case
    // (no extras) so the boundary-cache below can hit by identity.
    final isSearching = state.search.isNotEmpty;
    final List<AgendaItem> displayItems;
    if (isSearching && state.remoteSearchExtras.isNotEmpty) {
      final merged = <AgendaItem>[...items];
      merged.add(const AgendaHeaderItem(text: 'From the server'));
      for (final t in state.remoteSearchExtras) {
        merged.add(AgendaThreadItem(t));
      }
      displayItems = merged;
    } else {
      displayItems = items;
    }

    // A trailing synthetic row is appended when a search footer (spinner,
    // archived hint, or offline note) should be shown.
    final showFooter =
        isSearching &&
        (state.remoteSearchInProgress ||
            state.remoteSearchOffline ||
            (state.hasArchivedMatches && !state.showArchived));

    final hasAnyThread = displayItems.whereType<AgendaThreadItem>().isNotEmpty;

    // Filter on, view empty, and still waiting: either the activity
    // feed has not finished its initial load, or we are inside the
    // notification-activation window waiting for sync to deliver
    // unread items. Show a centered spinner instead of the empty
    // state so the user understands the screen is not frozen.
    if (!hasAnyThread &&
        !showFooter &&
        state.unreadFilterActive &&
        (state.unreadFilterPending || !state.activityFeedLoaded)) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.contentPaddingH,
          vertical: context.theme.spacing.xl,
        ),
        child: Center(
          child: Spinner.message('Loading unread threads'),
        ),
      );
    }

    if (!hasAnyThread &&
        !showFooter &&
        state.activityFeedDoneEnd &&
        state.activityFeedLoaded) {
      final isFiltering =
          state.filter.isNotEmpty || state.iconFilter.isNotEmpty;
      final String emptyMessage;
      if (isSearching && isFiltering) {
        emptyMessage = 'No threads match your search and filters.';
      } else if (isSearching) {
        emptyMessage = 'No threads match your search.';
      } else if (isFiltering) {
        emptyMessage = 'No threads match your filters.';
      } else {
        emptyMessage =
            'Threads track your specific goals and activities, with tasks, notes, and linked documents in one place.\nCreate a thread or add a connection to add threads here.';
      }
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.contentPaddingH,
          vertical: context.theme.spacing.xl,
        ),
        child: Text(
          emptyMessage,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.plotColors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    final bloc = context.read<PriorityBloc>();
    final footerIndex = showFooter ? displayItems.length : -1;
    final totalCount = displayItems.length + (showFooter ? 1 : 0);

    // Drop boundaries depend only on `displayItems`, which gets a fresh
    // identity from `_rebuildActivityFeedSections`. Cache by reference so
    // unrelated parent rebuilds (e.g. RSVP changes elsewhere on the page)
    // don't re-walk the list and re-parse every section marker.
    final ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList}) boundaries;
    if (identical(_cachedDropBoundaryItems, displayItems) &&
        _cachedDropBoundaries != null) {
      boundaries = _cachedDropBoundaries!;
    } else {
      boundaries = computeActivityFeedDropBoundaries(items: displayItems);
      _cachedDropBoundaryItems = displayItems;
      _cachedDropBoundaries = boundaries;
    }
    _activityFeedDragController.dispatcher = (payload, target) {
      dispatchActivityFeedThreadDrop(
        bloc: bloc,
        payload: payload,
        target: target,
      );
    };
    // No preview builder for the activity feed: the drop zone shows a
    // plain expanded gap. The floating drag-feedback already represents
    // the thread under the cursor, so a dimmed-thread preview inside
    // the gap would render the same row twice (once under the pointer,
    // once at the destination).
    _activityFeedDragController.previewBuilder = null;

    final list = InfiniteList(
      controller: controller,
      scrollController: scrollController,
      scrollStorageKey: scrollStorageKey,
      initialScrollOffset: bloc.activityFeedScrollOffset,
      onScrollOffsetChanged: (offset) => bloc.activityFeedScrollOffset = offset,
      count: totalCount,
      doneEnd: state.activityFeedDoneEnd,
      fetcher: (first, count) => bloc.fetchMoreActivityFeedItems(first, count),
      separatorBuilder: (context, index) =>
          _buildSeparator(context, displayItems, index, state, controller),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= totalCount) {
          return null;
        }
        if (index == footerIndex) {
          return _SearchFooter(state: state);
        }
        final current = displayItems[index];
        final dropAbove = boundaries.before[index];
        // Trailing boundary attached to the last list item (skip when the
        // search footer occupies the last index).
        final isLast = !showFooter && index == displayItems.length - 1;
        final tail = isLast ? boundaries.afterList : null;

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
            if (dropAbove != null)
              BlockDropZone(
                target: dropAbove.target,
                silent: dropAbove.silent,
                slotKey: 'feed_drop_above_$index',
                // Active gap sits directly above the next row in this
                // column — paint a 1px divider at the bottom of the
                // expanded gap so the row below isn't flush against
                // the dimmed preview.
                dividerBelow: true,
              ),
            ...current.when(
              header: (header) {
                String? displayText = header.text;
                final marker = displayText == null
                    ? null
                    : ActivitySectionMarker.tryDecode(displayText);
                if (marker != null) displayText = marker.label;
                // Activity-feed section headers (Today / New / Scheduled
                // day buckets / Done) are all just text labels and must
                // render through AgendaTile's text-only heading path so
                // they share color and vertical padding. Scheduled-day
                // headers carry a `date` for drag/keyboard targeting,
                // but passing that into AgendaTile would route them
                // through the date-header path (veryMuted + spacing.md)
                // and they'd stand out from their siblings — drop it
                // here when a section marker is present.
                final tileDate = marker != null ? null : header.date;
                final tile = AgendaTile(
                  dateTimeRange: header.dateTimeRange,
                  date: tileDate,
                  now: header.now,
                  thread: header.thread,
                  focusNode: focusNode,
                  text: displayText,
                  scheduleAt: header.scheduleAt,
                );

                // "Reschedule all" affordance for the Today block and
                // every future Scheduled-day block. Source the thread
                // list from the bloc's native-by-date map so threads
                // that were pushed forward by the per-priority per-day
                // cap travel with their original day rather than the
                // day they happen to be rendering on.
                final canRescheduleAll =
                    marker != null &&
                    (marker.section == ActivitySection.today ||
                        marker.section == ActivitySection.scheduled);
                if (canRescheduleAll) {
                  final sectionDate = marker.section == ActivitySection.today
                      ? Date.today()
                      : header.date;
                  final natives = sectionDate == null
                      ? const <Thread>[]
                      : state.activityFeedNativesByDate[sectionDate] ??
                            const <Thread>[];
                  if (natives.isNotEmpty) {
                    return [
                      _SectionHeaderWithTrailingButton(
                        tile: tile,
                        button: Button.icon(
                          RescheduleAllInBlock(
                            natives,
                            sectionLabel: marker.label,
                          ),
                        ),
                      ),
                    ];
                  }
                }

                // "Mark all read" affordance for the New block. Gather
                // the unread threads under this header from displayItems
                // — they aren't pre-cached on state like the date-keyed
                // natives map.
                if (marker != null &&
                    marker.section == ActivitySection.newSection) {
                  final unread = <Thread>[];
                  for (var i = index + 1; i < displayItems.length; i++) {
                    final next = displayItems[i];
                    if (next is AgendaHeaderItem) break;
                    if (next is AgendaThreadItem) unread.add(next.thread);
                  }
                  if (unread.isNotEmpty) {
                    return [
                      _SectionHeaderWithTrailingButton(
                        tile: tile,
                        button: Button.icon(MarkAllReadInNewSection(unread)),
                      ),
                    ];
                  }
                }

                return [tile];
              },
              activity: (agendaActivity) {
                final baseThread = agendaActivity.thread;
                final rowKey = agendaActivity.isAssociated
                    ? ValueKey(
                        'feed_activitywidget_${baseThread.id}_assoc_${agendaActivity.associationParentId ?? ''}',
                      )
                    : ValueKey('feed_activitywidget_${baseThread.id}');
                final item = _ActivityFeedItem(
                  key: rowKey,
                  baseThread: baseThread,
                  selected:
                      state.thread != null && baseThread.id == state.thread!.id,
                  now: agendaActivity.now,
                  focusNode: focusNode,
                  priorityContext: state.context,
                  isAssociated: agendaActivity.isAssociated,
                );
                if (agendaActivity.pinned) {
                  // Pinned event row: not draggable, not a drop target —
                  // it always leads the Event Agenda section.
                  return [item];
                }
                return [
                  ActivityFeedDraggableRow(
                    threadId: baseThread.id,
                    priorityContext: state.context,
                    child: item,
                  ),
                ];
              },
            ),
            if (tail != null)
              BlockDropZone(
                target: tail.target,
                silent: tail.silent,
                slotKey: 'feed_drop_tail',
              ),
          ],
        );
      },
    );

    return BlockDragScope(
      controller: _activityFeedDragController,
      child: ScrollEdgeFade(background: context.colour.background, child: list),
    );
  }
}

class _SearchFooter extends StatelessWidget {
  const _SearchFooter({required this.state});

  final PriorityState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.plotColors;
    final padding = EdgeInsets.symmetric(
      horizontal: context.contentPaddingH,
      vertical: context.theme.spacing.md,
    );

    if (state.remoteSearchInProgress) {
      return Padding(
        padding: padding,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [const Spinner()],
        ),
      );
    }

    if (state.hasArchivedMatches && !state.showArchived) {
      return Padding(
        padding: padding,
        child: Align(
          alignment: Alignment.center,
          child: FButton(
            variant: FButtonVariant.ghost,
            onPress: () => context.read<PriorityBloc>().toggleShowArchived(),
            child: const Text('View archived items matching this search'),
          ),
        ),
      );
    }

    if (state.remoteSearchOffline) {
      return Padding(
        padding: padding,
        child: Text(
          'Offline — showing local matches only',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class _ActivityFeedItem extends StatefulWidget {
  const _ActivityFeedItem({
    super.key,
    required this.baseThread,
    required this.selected,
    required this.now,
    required this.focusNode,
    required this.priorityContext,
    this.isAssociated = false,
  });

  final Thread baseThread;
  final bool selected;
  final bool now;
  final FocusNode focusNode;
  final Priority priorityContext;
  final bool isAssociated;

  @override
  State<_ActivityFeedItem> createState() => _ActivityFeedItemState();
}

class _ActivityFeedItemState extends State<_ActivityFeedItem> {
  late Future<Thread?> _representative;

  @override
  void initState() {
    super.initState();
    _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
      widget.baseThread,
    );
  }

  @override
  void didUpdateWidget(covariant _ActivityFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseThread.id != widget.baseThread.id ||
        oldWidget.baseThread.scheduleId != widget.baseThread.scheduleId ||
        oldWidget.baseThread.currentUserRsvp !=
            widget.baseThread.currentUserRsvp) {
      _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
        widget.baseThread,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Thread?>(
      future: _representative,
      builder: (context, snapshot) {
        final rep = snapshot.data;
        // Compose the live baseThread with the cached representative's
        // picked schedule + flags so the row reflects up-to-date sync
        // state (unread, title, tags, …) instead of the snapshot taken
        // when the representative was resolved. See
        // PriorityBloc._representativeCache for why we cache.
        final display = rep != null
            ? widget.baseThread.withRepresentativeFrom(rep)
            : widget.baseThread;
        // Key intentionally excludes the resolved scheduleId — including
        // it would change identity once the Future resolves and force
        // every ThreadWidget to remount, dropping focus and re-running
        // layout.
        return ThreadWidget(
          key: ValueKey('feed_activitywidget_${widget.baseThread.id}'),
          activity: display,
          selected: widget.selected,
          now: widget.now,
          focusNode: widget.focusNode,
          context: widget.priorityContext,
          showSubPriority: true,
          bump: false,
          showEventTiming: rep != null,
          isAssociated: widget.isAssociated,
        );
      },
    );
  }
}

/// Section header (Today, a future Scheduled day, or New) overlaid with a
/// small trailing-edge affordance ("Reschedule all" / "Mark all read").
/// The underlying [AgendaTile] keeps its centered text and dark band; the
/// button is laid out in a Row with an invisible mirror on the left so the
/// centered title stays at the row's true horizontal midpoint.
class _SectionHeaderWithTrailingButton extends StatelessWidget {
  const _SectionHeaderWithTrailingButton({
    required this.tile,
    required this.button,
  });

  final Widget tile;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    // Using a Row instead of a Stack overlay makes vertical alignment
    // deterministic (CrossAxisAlignment.center, applied by a single
    // layout primitive) and avoids the Stack-with-different-sized-
    // children ambiguity that rendered the icon below the label on iOS
    // while looking centered on macOS.
    final padded = Padding(
      padding: EdgeInsets.symmetric(horizontal: context.theme.spacing.sm),
      child: button,
    );
    return DecoratedBox(
      decoration: BoxDecoration(color: context.colour.headerBackground),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: padded,
          ),
          Expanded(child: tile),
          padded,
        ],
      ),
    );
  }
}
