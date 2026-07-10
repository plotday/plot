import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:equatable/equatable.dart';

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
import 'package:plot/state/feed_move_diff.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/priority_nav.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'priorities.dart';
import 'loading.dart';

/// Returns from a single-panel PriorityPage to the bottom-nav tab the user
/// came from (the focus list, or Agenda for deep-link arrivals). Shared by
/// the back gesture (PopScope) and the visible header back button so both
/// behave identically.
void returnFromPriorityToSourceTab(BuildContext context) {
  final back = computeBackTabFromPriority(
    currentSourceTab: PrioritiesShell.sourceTab,
  );
  PrioritiesShell.sourceTab = back.nextSourceTab;
  AutoTabsRouter.of(context).setActiveIndex(back.targetTab);
}

/// Reserved `/p/:priorityId` segment that opens the synthetic Everything feed
/// instead of a specific priority. A 10-char word can never collide with a
/// real (~22-char base58) priority id, and [PriorityWrapper] checks it before
/// base58 parsing.
const String kEverythingRouteSegment = 'everything';

/// What a `/p/:priorityId` segment resolves to. Pure so it can be unit-tested
/// without a router (see priority_route_target_test.dart), mirroring the
/// [PriorityBloc.shouldApplyWatchedContext] testable-decision pattern.
class PriorityRouteTarget extends Equatable {
  // ignore: unused_element
  const PriorityRouteTarget._({
    required this.everything,
    required this.priorityId,
    required this.invalid,
  });

  /// The reserved Everything feed (no scoped priority).
  const PriorityRouteTarget.everything()
      : everything = true,
        priorityId = null,
        invalid = false;

  /// A scoped focus/Inbox.
  const PriorityRouteTarget.focus(PriorityId id)
      : everything = false,
        priorityId = id,
        invalid = false;

  /// An unparseable segment (e.g. a stale/malformed link).
  const PriorityRouteTarget.invalid()
      : everything = false,
        priorityId = null,
        invalid = true;

  final bool everything;
  final PriorityId? priorityId;
  final bool invalid;

  @override
  List<Object?> get props => [everything, priorityId, invalid];
}

/// Resolves a `/p/:priorityId` segment to a [PriorityRouteTarget]. The reserved
/// [kEverythingRouteSegment] wins before base58 parsing.
PriorityRouteTarget parsePriorityRouteTarget(String segment) {
  if (segment == kEverythingRouteSegment) {
    return const PriorityRouteTarget.everything();
  }
  final id = PriorityId.tryFromShortString(segment);
  return id == null
      ? const PriorityRouteTarget.invalid()
      : PriorityRouteTarget.focus(id);
}

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required this.priorityIdString});

  final String priorityIdString;

  @override
  Widget wrappedRoute(BuildContext context) {
    final target = parsePriorityRouteTarget(priorityIdString);
    if (target.invalid) {
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
    //
    // For the reserved Everything segment there is no scoped priority: the
    // host mounts the feed in Everything mode (priorityId null), and the feed
    // resolves the default Inbox as its draft home.
    return _PriorityWrapperHost(
      priorityIdString: priorityIdString,
      priorityId: target.priorityId,
      everything: target.everything,
    );
  }
}

class _PriorityWrapperHost extends StatefulWidget {
  const _PriorityWrapperHost({
    required this.priorityIdString,
    required this.priorityId,
    this.everything = false,
  });

  final String priorityIdString;

  /// Null in the reserved Everything view (no scoped priority).
  final PriorityId? priorityId;

  /// Whether this is the synthetic Everything feed rather than a scoped focus.
  final bool everything;

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
      innerRouter.replaceAll([multi ? NewThreadRoute() : PriorityOnlyRoute()]);
    });
  }

  StackRouter? _findInnerRouter() {
    StackRouter? walk(RoutingController controller) {
      final direct = controller.innerRouterOf<StackRouter>(PriorityRoute.name);
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
      if (segment.hasChildren && _segmentsContainThread(segment.children!)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => _build(context, widget.priorityId);

  Widget _build(BuildContext context, PriorityId? priorityId) {
    final everything = widget.everything;
    return PriorityBlocProvider(
      // Everything has no scoped priority: load the default Inbox as the
      // draft home (the `useDefault` path, as the Search feed does) and do
      // not publish a scoped context to NowBloc. A scoped focus loads its id.
      priorityId: everything ? null : priorityId,
      useDefault: everything,
      setContext: !everything,
      // Establish Everything from the provider (built in both panel layouts),
      // not a per-page hook — single-panel never builds the `middle` panel.
      everything: everything,
      child: _PriorityCommandScope(
        child: _PriorityShortcutsProvider(
          priorityId: priorityId,
          child: ThreadHeaderNotifierProvider(
            child: BlocBuilder<LayoutBloc, LayoutState>(
              builder: (context, layoutState) {
                return StreamBuilder<bool>(
                  stream: TwistInstance.watchHasCalendarConnection(),
                  initialData: TwistInstance.hasCalendarConnectionInCache,
                  builder: (context, snap) {
                    final hasCalendar = snap.data ?? false;
                    // In single-panel mode UnifiedHeader sits above the panel
                    // layout. In multi-panel mode the panel layout splits the
                    // window into A (sidebar header + priorities + agenda) and
                    // B (main header + shared squircle containing middle +
                    // right). The outer A|B divider runs top-to-bottom; the
                    // inner middle|right divider stays inside the squircle.
                    final panelLayout = ResizablePanelLayout(
                      left: PrioritiesPanelContent(),
                      leftBottom: hasCalendar
                          ? const LeftPanelAgendaView()
                          : null,
                      leftFooter: layoutState.multiPanel
                          ? const LeftPanelFooter()
                          : null,
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
                                  // Single-panel only: hand the header a back
                                  // action so it can show a visible ← that
                                  // mirrors the OS back gesture
                                  // (returnFromPriorityToSourceTab). The header
                                  // decides whether to render it (only on the
                                  // bare /p/:id priority page, not thread/new).
                                  UnifiedHeader(
                                    onBack: () =>
                                        returnFromPriorityToSourceTab(context),
                                  ),
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
                        // The top status-bar inset is applied *per branch*
                        // inside ResizablePanelLayout, not here. The docked
                        // and main-column-only branches wrap their whole
                        // output in a top SafeArea (matching the old shared
                        // wrapper exactly). The two-panel band insets only its
                        // main column, leaving the overlay drawer free to
                        // paint its opaque surface up behind the status bar
                        // while padding its own content clear of it. Desktop
                        // top inset is 0, so all of this is a no-op there.
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
    // The sidebar's PrioritiesBloc list is enriched with hasThreads; reuse it
    // so the command-palette focus menu shows the right Archive/Merge label.
    final loaded = context.watch<PrioritiesBloc>().state.priorities;
    // The unscoped Everything view has a null context; its priority command
    // scope operates on the draft's Inbox fallback (the focus a new thread
    // would file into).
    final focus = bloc.state.thread?.priority ??
        bloc.state.context ??
        bloc.state.draft.priority;
    return CommandScope(
      commands: currentPriorityCommandGroups(
        enrichFocusFromList(focus, loaded),
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

  /// Null in the reserved Everything view (no scoped priority). Unused
  /// within this class's State, so nullability requires no further changes
  /// here.
  final PriorityId? priorityId;
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
                            ToggleThreadActive(thread).run(context);
                          }
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
  }) : target = parsePriorityRouteTarget(priorityIdString);

  /// Resolved route target. The reserved Everything segment yields a null
  /// [PriorityRouteTarget.priorityId] but is NOT invalid, so the single-panel
  /// feed still mounts (in Everything mode). Parsing via
  /// [parsePriorityRouteTarget] — rather than a bare `tryFromShortString` —
  /// keeps `everything` from decoding into a garbage priority id.
  final PriorityRouteTarget target;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A cross-priority thread-open (e.g. tapping an agenda event for a
      // different focus) navigates this router to PriorityRoute, then polls
      // across frames for its inner router to mount before replacing the
      // stack with ThreadRoute — see _replaceWithThreadWhenInnerReady in
      // widget/agenda.dart. That poll can win the race and land ThreadRoute
      // before this deferred callback runs. Bail if we're no longer the
      // active route so we don't clobber it back to NewThreadRoute.
      if (context.router.current.name != PriorityOnlyRoute.name) return;
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
    if (widget.target.invalid) {
      // Parent PriorityWrapper handles redirect for invalid ids.
      return const SizedBox.shrink();
    }
    // Null in Everything mode; the feed mounts unscoped (the bloc is already in
    // Everything mode via PriorityBlocProvider).
    final priorityId = widget.target.priorityId;
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
            onPopInvokedWithResult: (didPop, popResult) {
              if (didPop) return;
              final shortcuts = ActivityPanelControllerProvider.maybeOf(
                context,
              );
              if (shortcuts != null && shortcuts.tryCloseSearch()) return;
              final priorityBloc = context.read<PriorityBloc>();
              if (priorityBloc.state.unreadFilterActive) {
                priorityBloc.updateUnreadFilter(false); // first back clears the filter
                return; // stay in the focus
              }
              // Return to whichever bottom-nav tab the user came from
              // when they tapped the priority chip. Shared with the
              // visible header back button so both behave identically.
              returnFromPriorityToSourceTab(context);
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
  const PriorityPage({this.priorityId, super.key});

  /// Null in the reserved Everything view (Everything mode is established by
  /// [PriorityBlocProvider], not this page).
  final PriorityId? priorityId;

  @override
  State<PriorityPage> createState() => _PriorityPageState();
}

class _PriorityPageState extends State<PriorityPage>
    with TickerProviderStateMixin {
  BlockDragController? _activityFeedDragControllerInstance;
  BlockDragController get _activityFeedDragController =>
      _activityFeedDragControllerInstance ??= BlockDragController(vsync: this);

  /// Guard: ensure the notification unread-intent is applied at most once
  /// per mount even if the bloc rebuilds before the post-frame callback fires.
  bool _appliedUnreadIntent = false;

  /// Memoized drop-boundary computation. Recomputing on every parent
  /// rebuild would re-walk the entire feed and re-parse every section
  /// marker. Cache by `displayItems` identity — `_rebuildActivityFeedSections`
  /// produces a fresh `List.unmodifiable` on each emit, so reference
  /// equality is the right key.
  List<AgendaItem>? _cachedDropBoundaryItems;
  ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList})?
  _cachedDropBoundaries;

  // ---- Feed move animation (collapse at source / expand at destination).
  // Driven by PriorityState.feedMoveGen: explicit user state changes bump
  // the generation; the diff between the previous and current item lists
  // is animated with one controller so heights stay synchronized and rows
  // outside the moved range never shift.
  int _lastMoveGen = 0;
  List<AgendaItem> _lastFeedItems = const [];
  FeedMoveDiff _activeMoveDiff = FeedMoveDiff.empty;
  AnimationController? _moveController;
  Animation<double>? _moveAnimation;

  /// Start (or replace) the move animation for [diff]. A new move while
  /// one is in flight completes the old one instantly.
  void _startMoveAnimation(FeedMoveDiff diff) {
    _moveController?.dispose();
    _moveController = null;
    _moveAnimation = null;
    _activeMoveDiff = diff;
    if (diff.isEmpty) return;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _moveController = controller;
    _moveAnimation = CurvedAnimation(
      parent: controller,
      curve: Curves.easeInOutCubic,
    );
    controller.forward().whenComplete(() {
      if (!mounted || _moveController != controller) return;
      setState(() {
        _activeMoveDiff = FeedMoveDiff.empty;
        _moveController = null;
        _moveAnimation = null;
      });
      controller.dispose();
    });
  }

  /// Splice the active move's collapsing ghosts into [items] after their
  /// anchor rows (the nearest stable item above the ghost's old position).
  /// A ghost whose anchor is missing from [items] is dropped (snaps).
  List<_FeedEntry> _spliceGhosts(List<AgendaItem> items) {
    final diff = _activeMoveDiff;
    if (diff.ghosts.isEmpty) {
      return [for (final item in items) _FeedEntry(item)];
    }
    final byAnchor = <String?, List<AgendaItem>>{};
    for (final g in diff.ghosts) {
      byAnchor.putIfAbsent(g.anchorKey, () => []).add(g.item);
    }
    final entries = <_FeedEntry>[
      for (final g in byAnchor[null] ?? const <AgendaItem>[])
        _FeedEntry(g, ghost: true),
    ];
    for (final item in items) {
      entries.add(_FeedEntry(item));
      final ghosts = byAnchor[feedItemKey(item)];
      if (ghosts != null) {
        entries.addAll([for (final g in ghosts) _FeedEntry(g, ghost: true)]);
      }
    }
    return entries;
  }

  @override
  void initState() {
    super.initState();
    // One-shot: when the user lands on this priority from a
    // multi-thread notification tap, [NotificationLandingPage] leaves
    // `PendingActivityFeedView.scrollToUpdates` set. Consume and clear
    // the flag in a post-frame callback so `PriorityBloc` is already
    // available via context.read.
    if (PendingActivityFeedView.scrollToUpdates) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!PendingActivityFeedView.scrollToUpdates) return;
        PendingActivityFeedView.scrollToUpdates = false;
        context.read<PriorityBloc>().selectActivityTab(ActivityTab.unified);
      });
    }
    // One-shot: when the user opens a focus from a notification,
    // [_navigateToNotificationTarget] sets `openUnreadOnly`. Apply the
    // unread filter exactly once on the first post-frame so PriorityBloc
    // is reachable. If there is nothing unread, Task 11's auto-off safety
    // net (`_rebuildActiveTabSection`: `unreadFilterActive && !hasUnread`)
    // will clear the filter on the next feed rebuild — no need to gate here.
    if (PendingActivityFeedView.openUnreadOnly) {
      PendingActivityFeedView.openUnreadOnly = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _appliedUnreadIntent) return;
        _appliedUnreadIntent = true;
        context.read<PriorityBloc>().updateUnreadFilter(true);
      });
    }
  }

  @override
  void dispose() {
    _activityFeedDragControllerInstance?.dispose();
    _moveController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<PriorityBloc, PriorityState>(
          // Null id in the unscoped Everything view; the ?.id comparison still
          // fires on entering/leaving Everything (null <-> a focus id).
          listenWhen: (previous, current) =>
              previous.context?.id != current.context?.id,
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
        // Mirror NowBloc.everything into PriorityBloc so the activity feed
        // re-scopes to the unscoped "Everything" list (or back to the scoped
        // focus/Inbox view) when the user toggles the sidebar tiles.
        BlocListener<NowBloc, NowState>(
          listenWhen: (previous, current) {
            final p = previous is NowLoaded && previous.everything;
            final n = current is NowLoaded && current.everything;
            return p != n;
          },
          listener: (context, nowState) {
            final everything = nowState is NowLoaded && nowState.everything;
            context.read<PriorityBloc>().setEverything(everything);
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

            // Escape exits multi-select first when a selection is active;
            // otherwise it falls through to ClearItemFocusIntent below.
            if (event.logicalKey == LogicalKeyboardKey.escape &&
                state.multiSelecting) {
              context.read<PriorityBloc>().clearSelection();
              return KeyEventResult.handled;
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
                        // Sticky tab header. In multi-panel mode it
                        // sits above the scrollable list and carries
                        // the "Do all later" button on the right.
                        // In single-panel (phone) mode it sits at
                        // the bottom of the screen for thumb reach,
                        // offset upward by the measured bottom-nav
                        // height so it lands just above the nav
                        // rather than under it. A visible "Today"
                        // date header at the top of the list takes
                        // over labelling the first block.
                        child: Builder(
                          builder: (context) {
                            // Unified feed: no tab header. The four
                            // sections (Updates / Doing / Scheduled /
                            // Activity) render inline as agenda headers.
                            // Key per-focus scroll restoration by the focus the
                            // DISPLAYED items belong to (`activeTabContext`), not
                            // the route's `priorityId`. On a switch the route id
                            // flips a few frames before the bloc swaps in the new
                            // focus's items (it keeps the outgoing list to avoid a
                            // blank frame). Keying by the route would recreate the
                            // scroll position — and restore its saved offset —
                            // against the OUTGOING list, scrolling the wrong
                            // content (and overscroll-stranding it while content
                            // streams in). Keying by the items' focus moves the
                            // position swap to the instant the new content lands,
                            // so PageStorage restores it directly at its offset.
                            // Falls back to the route id before any items load and
                            // in the unscoped Everything view (null context).
                            final feedScrollFocusId =
                                state.activeTabContext?.id ?? widget.priorityId;
                            // Subtle switch transition: while the route's focus
                            // is ahead of the focus the displayed items belong
                            // to — the bloc holds the outgoing list for a beat
                            // until the new focus's items stream in (~200ms) —
                            // dim the feed toward the panel background. This
                            // gives immediate feedback that the tap registered
                            // and softens the content swap.
                            //
                            // Dim with an overlay SCRIM (a translucent fill of
                            // the panel background painted on top), NOT
                            // `AnimatedOpacity` on the feed. A subtree opacity
                            // < 1.0 forces an offscreen `saveLayer` over the
                            // whole feed; on macOS Impeller that offscreen
                            // intermittently failed to composite and painted the
                            // panel a flat grey (an engine-level failure, so no
                            // Dart exception and nothing in error tracking). A
                            // scrim is a plain translucent rect — no offscreen,
                            // nothing to fail — and is mathematically identical
                            // to the old 0.55 opacity because the feed's own
                            // background is this same colour (see the
                            // ScrollEdgeFade in [_buildActivityFeed]): opacity α
                            // over background B equals a scrim of B at alpha
                            // (1 − α).
                            //
                            // [_FeedSwitchScrim] paints that scrim and fades its
                            // alpha with an explicit controller (never an
                            // `Opacity`/`AnimatedOpacity`, which would
                            // reintroduce the saveLayer). IgnorePointer +
                            // StackFit.expand keep it paint-only — no layout or
                            // scroll-offset impact, so it can't disturb the
                            // displayed-content scroll restoration above.
                            final switchingFocus =
                                state.context?.id != state.activeTabContext?.id;
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                _buildActivityFeed(
                                  context,
                                  state,
                                  items,
                                  listController,
                                  ScrollControllerContext.of(context),
                                  scrollStorageKey: PageStorageKey(
                                    'priority_feed_$feedScrollFocusId',
                                  ),
                                ),
                                _FeedSwitchScrim(
                                  active: switchingFocus,
                                  color: context.colour.background,
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
            },
          ),
        );
      },
    );
  }

  Widget _buildSeparator(
    BuildContext context,
    List<_FeedEntry> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final selectedId = state.thread?.id;
    final prevEntry = index > 0 && index - 1 < listItems.length
        ? listItems[index - 1]
        : null;
    final nextEntry = index < listItems.length ? listItems[index] : null;
    final rawPrev = prevEntry?.item;
    final rawNext = nextEntry?.item;
    // A move ghost duplicates the moved thread's id; suppress the
    // selection accent next to ghosts so the open thread doesn't paint
    // two rings while it animates.
    final adjacentGhost =
        (prevEntry?.ghost ?? false) || (nextEntry?.ghost ?? false);
    // The leading separator (above the first item) renders as an invisible
    // background-coloured 1px strip (see BlockListSeparator's `prev == null`
    // branch). In multi-panel mode that strip sits above the feed's leading
    // section header, pushing it 1px lower than the thread panel's actions
    // row across the shared squircle top — the bands' [panelHeaderHeight]s
    // match but the list offset broke the alignment. Drop it so the header
    // sits flush against the panel top like the thread panel's band does.
    if (rawPrev == null && context.isMultiPanel) {
      return const SizedBox.shrink();
    }
    return BlockListSeparator(
      prev: rawPrev,
      next: rawNext,
      controller: controller,
      dragController: _activityFeedDragController,
      index: index,
      selectedAccent: (item) {
        if (adjacentGhost) return null;
        if (item is AgendaThreadItem && item.thread.id == selectedId) {
          // Match the sidebar's selection ring: the lighter, per-focus
          // [borderFromTheme] hue rather than the full-saturation accent.
          return context.colour.colours.borderFromTheme(
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

  /// Builds the feed's section-header widget for [header] at [index] in
  /// [entries]: an [AgendaTile] label plus — for the Doing/Scheduled blocks
  /// that hold threads — the trailing "Mark all read" / "Do all later"
  /// buttons. Shared by the inline list builder and the sticky-header
  /// overlay so the pinned copy is identical to the real header (buttons
  /// included). Scheduled-day headers carry a `date` for drag/keyboard
  /// targeting; it's dropped when a section marker is present so they render
  /// through AgendaTile's text-only heading path (matching their siblings)
  /// rather than the date-header path.
  Widget _buildFeedSectionHeaderWidget(
    BuildContext context,
    List<_FeedEntry> entries,
    int index,
    AgendaHeaderItem header, {
    FocusNode? focusNode,
  }) {
    String? displayText = header.text;
    final marker = displayText == null
        ? null
        : ActivitySectionMarker.tryDecode(displayText);
    if (marker != null) displayText = marker.label;
    final tileDate = marker != null ? null : header.date;

    // "Do all later" affordance for the Doing block and every Scheduled-day
    // block. Collect the threads that follow this header until the next
    // AgendaHeaderItem and skip the button when the block is empty.
    final canRescheduleAll =
        marker != null &&
        (marker.section == ActivitySection.doing ||
            marker.section == ActivitySection.scheduled);
    List<Thread>? sectionThreads;
    if (canRescheduleAll) {
      sectionThreads = <Thread>[];
      for (var j = index + 1; j < entries.length; j++) {
        final nextEntry = entries[j];
        if (nextEntry.ghost) continue;
        final next = nextEntry.item;
        if (next is AgendaHeaderItem) break;
        if (next is AgendaThreadItem) {
          sectionThreads.add(next.thread);
        }
      }
      if (sectionThreads.isEmpty) sectionThreads = null;
    }

    final tile = AgendaTile(
      dateTimeRange: header.dateTimeRange,
      date: tileDate,
      now: header.now,
      thread: header.thread,
      focusNode: focusNode,
      text: displayText,
      scheduleAt: header.scheduleAt,
    );

    if (sectionThreads != null) {
      // The Active (doing) block gains a leading "Mark all read" button when
      // it holds unread threads — same command and icon as the multi-select
      // header's bulk action.
      final showMarkAllRead =
          marker!.section == ActivitySection.doing &&
          BulkMarkRead.applies(sectionThreads);
      return _SectionHeaderWithRescheduleAll(
        tile: tile,
        threads: sectionThreads,
        sectionLabel: marker.label,
        showMarkAllRead: showMarkAllRead,
      );
    }

    return tile;
  }

  Widget _buildActivityFeed(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    PageStorageKey<String>? scrollStorageKey,
  }) {
    // `items` is already the scope-narrowed view (activityFeedViewItems), so
    // local results respect any focus the global view is narrowed to.
    //
    // Reuse the incoming `items` reference unchanged in the common case
    // (no extras) so the boundary-cache below can hit by identity.
    final isSearching = state.search.isNotEmpty;
    final scope = state.globalViewScope;
    // The dedicated (non-search, non-filter) Everything feed spans every focus
    // and is otherwise unsectioned, so — in multi-panel mode — it leads with a
    // single "Everything" section header. Global views (search/filter) render
    // as one headerless flat list, so the header is suppressed there.
    //
    // Drive this off `activeTabEverythingFeed` (recorded when the items were
    // built) rather than the live `state.everything`: on a focus→Everything
    // switch the flag flips a frame before the feed rebuilds, and reading the
    // live flag would prepend "Everything" above the old focus list while its
    // "Active" section header is still present (a visible double-header frame).
    final everythingHeader =
        state.activeTabEverythingFeed &&
        context.read<LayoutBloc>().state.multiPanel &&
        items.whereType<AgendaThreadItem>().isNotEmpty;
    final List<AgendaItem> displayItems;
    if ((isSearching || state.hasActiveFilter) &&
        state.remoteSearchExtras.isNotEmpty) {
      // Remote extras (threads the server surfaced that aren't visible
      // locally) append directly to the same list — no section header. These
      // are surfaced for a filter-only browse (e.g. thread type = "Plot")
      // too, not just text search, so old unsynced matches aren't dropped.
      // [remoteSearchExtrasDeduped] drops any thread that has since entered the
      // local feed (via sync or searchRemote's hydration) so it can't render
      // both as a local row and an extra. When the view is narrowed to a focus,
      // the extras are filtered to it too so they match the local results.
      final deduped = state.remoteSearchExtrasDeduped;
      final extras = scope == null
          ? deduped
          : deduped.where(
              (t) => t.priority.id == scope.id,
            );
      final merged = <AgendaItem>[...items];
      for (final t in extras) {
        merged.add(AgendaThreadItem(t));
      }
      displayItems = merged;
    } else if (everythingHeader) {
      displayItems = <AgendaItem>[
        const AgendaHeaderItem(text: 'Everything'),
        ...items,
      ];
    } else {
      displayItems = items;
    }

    // Move animation: an advanced generation means this rebuild was caused
    // by an explicit user state change — animate the diff (collapsing
    // ghosts at the source, synchronized expands at the destination).
    // Stream-driven rebuilds (same generation) snap as before.
    if (state.feedMoveGen != _lastMoveGen) {
      _lastMoveGen = state.feedMoveGen;
      _startMoveAnimation(
        computeFeedMoveDiff(_lastFeedItems, displayItems, state.feedMovedIds),
      );
    }
    _lastFeedItems = displayItems;

    final renderItems = _spliceGhosts(displayItems);

    // A trailing synthetic row is appended when a search footer (spinner,
    // archived hint, or offline note) should be shown.
    final showFooter =
        isSearching &&
        (state.remoteSearchInProgress ||
            state.remoteSearchOffline ||
            (state.hasArchivedMatches && !state.showArchived));

    final hasAnyThread = displayItems.whereType<AgendaThreadItem>().isNotEmpty;

    // First app load: the bloc starts with `activityFeedLoaded == false` and
    // no items, so show a LoadingPage rather than flashing the empty-state text
    // before the first subscription emission arrives. Priority switches and
    // search/Everything toggles deliberately KEEP the prior list (and
    // `activityFeedLoaded == true`), so they never hit this branch — the old
    // list renders until the new data swaps in, avoiding a blank frame.
    if (!hasAnyThread && !showFooter && !state.activityFeedLoaded) {
      return const LoadingPage();
    }

    // A global view narrowed to a focus filters the loaded global results
    // client-side, so its emptiness doesn't depend on global pagination being
    // exhausted — show the empty state without waiting for `activityFeedDoneEnd`
    // (otherwise an empty narrowed view would spin forever). The unnarrowed
    // view still waits for done-end so it doesn't flash "no matches" mid-load.
    final narrowedToFocus = state.globalViewScope != null;
    if (!hasAnyThread &&
        !showFooter &&
        state.activityFeedLoaded &&
        (state.activityFeedDoneEnd || narrowedToFocus)) {
      final isFiltering =
          state.filter.isNotEmpty || state.iconFilter.isNotEmpty;
      final String emptyMessage;
      if (narrowedToFocus) {
        emptyMessage = 'No matching threads in this focus.';
      } else if (isSearching && isFiltering) {
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
    final footerIndex = showFooter ? renderItems.length : -1;
    final totalCount = renderItems.length + (showFooter ? 1 : 0);

    // Source-aware drag: determine whether the currently-dragged thread is
    // active (so we can suppress drop slots inside the unread cluster).
    final draggingBlockId = _activityFeedDragController.draggingBlockId;
    final draggingActive = draggingBlockId != null &&
        displayItems
            .whereType<AgendaThreadItem>()
            .any((i) =>
                i.thread.id.toString() == draggingBlockId &&
                i.thread.isActiveThread);
    final unreadClusterIds = state.unreadClusterIds;

    // Drop boundaries depend only on `displayItems`, which gets a fresh
    // identity from `_rebuildActivityFeedSections`. Cache by reference so
    // unrelated parent rebuilds (e.g. RSVP changes elsewhere on the page)
    // don't re-walk the list and re-parse every section marker. While move
    // ghosts are spliced in, boundaries are computed over the projected
    // list WITHOUT touching the cache, so the post-animation rebuild
    // doesn't serve stale ghost-offset slots.
    //
    // Note: the boundary cache does NOT key on draggingActive/unreadClusterIds
    // because boundaries are recomputed on every drag-start rebuild (the drag
    // controller notifies listeners when dragging begins, triggering a rebuild).
    final ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList}) boundaries;
    final hasGhosts = renderItems.length != displayItems.length;
    if (hasGhosts) {
      boundaries = computeActivityFeedDropBoundaries(
        items: [for (final e in renderItems) e.item],
        draggingActive: draggingActive,
        unreadClusterIds: unreadClusterIds,
      );
    } else if (identical(_cachedDropBoundaryItems, displayItems) &&
        _cachedDropBoundaries != null &&
        !draggingActive) {
      // Cache hit only when not dragging an active thread — when dragging
      // active, the cluster-suppressed boundaries differ from the normal set.
      boundaries = _cachedDropBoundaries!;
    } else {
      boundaries = computeActivityFeedDropBoundaries(
        items: displayItems,
        draggingActive: draggingActive,
        unreadClusterIds: unreadClusterIds,
      );
      if (!draggingActive) {
        _cachedDropBoundaryItems = displayItems;
        _cachedDropBoundaries = boundaries;
      }
    }
    _activityFeedDragController.dispatcher = (payload, target) {
      dispatchActivityFeedThreadDrop(
        bloc: bloc,
        payload: payload,
        target: target,
        draggingActive: draggingActive,
        unreadClusterIds: unreadClusterIds,
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
      // Use the filtered view's done-end: when the unread-only filter is on,
      // the whole unread set is already loaded by the head streams, so the
      // view is complete even though the read/Done tail still paginates.
      // Otherwise InfiniteList renders a trailing spinner that pages the read
      // tail forever behind the short filtered list (the spinner-stuck-at-end
      // bug when the unread toggle is turned on).
      doneEnd: state.activityFeedViewDoneEnd,
      // Stable identities keep the sliver's elements (and their stored
      // layout offsets) attached to their rows when indices shift — e.g.
      // when a move ghost splices in or out — so the viewport doesn't
      // re-anchor by index and jump. The offset CORRECTION is disabled:
      // ghosts enter/leave at zero height, so the average-extent estimate
      // it applies would itself cause a jump.
      itemKey: (index) {
        if (index == footerIndex) return 'feed_footer';
        if (index < 0 || index >= renderItems.length) {
          return 'feed_overflow_$index';
        }
        final entry = renderItems[index];
        final key = feedItemKey(entry.item);
        return entry.ghost ? 'feed_ghost_${_lastMoveGen}_$key' : key;
      },
      anchorCorrection: false,
      fetcher: (first, count) => bloc.fetchMoreActivityFeedItems(first, count),
      // Pin the feed's text section headers (Active / Doing / Scheduled /
      // Done / Everything …) to the top while their threads scroll beneath.
      // Only text-only headings pin; event/now headers are left alone.
      isStickyHeader: (i) {
        if (i < 0 || i >= renderItems.length) return false;
        final item = renderItems[i].item;
        return item is AgendaHeaderItem &&
            item.text != null &&
            item.dateTimeRange == null;
      },
      stickyHeaderBuilder: (context, index) {
        final header = renderItems[index].item as AgendaHeaderItem;
        // Identical to the inline section header, buttons included, so the
        // pinned copy matches (and its "Do all later" / "Mark all read"
        // actions work — the overlay is not IgnorePointer-wrapped).
        return _buildFeedSectionHeaderWidget(
          context,
          renderItems,
          index,
          header,
        );
      },
      separatorBuilder: (context, index) =>
          _buildSeparator(context, renderItems, index, state, controller),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= totalCount) {
          return null;
        }
        if (index == footerIndex) {
          return SearchFooter(state: state);
        }
        final entry = renderItems[index];
        final current = entry.item;
        // Ghosts are collapsing copies of moved-away rows — never drop
        // targets.
        final dropAbove = entry.ghost ? null : boundaries.before[index];
        // Trailing boundary attached to the last list item (skip when the
        // search footer occupies the last index).
        final isLast = !showFooter && index == renderItems.length - 1;
        final tail = isLast ? boundaries.afterList : null;
        final itemKey = feedItemKey(current);

        var children = current.when<List<Widget>>(
              header: (header) => [
                _buildFeedSectionHeaderWidget(
                  context,
                  renderItems,
                  index,
                  header,
                  focusNode: focusNode,
                ),
              ],
              activity: (agendaActivity) {
                final baseThread = agendaActivity.thread;
                // Must track feedItemKey's identity: the pinned "Event Agenda"
                // copy needs a key distinct from the same event's Scheduled
                // copy, or the two sibling rows collide in the InfiniteList.
                final rowKey = entry.ghost
                    ? ValueKey('feed_ghost_row_$itemKey')
                    : agendaActivity.isAssociated
                    ? ValueKey(
                        'feed_activitywidget_${baseThread.id}_assoc_${agendaActivity.associationParentId ?? ''}',
                      )
                    : agendaActivity.pinned
                    ? ValueKey('feed_activitywidget_${baseThread.id}_pinned')
                    : ValueKey('feed_activitywidget_${baseThread.id}');
                final item = ActivityFeedThreadRow(
                  key: rowKey,
                  baseThread: baseThread,
                  // Row selection is a multi-panel concept — it marks which
                  // thread is open in the side panel beside the list. In
                  // single-panel the list and an open thread are never shown
                  // together, so never highlight a row there (state.thread can
                  // linger after a back-navigation that didn't clear it — e.g.
                  // a notification/deep-link single-ThreadRoute stack).
                  selected:
                      !entry.ghost &&
                      context.isMultiPanel &&
                      state.thread != null &&
                      baseThread.id == state.thread!.id,
                  now: agendaActivity.now,
                  focusNode: focusNode,
                  // Use the context the displayed items were built for (not the
                  // live one) so the per-row focus label stays consistent with
                  // the rows during a focus switch — the previous focus's kept
                  // rows must not flash the previous focus's label before they
                  // swap out. Drag (below) still targets the live context. In
                  // the unscoped Everything view both are null, so fall back to
                  // the draft's Inbox priority.
                  priorityContext: state.activeTabContext ??
                      state.context ??
                      state.draft.priority,
                  isAssociated: agendaActivity.isAssociated,
                  // Every global, cross-priority view — the Everything feed and
                  // any active search OR filter, not just a text search — is a
                  // flat list spanning all focuses, so each row must carry its
                  // own focus label. Passing only `isSearching` here dropped the
                  // label on filtered / Everything results filed under the
                  // ambient [priorityContext].
                  isGlobalView: state.isGlobalView,
                  multiSelected:
                      !entry.ghost && state.selected.contains(baseThread.id),
                  multiSelectMode: state.multiSelecting,
                );
                if (agendaActivity.pinned ||
                    entry.ghost ||
                    state.multiSelecting) {
                  // Pinned event rows, move ghosts, and any row while
                  // multi-selecting: not draggable, not drop targets.
                  return [item];
                }
                return [
                  ActivityFeedDraggableRow(
                    threadId: baseThread.id,
                    // Everything (null context) → drag default-targets the
                    // draft's Inbox priority.
                    priorityContext: state.context ?? state.draft.priority,
                    child: item,
                  ),
                ];
              },
        );

        // Move animation wrappers: ghosts collapse 1→0 at the source while
        // destination rows expand 0→1, driven by one shared controller so
        // total height between source and destination stays constant and
        // rows outside that range never shift.
        final anim = _moveAnimation;
        if (anim != null) {
          if (entry.ghost) {
            children = [
              SizeTransition(
                sizeFactor: ReverseAnimation(anim),
                alignment: Alignment.topCenter,
                child: ExcludeFocus(
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ];
          } else if (_activeMoveDiff.expandingKeys.contains(itemKey)) {
            children = [
              SizeTransition(
                sizeFactor: anim,
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ];
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            entry.ghost
                ? 'feed_ghost_${_lastMoveGen}_$itemKey'
                : current.when(
                    header: (h) => h.date != null
                        ? 'feed_header_date_${h.date}'
                        : 'feed_header_${h.text}',
                    activity: (a) => 'feed_activity_${a.thread.id}',
                  ),
          ),
          children: [
            // The Everything feed spans every focus, so per-row gap drop
            // targets (which schedule into the current scope) don't apply —
            // suppress them and render one plain unsectioned list.
            if (dropAbove != null && !state.everything)
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
            ...children,
            if (tail != null && !state.everything)
              BlockDropZone(
                target: tail.target,
                silent: tail.silent,
                slotKey: 'feed_drop_tail',
              ),
          ],
        );
      },
    );

    // The single-panel bottom nav is overlaid on top of the page content
    // (see _MobileShellChrome's Stack), so reserve its measured height as
    // bottom padding — otherwise the last feed rows are painted under the
    // nav and can't be scrolled into view (reachable only via overscroll).
    // BottomNavInset.of returns 0 in multi-panel and on nav-hidden routes,
    // so this is a no-op there.
    return Padding(
      padding: EdgeInsets.only(bottom: BottomNavInset.of(context)),
      child: BlockDragScope(
        controller: _activityFeedDragController,
        child: ScrollEdgeFade(
          background: context.colour.background,
          // The pinned section header paints its own fade below its seam;
          // a top fade here would sit on top of that header instead.
          top: false,
          child: list,
        ),
      ),
    );
  }
}

/// A row in the rendered activity feed: a live [AgendaItem], or a
/// collapsing ghost of one (the source side of a move animation).
class _FeedEntry {
  const _FeedEntry(this.item, {this.ghost = false});
  final AgendaItem item;
  final bool ghost;
}

/// Opaque scrim that dims the activity feed toward the panel background during
/// a focus switch (see the feed builder's call site for why the feed dims while
/// the bloc holds the outgoing list until the new focus's items stream in).
///
/// Painted as an overlay scrim rather than wrapping the feed in
/// `Opacity`/`AnimatedOpacity`: a subtree opacity < 1.0 forces an offscreen
/// `saveLayer`, and on macOS Impeller that offscreen intermittently failed to
/// composite and rendered the whole panel a flat grey (an engine-level failure,
/// so no Dart exception reached error tracking). A translucent rect has no
/// offscreen and is mathematically identical to the old 0.55 opacity — the
/// feed's own background is [color], and opacity α over background B equals a
/// scrim of B at alpha (1 − α).
///
/// The alpha is animated by an explicit [AnimationController] — never an
/// `Opacity`/`AnimatedOpacity` on the scrim itself, which would reintroduce the
/// very `saveLayer` this exists to avoid.
class _FeedSwitchScrim extends StatefulWidget {
  const _FeedSwitchScrim({required this.active, required this.color});

  /// Whether the feed is mid-switch and should be dimmed. Toggling this drives
  /// the fade in/out.
  final bool active;

  /// The panel background colour the scrim fades in over the feed. Matches the
  /// feed's own background so the dim reads as a uniform wash, not a tint.
  final Color color;

  @override
  State<_FeedSwitchScrim> createState() => _FeedSwitchScrimState();
}

class _FeedSwitchScrimState extends State<_FeedSwitchScrim>
    with SingleTickerProviderStateMixin {
  /// Peak scrim alpha while switching — 1 − 0.55, matching the opacity the feed
  /// dim used before it became a scrim.
  static const double _maxAlpha = 0.45;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Seed to the resting/active value so a feed that mounts mid-switch (first
    // load: switchingFocus is already true) shows the dim immediately, matching
    // the old implicit-opacity behaviour that never animated on first build.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: widget.active ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_FeedSwitchScrim oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_controller.value);
          // Same RGB as the resting state; only the alpha ramps, so the wash
          // never passes through an off-hue mid-tone. At t == 0 the fully
          // transparent fill is a no-op paint (ColoredBox skips it).
          return ColoredBox(
            color: widget.color.withValues(alpha: _maxAlpha * t),
          );
        },
      ),
    );
  }
}

/// Section header (Doing or a Scheduled-day bucket) paired with small
/// trailing-edge buttons. The underlying [AgendaTile] keeps its centered text;
/// the buttons sit in a Row with an invisible mirror on the left so the
/// centered title stays at the row's true horizontal midpoint regardless of
/// the buttons' width. When [showMarkAllRead] is set (the Active block with
/// unread threads), a "Mark all read" button precedes "Do all later" in the
/// trailing group, and the left mirror grows to match.
class _SectionHeaderWithRescheduleAll extends StatelessWidget {
  const _SectionHeaderWithRescheduleAll({
    required this.tile,
    required this.threads,
    required this.sectionLabel,
    this.showMarkAllRead = false,
  });

  final Widget tile;
  final List<Thread> threads;
  final String sectionLabel;

  /// When true, a "Mark all read" button (the same [BulkMarkRead] command and
  /// icon as the multi-select header) precedes "Do all later" in the trailing
  /// group. Only the Active block sets this, and only while it holds unread
  /// threads.
  final bool showMarkAllRead;

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    // Trailing buttons sit directly adjacent — matching the multi-select
    // command bar, where each [Button.icon] supplies its own spacing — with a
    // single `lg` inset framing the whole group off the right edge and away
    // from the tile. "Mark all read" (only when the Active block has unread
    // threads) comes before "Do all later".
    final trailing = Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing.lg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMarkAllRead) Button.icon(BulkMarkRead(threads)),
          Button.icon(
            RescheduleAllInBlock(threads, sectionLabel: sectionLabel),
          ),
        ],
      ),
    );
    // The whole header sits on the subtle section-header band. Wrapping the
    // full Row (not just the centered tile) means the band also runs behind
    // the trailing buttons and their invisible left mirror — otherwise the
    // band only paints under the tile in the middle and the sides show
    // through. The tile paints the same opaque band internally for button-less
    // sections, so the two coincide here with no seam.
    return DecoratedBox(
      decoration: BoxDecoration(color: context.colour.sectionHeaderBackground),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Invisible mirror of the entire trailing group reserves its exact
          // width on the left so the centred tile text sits at the row's true
          // horizontal midpoint — whether the group is one button or two.
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: trailing,
          ),
          Expanded(child: tile),
          trailing,
        ],
      ),
    );
  }
}
